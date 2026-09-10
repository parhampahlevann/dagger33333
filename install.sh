#!/usr/bin/env bash
#
# ============================================================================
#  Gost Tunnel Manager  v3.0.0
#  Full rewrite of "Gost Ip6 Script v2.7.0" (original by Masoud Gb)
#  Iran VPS  <-->  Kharej VPS port forwarding (TCP / UDP / encrypted tunnels)
# ============================================================================
#
# WHAT WAS ACTUALLY BROKEN IN v2.7.0 AND IS FIXED HERE
# ----------------------------------------------------
# INSTALL (slow / fails)
#  1. GOST3_PINNED_VERSION was "3.3.0" - that release does not exist. Every
#     time version resolution failed (i.e. exactly when GitHub is filtered),
#     the fallback URL 404'd and the install died. -> pinned to a real release
#     (3.2.6) and the pin is used as a RETRY, not as a blind replacement.
#  2. Mirrors were tried strictly in order, each with --timeout=15 --tries=2,
#     so one dead mirror cost 30s+ before the next was tried. -> mirrors are
#     now RACED in parallel with a 1-byte range request; the first responder
#     wins and is reused for every later download. Usually <2s.
#  3. gzip/tar wrote straight into /usr/local/bin/gost. With a tunnel running
#     that fails with ETXTBSY and leaves a half-written binary behind.
#     -> download + extract + ELF check + `gost -V` smoke test in a temp dir,
#        then atomic rename() into place, then services restart.
#  4. `tar -xzf ... 2>/dev/null` swallowed extraction failures. -> reported.
#  5. apt could hang on a lock forever. -> DPkg::Lock::Timeout=60, dnf/yum
#     fallback, `nano` dropped, `iptables`/`ca-certificates` added (missing
#     but required).
#
# TUNNEL (installs, then no traffic)
#  6. grpc/quic/kcp were emitted as `-L=grpc://:P/DEST:P`. Those are tunnel
#     LISTENERS in gost and expect a gost peer on the other end - single
#     sided they accept connections and drop the traffic. This was the real
#     "tunnel does not work" bug. -> proper 2-node setup:
#          Kharej: -L=relay+grpc://:8443
#          Iran  : -L=tcp://:443/127.0.0.1:443 -F=relay+grpc://KHAREJ:8443
#  7. Invented metadata (keepalive.idle, keepalive.count, keepAlive on TCP)
#     that gost silently ignores. -> TCP is emitted clean (defaults are
#     correct), UDP uses the documented keepAlive/ttl/readBufferSize with the
#     right casing, and gost 2.x vs 3.x syntax is handled separately.
#  8. Stale units were never removed. Recreating a tunnel with fewer ports
#     left old gost_x_1/gost_x_2 units running and HOLDING THE PORTS, so the
#     new unit could not bind. -> old units stopped, disabled, deleted.
#  9. Port collisions were never detected -> silent bind failures. Checked now.
# 10. 1000 -L flags on a single ExecStart line. systemd < 235 caps a line at
#     2048 bytes, so the unit was invalid. -> 200 flags per unit, written with
#     backslash continuations.
# 11. `systemctl restart gost_*.service` only matches already-loaded units and
#     is not expanded by cron's shell. -> units are enumerated explicitly.
# 12. Regex-parsing systemd units for status (the thing that broke over IPv4
#     vs [IPv6] brackets) is gone. Tunnels are declared in
#     /etc/gost/tunnels/*.conf and every action reads from there.
# 13. BBR was written to sysctl.d but tcp_bbr was never modprobe'd nor checked
#     against tcp_available_congestion_control -> silently never applied.
# 14. net.ipv4.ip_forward / IPv6 forwarding were never set on a box whose
#     whole job is forwarding. Added, plus conntrack UDP timeouts.
# 15. `alias gost="bash /etc/gost/install.sh"` shadowed the real binary, so
#     `gost -V` ran the installer. Command is now `gost-tunnel` and the old
#     alias is stripped from ~/.bashrc.
# 16. Watchdog opened a real session through the tunnel every 15s and
#     restarted on the first hiccup. -> passive `ss` check + 2-strike rule.
# 17. Self-update replaced the script without checking it parses. -> `bash -n`
#     gate + timestamped backup.
#
# Env override: GOST_MIRROR=https://your.mirror/   (tried first)
# ============================================================================

set -o pipefail

C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_CYAN=$'\e[36m'; C_MAGENTA=$'\e[35m'
C_WHITE=$'\e[97m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BOLD=$'\e[1m'

VERSION="3.0.0"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

GOST_BIN="/usr/local/bin/gost"
GOST_DIR="/etc/gost"
TUN_DIR="$GOST_DIR/tunnels"
SELF_INSTALL="$GOST_DIR/install.sh"
LAUNCHER="/usr/local/bin/gost-tunnel"
UNIT_DIR="/etc/systemd/system"
SYSCTL_FILE="/etc/sysctl.d/99-gost-tunnel.conf"
LIMITS_FILE="/etc/security/limits.d/99-gost-tunnel.conf"
MODULES_FILE="/etc/modules-load.d/gost-tunnel.conf"
WATCHDOG_SCRIPT="/usr/local/bin/gost-watchdog.sh"
WATCHDOG_UNIT="$UNIT_DIR/gost-watchdog.service"
WATCHDOG_LOG="/var/log/gost-watchdog.log"
FW_SCRIPT="/usr/local/bin/gost-firewall.sh"
FW_UNIT="$UNIT_DIR/gost-firewall.service"
AUTORESTART_SCRIPT="/usr/local/bin/gost-auto-restart.sh"

LEGACY_WATCHDOG="/usr/bin/gost_watchdog.sh"
LEGACY_AUTORESTART="/usr/bin/gost_auto_restart.sh"

REPO_UPDATE_URL="https://github.com/masoudgb/Gost-ip6/raw/main/install.sh"

GOST2_PIN="2.11.5"   # ginuerzh/gost - verified asset naming
GOST3_PIN="3.2.6"    # go-gost/gost  - verified asset naming
MAX_FLAGS_PER_UNIT=200
MAX_PORTS=4000

TMPD=""
DEPS_DONE=0
BEST_MIRROR=""

# ---------------------------------------------------------------- output ----
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$C_GREEN"  "$*" "$C_RESET"; }
info() { printf '%s%s%s\n' "$C_CYAN"   "$*" "$C_RESET"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()  { printf '%s%s%s\n' "$C_RED"    "$*" "$C_RESET" >&2; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD" 2>/dev/null; }
trap cleanup EXIT
TMPD="$(mktemp -d /tmp/gost-mgr.XXXXXX)" || { err "cannot create temp dir"; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then err "Run me as root."; exit 1; fi
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

read_choice() { # prompt min max
  local prompt="$1" min="$2" max="$3" val
  while true; do
    printf '%s' "$prompt" >&2
    read -r val || return 1
    val="${val//[[:space:]]/}"
    if is_number "$val" && [ "$val" -ge "$min" ] && [ "$val" -le "$max" ]; then
      printf '%s\n' "$val"; return 0
    fi
    err "Invalid option, try again."
  done
}

confirm() {
  local a
  printf '%s' "$1" >&2
  read -r a || return 1
  [ "${a,,}" = "y" ] || [ "${a,,}" = "yes" ]
}

banner() {
  printf '%s' "$C_MAGENTA"
  cat <<'BAN'
   ____  ___  ____ _____   _____ _   _ _   _ _   _ _____ _
  / ___|/ _ \/ ___|_   _| |_   _| | | | \ | | \ | | ____| |
 | |  _| | | \___ \ | |     | | | | | |  \| |  \| |  _| | |
 | |_| | |_| |___) || |     | | | |_| | |\  | |\  | |___| |___
  \____|\___/|____/ |_|     |_|  \___/|_| \_|_| \_|_____|_____|
BAN
  printf '%s' "$C_RESET"
  printf '%sManager v%s%s  %sbased on Masoud Gb / Hamid Router%s\n\n' \
    "$C_BOLD" "$VERSION" "$C_RESET" "$C_CYAN" "$C_RESET"
}

# ------------------------------------------------------------- utilities ----
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo amd64   ;;
    aarch64|arm64)  echo arm64   ;;
    armv7*|armv7l)  echo armv7   ;;
    armv6*)         echo armv6   ;;
    armv5*)         echo armv5   ;;
    i386|i686)      echo 386     ;;
    riscv64)        echo riscv64 ;;
    mips64el)       echo mips64le;;
    mips64)         echo mips64  ;;
    mipsel)         echo mipsle  ;;
    mips)           echo mips    ;;
    *)              echo amd64   ;;
  esac
}

looks_like_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for o in ${ip//./ }; do
    [ "$((10#$o))" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

looks_like_ipv6() {
  [[ "$1" == *:* ]] || return 1
  [[ "$1" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
  return 0
}

# gost needs [brackets] around an IPv6 literal and MUST NOT have them on IPv4.
wrap_host() {
  local h="$1"
  if looks_like_ipv6 "$h" && [[ "$h" != \[* ]]; then
    printf '[%s]' "$h"
  else
    printf '%s' "$h"
  fi
}

unit_base_from_name() { printf 'gost_%s' "${1//[^a-zA-Z0-9]/_}"; }

listening() { # proto port
  local flag="-ltn"
  case "$1" in udp|quic|kcp) flag="-lun" ;; esac
  ss -H $flag 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${2}\$"
}

# ------------------------------------------------------------ dependency ----
install_deps() {
  [ "$DEPS_DONE" -eq 1 ] && return 0
  DEPS_DONE=1
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 update -qq >/dev/null 2>&1 || \
      warn "apt update failed - continuing with what is already installed."
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 install -y -qq \
      curl wget tar gzip iproute2 iptables ca-certificates >/dev/null 2>&1 || true
  elif have dnf; then
    dnf install -y -q curl wget tar gzip iproute iptables ca-certificates >/dev/null 2>&1 || true
  elif have yum; then
    yum install -y -q curl wget tar gzip iproute iptables ca-certificates >/dev/null 2>&1 || true
  fi
  local c
  for c in tar gzip ss; do
    have "$c" || warn "'$c' is missing - some features may not work."
  done
  have curl || have wget || { err "Neither curl nor wget is available."; return 1; }
  return 0
}

# --------------------------------------------------------------- network ----
mirrors() {
  local m
  [ -n "$GOST_MIRROR" ] && printf '%s\n' "${GOST_MIRROR%/}/"
  [ -n "$BEST_MIRROR" ] && printf '%s\n' "$BEST_MIRROR"
  for m in "https://gh-proxy.com/" "https://ghfast.top/" "https://ghproxy.net/" ""; do
    [ "$m" = "$BEST_MIRROR" ] && continue
    printf '%s\n' "$m"
  done
}

mirror_label() { if [ -z "$1" ]; then printf 'direct GitHub'; else printf 'mirror %s' "$1"; fi; }

http_get() { # url out maxtime
  local url="$1" out="$2" max="${3:-180}"
  rm -f "$out"
  if have curl; then
    curl -4 -fsSL --connect-timeout 5 --max-time "$max" -o "$out" "$url" 2>/dev/null
  else
    wget -4 -q --timeout=10 --tries=1 -O "$out" "$url" 2>/dev/null
  fi
  [ -s "$out" ]
}

# Race every mirror with a 1-byte range request; first responder wins and is
# cached. This is what removes the guaranteed timeouts that made installs slow.
pick_mirror() { # full-github-url
  have curl || return 0
  local url="$1" hits="$TMPD/hits" m waited=0
  : >"$hits"
  while IFS= read -r m; do
    (
      code=$(curl -4 -o /dev/null -s -w '%{http_code}' -r 0-0 \
             --connect-timeout 4 --max-time 6 "${m}${url}" 2>/dev/null)
      case "$code" in 200|206) printf '%s\n' "$m" >>"$hits" ;; esac
    ) &
  done < <(mirrors)
  while [ "$waited" -lt 70 ]; do
    [ -s "$hits" ] && break
    sleep 0.1; waited=$((waited+1))
  done
  sleep 0.4   # grace so a faster mirror can still win the race
  if [ -s "$hits" ]; then
    BEST_MIRROR="$(head -n1 "$hits")"
    info "Fastest endpoint: $(mirror_label "$BEST_MIRROR")"
  else
    warn "No endpoint answered the probe - trying them all anyway."
  fi
  return 0
}

fetch_github() { # url out maxtime
  local url="$1" out="$2" max="${3:-180}" m
  while IFS= read -r m; do
    info "Downloading via $(mirror_label "$m") ..."
    if http_get "${m}${url}" "$out" "$max"; then
      [ -z "$BEST_MIRROR" ] && BEST_MIRROR="$m"
      return 0
    fi
  done < <(mirrors)
  return 1
}

resolve_v3_version() {
  local m ver
  have curl || { printf '%s\n' "$GOST3_PIN"; return 0; }
  while IFS= read -r m; do
    ver=$(curl -4 -sS -o /dev/null -w '%{redirect_url}' --connect-timeout 4 --max-time 8 \
          "${m}https://github.com/go-gost/gost/releases/latest" 2>/dev/null \
          | grep -oE '[^/]+$' | sed 's/^v//')
    [[ "$ver" =~ ^[0-9]+\.[0-9]+ ]] && { printf '%s\n' "$ver"; return 0; }
  done < <(mirrors)
  ver=$(curl -4 -sS --connect-timeout 4 --max-time 8 \
        "https://api.github.com/repos/go-gost/gost/releases/latest" 2>/dev/null \
        | grep -oE '"tag_name":[[:space:]]*"v?[^"]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [[ "$ver" =~ ^[0-9]+\.[0-9]+ ]] && { printf '%s\n' "$ver"; return 0; }
  warn "Could not resolve the latest gost 3.x tag - using pinned $GOST3_PIN."
  printf '%s\n' "$GOST3_PIN"
}

verify_checksum() { # file repo version asset
  local file="$1" repo="$2" version="$3" asset="$4"
  local sums="$TMPD/checksums.txt" expected actual
  if fetch_github "https://github.com/${repo}/releases/download/v${version}/checksums.txt" "$sums" 20; then
    expected=$(grep -E "[[:space:]]\*?${asset}\$" "$sums" | awk '{print $1}' | head -n1)
  fi
  if [ -z "$expected" ]; then
    # Never fall back to a hardcoded hash: it goes stale the moment upstream
    # cuts a release, and then it hard-fails every install (the old bug).
    warn "checksums.txt unavailable - skipping integrity check for ${asset}."
    return 0
  fi
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [ "$expected" != "$actual" ]; then err "Checksum mismatch for ${asset}."; return 1; fi
  ok "Checksum verified."
  return 0
}

# ----------------------------------------------------------- gost install ---
gost_major() {
  [ -x "$GOST_BIN" ] || { echo 0; return; }
  local v
  v=$("$GOST_BIN" -V 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [ -z "$v" ] && { echo 3; return; }
  printf '%s\n' "${v%%.*}"
}

gost_version_string() {
  [ -x "$GOST_BIN" ] || { printf 'not installed\n'; return; }
  "$GOST_BIN" -V 2>&1 | head -n1
}

download_and_stage() { # 2|3 -> prints staged binary path
  local want="$1" arch ver repo asset url a2 archive stage found out
  arch=$(detect_arch)
  stage="$TMPD/stage"; rm -rf "$stage"; mkdir -p "$stage"

  if [ "$want" -eq 2 ]; then
    repo="ginuerzh/gost"; ver="$GOST2_PIN"
    a2="$arch"; [ "$arch" = "arm64" ] && a2="armv8"   # v2 names arm64 "armv8"
    asset="gost-linux-${a2}-${ver}.gz"
  else
    repo="go-gost/gost"; ver="$(resolve_v3_version)"
    asset="gost_${ver}_linux_${arch}.tar.gz"
  fi
  url="https://github.com/${repo}/releases/download/v${ver}/${asset}"
  info "Target: gost ${ver} (${arch})" >&2

  pick_mirror "$url" >&2
  archive="$TMPD/$asset"
  if ! fetch_github "$url" "$archive" 240 >&2; then
    if [ "$want" -ne 2 ] && [ "$ver" != "$GOST3_PIN" ]; then
      warn "Download of ${ver} failed everywhere - retrying pinned ${GOST3_PIN}." >&2
      ver="$GOST3_PIN"; asset="gost_${ver}_linux_${arch}.tar.gz"
      url="https://github.com/${repo}/releases/download/v${ver}/${asset}"
      archive="$TMPD/$asset"
      fetch_github "$url" "$archive" 240 >&2 || { err "Download failed on every endpoint."; return 1; }
    else
      err "Download failed on every endpoint. Check DNS/connectivity or set GOST_MIRROR=..."
      return 1
    fi
  fi

  if [ "$want" -eq 2 ]; then
    if ! gzip -dc "$archive" >"$stage/gost"; then err "gunzip failed - archive is corrupt."; return 1; fi
  else
    verify_checksum "$archive" "$repo" "$ver" "$asset" >&2 || return 1
    if ! tar -xzf "$archive" -C "$stage"; then err "tar extraction failed - archive is corrupt."; return 1; fi
    found=$(find "$stage" -type f -name gost | head -n1)
    [ -z "$found" ] && { err "No 'gost' binary inside ${asset}."; return 1; }
    [ "$found" != "$stage/gost" ] && mv -f "$found" "$stage/gost"
  fi

  chmod +x "$stage/gost"
  if [ "$(head -c4 "$stage/gost" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
    err "Downloaded file is not an ELF binary (mirror served an error page?)."
    return 1
  fi
  if ! out=$("$stage/gost" -V 2>&1) || [ -z "$out" ]; then
    err "Smoke test failed: binary will not execute here (wrong architecture?)."
    return 1
  fi
  printf '%s\n' "$stage/gost"
}

install_gost() { # 1 => gost 2.x , 2 => gost 3.x  (menu numbering)
  local choice="$1" want=3 staged
  [ "$choice" = "1" ] && want=2
  install_deps || return 1
  mkdir -p /usr/local/bin
  staged=$(download_and_stage "$want") || return 1
  # Atomic swap: rename() over a running binary is safe, truncating it is not
  # (ETXTBSY / half-written file) - that was the old "core will not install".
  install -m 0755 "$staged" "${GOST_BIN}.new" || { err "Cannot write to /usr/local/bin."; return 1; }
  mv -f "${GOST_BIN}.new" "$GOST_BIN" || { err "Cannot replace $GOST_BIN."; return 1; }
  ok "Installed: $(gost_version_string)"
  restart_all_tunnels quiet
  return 0
}

ensure_gost() { # required major (0 = any)
  local need="${1:-0}" cur v
  cur=$(gost_major)
  if [ "$cur" -eq 0 ]; then
    if [ "$need" -eq 3 ]; then
      info "This transport needs gost 3.x - installing it now."
      install_gost 2; return $?
    fi
    info "gost is not installed yet."
    say "  ${C_CYAN}1.${C_RESET} gost 2.x (pinned ${GOST2_PIN}, plain TCP/UDP forwarding)"
    say "  ${C_CYAN}2.${C_RESET} gost 3.x (latest, needed for grpc/quic/kcp/ws)  ${C_GREEN}<- recommended${C_RESET}"
    v=$(read_choice "${C_WHITE}Your choice: ${C_RESET}" 1 2) || return 1
    install_gost "$v"; return $?
  fi
  if [ "$need" -eq 3 ] && [ "$cur" -lt 3 ]; then
    warn "Installed gost is ${cur}.x - upgrading to 3.x for this transport."
    install_gost 2; return $?
  fi
  return 0
}

# ------------------------------------------------------------ tunnel store --
tunnel_names() {
  local f
  for f in "$TUN_DIR"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
}

unit_list() { # base
  local u
  for u in "$UNIT_DIR/${1}_"*.service; do
    [ -e "$u" ] || continue
    basename "$u"
  done
}

remove_units() { # base
  local u
  for u in $(unit_list "$1"); do
    systemctl disable --now "$u" >/dev/null 2>&1
    rm -f "$UNIT_DIR/$u"
  done
  systemctl daemon-reload
}

# ------------------------------------------------------------ port parsing --
# "443" | "80,443,8080" | "2000-2100" | "80,443,5000-5100"
# Ranges must use a dash. The old script read "2000,2100" as a range, which
# silently turned a 2-port list into 101 listeners.
expand_ports() { # spec -> csv
  local spec="$1" tok start end p out=() toks=()
  spec="${spec//[[:space:]]/}"
  IFS=',' read -ra toks <<<"$spec"
  for tok in "${toks[@]}"; do
    [ -z "$tok" ] && continue
    if [[ "$tok" == *-* ]]; then
      start="${tok%%-*}"; end="${tok##*-}"
      if ! is_number "$start" || ! is_number "$end" || [ "$start" -lt 1 ] || [ "$end" -gt 65535 ] || [ "$start" -gt "$end" ]; then
        err "Invalid range: $tok"; return 1
      fi
      for ((p=start; p<=end; p++)); do out+=("$p"); done
    else
      if ! is_number "$tok" || [ "$tok" -lt 1 ] || [ "$tok" -gt 65535 ]; then
        err "Invalid port: $tok"; return 1
      fi
      out+=("$tok")
    fi
  done
  [ "${#out[@]}" -eq 0 ] && { err "No ports given."; return 1; }
  if [ "${#out[@]}" -gt "$MAX_PORTS" ]; then
    err "${#out[@]} ports is past sane limits (max $MAX_PORTS)."; return 1
  fi
  printf '%s\n' "${out[@]}" | sort -n -u | paste -sd, -
}

check_port_conflicts() { # base proto csv
  local base="$1" proto="$2" csv="$3" p clash=() owner arr=()
  IFS=',' read -ra arr <<<"$csv"
  for p in "${arr[@]}"; do
    if listening "$proto" "$p"; then
      owner=$(ss -H -ltnup 2>/dev/null | awk -v P=":$p" '$4 ~ P"$"' | head -n1)
      case "$owner" in *gost*) continue ;; esac
      clash+=("$p")
    fi
  done
  if [ "${#clash[@]}" -gt 0 ]; then
    warn "Already in use by another process (${proto}): ${clash[*]}"
    confirm "${C_YELLOW}Continue anyway? (y/n): ${C_RESET}" || return 1
  fi
  return 0
}

# --------------------------------------------------------- flag generation --
# TCP forwarding needs NO metadata - gost's defaults are already correct, and
# the old keepalive.* keys were not real options (silently ignored).
udp_suffix() {
  if [ "$(gost_major)" -ge 3 ]; then
    printf '?keepAlive=true&ttl=30s&readBufferSize=4096&backlog=1024'
  else
    printf '?ttl=30s'
  fi
}

build_flags() { # base -> one flag per line
  local base="$1" DEST PORTS PROTO IPV MODE CHANNEL TSERVER TPORT
  # shellcheck disable=SC1090
  . "$TUN_DIR/${base}.conf"
  local dest_addr usuf p arr=()
  dest_addr="$(wrap_host "$DEST")"
  usuf="$(udp_suffix)"

  if [ "$MODE" = "tunnel-server" ]; then
    printf -- '-L=relay+%s://:%s\n' "$CHANNEL" "$TPORT"
    return 0
  fi

  IFS=',' read -ra arr <<<"$PORTS"
  for p in "${arr[@]}"; do
    case "$PROTO" in
      tcp)  printf -- '-L=tcp://:%s/%s:%s\n' "$p" "$dest_addr" "$p" ;;
      udp)  printf -- '-L=udp://:%s/%s:%s%s\n' "$p" "$dest_addr" "$p" "$usuf" ;;
      both) printf -- '-L=tcp://:%s/%s:%s\n' "$p" "$dest_addr" "$p"
            printf -- '-L=udp://:%s/%s:%s%s\n' "$p" "$dest_addr" "$p" "$usuf" ;;
    esac
  done

  if [ "$MODE" = "tunnel-client" ]; then
    # THIS is what makes grpc/quic/kcp/ws actually relay: the listener stays
    # tcp/udp, the encrypted transport is the forward chain hop.
    printf -- '-F=relay+%s://%s:%s\n' "$CHANNEL" "$(wrap_host "$TSERVER")" "$TPORT"
  fi
}

write_units() { # base
  local base="$1" flags=() f chain="" total per units idx start end i unit exec
  while IFS= read -r f; do flags+=("$f"); done < <(build_flags "$base")
  [ "${#flags[@]}" -eq 0 ] && { err "Nothing to configure."; return 1; }

  # -F must be repeated in every chunk, else the extra units relay nowhere.
  if [[ "${flags[-1]}" == -F=* ]]; then
    chain="${flags[-1]}"; unset 'flags[-1]'
  fi

  total=${#flags[@]}; per=$MAX_FLAGS_PER_UNIT
  units=$(( (total + per - 1) / per ))
  [ "$units" -eq 0 ] && units=1

  remove_units "$base"

  for ((idx=0; idx<units; idx++)); do
    unit="${base}_${idx}"
    start=$((idx*per)); end=$(( (idx+1)*per )); [ "$end" -gt "$total" ] && end=$total
    exec="ExecStart=${GOST_BIN}"
    for ((i=start; i<end; i++)); do
      exec+=" \\
    ${flags[$i]}"
    done
    [ -n "$chain" ] && exec+=" \\
    ${chain}"

    cat >"$UNIT_DIR/${unit}.service" <<EOF
[Unit]
Description=GO Simple Tunnel (${unit})
Documentation=https://gost.run
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
${exec}
Restart=always
RestartSec=2
TimeoutStopSec=10
LimitNOFILE=1048576
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=2

[Install]
WantedBy=multi-user.target
EOF
  done

  systemctl daemon-reload
  local failed=0
  for ((idx=0; idx<units; idx++)); do
    unit="${base}_${idx}.service"
    systemctl enable "$unit" >/dev/null 2>&1
    systemctl restart "$unit"
    if ! systemctl is-active --quiet "$unit"; then
      failed=1
      err "Unit ${unit} did not start. Last log lines:"
      journalctl -u "$unit" -n 12 --no-pager 2>/dev/null | sed 's/^/    /'
    fi
  done
  [ "$failed" -eq 0 ] && ok "${units} unit(s) running, ${total} listener(s)."
  return "$failed"
}

# -------------------------------------------------------------- firewall ----
write_firewall_helper() {
  cat >"$FW_SCRIPT" <<'FWEOF'
#!/usr/bin/env bash
# Generated by gost-tunnel: opens tunnel ports, clamps MSS to the path MTU.
TUN_DIR="/etc/gost/tunnels"
add_rule() { # ipt proto csv
  local ipt="$1" proto="$2" csv="$3"
  command -v "$ipt" >/dev/null 2>&1 || return 0
  "$ipt" -C INPUT -p "$proto" -m multiport --dports "$csv" -j ACCEPT 2>/dev/null || \
  "$ipt" -I INPUT 1 -p "$proto" -m multiport --dports "$csv" -j ACCEPT 2>/dev/null
}
open_ports() { # proto csv   (multiport allows max 15 entries per rule)
  local proto="$1" csv="$2" chunk=() n=0 p arr=()
  IFS=',' read -ra arr <<<"$csv"
  for p in "${arr[@]}"; do
    [ -z "$p" ] && continue
    chunk+=("$p"); n=$((n+1))
    if [ "$n" -eq 15 ]; then
      add_rule iptables  "$proto" "$(IFS=,; echo "${chunk[*]}")"
      add_rule ip6tables "$proto" "$(IFS=,; echo "${chunk[*]}")"
      chunk=(); n=0
    fi
  done
  if [ "$n" -gt 0 ]; then
    add_rule iptables  "$proto" "$(IFS=,; echo "${chunk[*]}")"
    add_rule ip6tables "$proto" "$(IFS=,; echo "${chunk[*]}")"
  fi
}
for f in "$TUN_DIR"/*.conf; do
  [ -e "$f" ] || continue
  PORTS=""; PROTO=""; MODE=""; TPORT=""
  . "$f"
  if [ "$MODE" = "tunnel-server" ]; then
    open_ports tcp "$TPORT"; open_ports udp "$TPORT"; continue
  fi
  case "$PROTO" in
    tcp)  open_ports tcp "$PORTS" ;;
    udp)  open_ports udp "$PORTS" ;;
    both) open_ports tcp "$PORTS"; open_ports udp "$PORTS" ;;
  esac
  if [ "$MODE" = "tunnel-client" ]; then
    open_ports tcp "$TPORT"; open_ports udp "$TPORT"
  fi
done
if command -v iptables >/dev/null 2>&1; then
  iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
fi
exit 0
FWEOF
  chmod +x "$FW_SCRIPT"
  cat >"$FW_UNIT" <<EOF
[Unit]
Description=gost tunnel firewall rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$FW_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable gost-firewall.service >/dev/null 2>&1
}

apply_firewall() {
  write_firewall_helper
  if "$FW_SCRIPT" >/dev/null 2>&1; then
    ok "Firewall rules + MSS clamp applied (re-applied on every boot)."
  fi
  have netfilter-persistent && netfilter-persistent save >/dev/null 2>&1
  return 0
}

remove_firewall() {
  if have iptables; then
    while iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do
      iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || break
    done
  fi
  systemctl disable --now gost-firewall.service >/dev/null 2>&1
  rm -f "$FW_UNIT" "$FW_SCRIPT"
  systemctl daemon-reload
}

# --------------------------------------------------------- kernel tuning ----
apply_kernel_tuning() {
  info "Applying kernel / TCP / UDP tuning ..."
  local kmaj kmin bbr=0 cc qd
  kmaj=$(uname -r | cut -d. -f1); kmin=$(uname -r | cut -d. -f2 | grep -oE '^[0-9]+')
  kmaj=${kmaj:-0}; kmin=${kmin:-0}

  # BBR needs tcp_bbr loaded BEFORE sysctl will accept it. The old script never
  # modprobe'd it, so the setting was written and silently rejected.
  if [ "$kmaj" -gt 4 ] || { [ "$kmaj" -eq 4 ] && [ "$kmin" -ge 9 ]; }; then
    modprobe tcp_bbr 2>/dev/null
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
      bbr=1
      printf 'tcp_bbr\n' >"$MODULES_FILE"
    else
      warn "tcp_bbr unavailable in this kernel - keeping current congestion control."
    fi
  else
    warn "Kernel $(uname -r) is older than 4.9 - no BBR."
  fi

  {
    echo "# managed by gost-tunnel v${VERSION}"
    echo "net.ipv4.ip_forward = 1"
    echo "net.ipv6.conf.all.forwarding = 1"
    echo "net.ipv4.ip_local_port_range = 10240 65535"
    echo "net.core.rmem_max = 67108864"
    echo "net.core.wmem_max = 67108864"
    echo "net.core.rmem_default = 1048576"
    echo "net.core.wmem_default = 1048576"
    echo "net.ipv4.tcp_rmem = 4096 87380 67108864"
    echo "net.ipv4.tcp_wmem = 4096 65536 67108864"
    echo "net.ipv4.udp_rmem_min = 16384"
    echo "net.ipv4.udp_wmem_min = 16384"
    echo "net.core.netdev_max_backlog = 65535"
    echo "net.core.somaxconn = 65535"
    echo "net.ipv4.tcp_max_syn_backlog = 65535"
    echo "net.ipv4.tcp_syncookies = 1"
    echo "net.ipv4.tcp_fin_timeout = 15"
    echo "net.ipv4.tcp_tw_reuse = 1"
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    echo "net.ipv4.tcp_keepalive_time = 60"
    echo "net.ipv4.tcp_keepalive_intvl = 10"
    echo "net.ipv4.tcp_keepalive_probes = 6"
    echo "net.ipv4.tcp_mtu_probing = 1"
    echo "net.ipv4.tcp_fastopen = 3"
    echo "net.ipv4.tcp_notsent_lowat = 16384"
    echo "fs.file-max = 2097152"
    if [ "$bbr" -eq 1 ]; then
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    fi
    if modprobe nf_conntrack 2>/dev/null || [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
      echo "net.netfilter.nf_conntrack_max = 262144"
      echo "net.netfilter.nf_conntrack_tcp_timeout_established = 3600"
      echo "net.netfilter.nf_conntrack_udp_timeout = 60"
      echo "net.netfilter.nf_conntrack_udp_timeout_stream = 180"
    fi
  } >"$SYSCTL_FILE"

  sysctl --system >/dev/null 2>&1 || warn "sysctl reported errors - run 'sysctl --system' to see them."

  {
    echo "* soft nofile 1048576"
    echo "* hard nofile 1048576"
    echo "root soft nofile 1048576"
    echo "root hard nofile 1048576"
  } >"$LIMITS_FILE"

  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  ok "Tuning applied. congestion=${cc:-?} qdisc=${qd:-?} ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
}

# -------------------------------------------------------------- watchdog ----
write_watchdog() {
  cat >"$WATCHDOG_SCRIPT" <<'WDEOF'
#!/usr/bin/env bash
# Generated by gost-tunnel. Passive health check: never opens a session
# through the tunnel, and needs two consecutive failures before restarting.
LOG="/var/log/gost-watchdog.log"
TUN_DIR="/etc/gost/tunnels"
INTERVAL=15
MAX_LOG_LINES=5000
declare -A STRIKES

log() { printf '%s %s\n' "$(date '+%F %T')" "$1" >>"$LOG"; }

trim_log() {
  [ -f "$LOG" ] || return 0
  local n; n=$(wc -l <"$LOG" 2>/dev/null || echo 0)
  if [ "$n" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG" >"${LOG}.tmp" && mv -f "${LOG}.tmp" "$LOG"
  fi
}

listening() {
  local flag="-ltn"; [ "$1" = udp ] && flag="-lun"
  ss -H $flag 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${2}\$"
}

strike() { # unit reason
  local u="$1" r="$2"
  STRIKES[$u]=$(( ${STRIKES[$u]:-0} + 1 ))
  if [ "${STRIKES[$u]}" -ge 2 ]; then
    systemctl restart "$u"
    log "restarted $u ($r)"
    STRIKES[$u]=0
  fi
}

while true; do
  if [ ! -x /usr/local/bin/gost ]; then
    log "gost binary missing - nothing to supervise"
    sleep "$INTERVAL"; continue
  fi
  for cfg in "$TUN_DIR"/*.conf; do
    [ -e "$cfg" ] || continue
    base="$(basename "$cfg" .conf)"
    PORTS=""; PROTO=""; MODE=""; TPORT=""
    . "$cfg"
    for unit in /etc/systemd/system/"${base}"_*.service; do
      [ -e "$unit" ] || continue
      name="$(basename "$unit")"
      if ! systemctl is-active --quiet "$name"; then
        systemctl restart "$name"
        log "restarted $name (unit was inactive)"
        STRIKES[$name]=0
        continue
      fi
      if [ "$MODE" = "tunnel-server" ]; then
        listening tcp "$TPORT" || strike "$name" "tunnel port $TPORT not listening"
        continue
      fi
      first="${PORTS%%,*}"
      [ -z "$first" ] && continue
      case "$PROTO" in
        udp) listening udp "$first" || strike "$name" "udp/$first not listening" ;;
        *)   listening tcp "$first" || strike "$name" "tcp/$first not listening" ;;
      esac
    done
  done
  trim_log
  sleep "$INTERVAL"
done
WDEOF
  chmod +x "$WATCHDOG_SCRIPT"
  cat >"$WATCHDOG_UNIT" <<EOF
[Unit]
Description=gost tunnel watchdog
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

enable_watchdog() {
  write_watchdog
  systemctl enable --now gost-watchdog.service >/dev/null 2>&1
  [ "${1:-}" = "silent" ] || ok "Watchdog enabled (passive check every ~15s, log: $WATCHDOG_LOG)."
}

disable_watchdog() {
  systemctl disable --now gost-watchdog.service >/dev/null 2>&1
  ok "Watchdog disabled."
}

# --------------------------------------------------------------- prompts ----
prompt_protocol() {
  say "${C_GREEN}Traffic type:${C_RESET}" >&2
  say "  ${C_CYAN}1.${C_RESET} TCP only" >&2
  say "  ${C_CYAN}2.${C_RESET} UDP only" >&2
  say "  ${C_CYAN}3.${C_RESET} TCP + UDP  ${C_GREEN}<- what most setups actually need${C_RESET}" >&2
  say "  ${C_CYAN}4.${C_RESET} Encrypted tunnel (grpc/quic/kcp/wss/mtls) - needs gost on BOTH servers" >&2
  local o; o=$(read_choice "${C_WHITE}Your choice: ${C_RESET}" 1 4) || return 1
  case "$o" in 1) echo tcp ;; 2) echo udp ;; 3) echo both ;; 4) echo TUNNEL ;; esac
}

prompt_channel() {
  say "${C_GREEN}Tunnel transport:${C_RESET}" >&2
  say "  ${C_CYAN}1.${C_RESET} grpc  HTTP/2 + TLS, best against DPI" >&2
  say "  ${C_CYAN}2.${C_RESET} wss   WebSocket + TLS, looks like plain https" >&2
  say "  ${C_CYAN}3.${C_RESET} mtls  multiplexed TLS, lowest overhead" >&2
  say "  ${C_CYAN}4.${C_RESET} quic  UDP + TLS1.3, fastest when UDP is not throttled" >&2
  say "  ${C_CYAN}5.${C_RESET} kcp   UDP + FEC, best on lossy links, eats bandwidth" >&2
  local o; o=$(read_choice "${C_WHITE}Your choice: ${C_RESET}" 1 5) || return 1
  case "$o" in 1) echo grpc ;; 2) echo wss ;; 3) echo mtls ;; 4) echo quic ;; 5) echo kcp ;; esac
}

prompt_ports() {
  local spec
  say "${C_GREEN}Ports${C_RESET} - one: ${C_CYAN}443${C_RESET} | list: ${C_CYAN}80,443,8080${C_RESET} | range: ${C_CYAN}2000-2100${C_RESET} | mixed: ${C_CYAN}80,2000-2100${C_RESET}" >&2
  printf '%s' "${C_WHITE}Ports: ${C_RESET}" >&2
  read -r spec || return 1
  expand_ports "$spec"
}

# ---------------------------------------------------------- create tunnel ---
action_create_tunnel() { # ip_version
  local ipv="$1" dest ports proto channel tserver tport base mode="direct" r
  ensure_gost 0 || return 1

  printf '%s' "${C_WHITE}Destination (Kharej) IP: ${C_RESET}"
  read -r dest || return 1
  dest="${dest//[[:space:]]/}"; dest="${dest#[}"; dest="${dest%]}"
  [ -z "$dest" ] && { err "IP cannot be empty."; return 1; }
  if [ "$ipv" -eq 4 ] && ! looks_like_ipv4 "$dest"; then err "Not a valid IPv4 address."; return 1; fi
  if [ "$ipv" -eq 6 ] && ! looks_like_ipv6 "$dest"; then err "Not a valid IPv6 address."; return 1; fi

  proto=$(prompt_protocol) || return 1

  if [ "$proto" = "TUNNEL" ]; then
    ensure_gost 3 || return 1
    channel=$(prompt_channel) || return 1
    say "${C_GREEN}Which side is this server?${C_RESET}"
    say "  ${C_CYAN}1.${C_RESET} Iran / entry side  (users connect here)"
    say "  ${C_CYAN}2.${C_RESET} Kharej / exit side (terminates the tunnel)"
    r=$(read_choice "${C_WHITE}Your choice: ${C_RESET}" 1 2) || return 1
    printf '%s' "${C_WHITE}Tunnel port (identical on both servers, e.g. 8443): ${C_RESET}"
    read -r tport || return 1
    tport="${tport//[[:space:]]/}"
    if ! is_number "$tport" || [ "$tport" -lt 1 ] || [ "$tport" -gt 65535 ]; then
      err "Invalid tunnel port."; return 1
    fi
    if [ "$r" -eq 2 ]; then
      mode="tunnel-server"; proto="tcp"; ports=""
      base=$(unit_base_from_name "srv_${channel}_${tport}")
    else
      mode="tunnel-client"; tserver="$dest"
      say "${C_CYAN}On the exit side traffic is delivered to this address."
      say "Press Enter for 127.0.0.1 (services running on the Kharej box itself).${C_RESET}"
      printf '%s' "${C_WHITE}Final target [127.0.0.1]: ${C_RESET}"
      read -r dest || return 1
      dest="${dest//[[:space:]]/}"; [ -z "$dest" ] && dest="127.0.0.1"
      proto=$(read_choice "${C_WHITE}Forward 1=TCP 2=UDP 3=both: ${C_RESET}" 1 3) || return 1
      case "$proto" in 1) proto=tcp ;; 2) proto=udp ;; 3) proto=both ;; esac
      ports=$(prompt_ports) || return 1
      base=$(unit_base_from_name "cli_${tserver}")
    fi
  else
    ports=$(prompt_ports) || return 1
    base=$(unit_base_from_name "$dest")
  fi

  if [ -n "$ports" ]; then
    case "$proto" in tcp|both) check_port_conflicts "$base" tcp "$ports" || return 1 ;; esac
    case "$proto" in udp|both) check_port_conflicts "$base" udp "$ports" || return 1 ;; esac
  fi

  mkdir -p "$TUN_DIR"
  cat >"$TUN_DIR/${base}.conf" <<EOF
# gost-tunnel config - edit, then run "Rebuild units from config"
NAME="$base"
DEST="$dest"
PORTS="$ports"
PROTO="$proto"
IPV="$ipv"
MODE="$mode"
CHANNEL="${channel:-}"
TSERVER="${tserver:-}"
TPORT="${tport:-}"
CREATED="$(date '+%F %T')"
EOF

  write_units "$base" || return 1
  apply_firewall
  apply_kernel_tuning
  enable_watchdog silent
  hr
  ok "Tunnel '${base}' is live."
  if [ "$mode" = "tunnel-client" ]; then
    warn "Now run this script on the Kharej server: option 4 -> ${channel} -> 'Kharej / exit side', tunnel port ${tport}."
  elif [ "$mode" = "tunnel-server" ]; then
    warn "Now run this script on the Iran server: option 4 -> ${channel} -> 'Iran / entry side', tunnel port ${tport}."
  fi
}

# ---------------------------------------------------------------- status ----
action_status() {
  local names base DEST PORTS PROTO IPV MODE CHANNEL TSERVER TPORT n state unit
  hr
  say "${C_WHITE}gost core:${C_RESET} $(gost_version_string)"
  names=$(tunnel_names)
  if [ -z "$names" ]; then
    warn "No tunnels configured."
  else
    while IFS= read -r base; do
      DEST=""; PORTS=""; PROTO=""; IPV=""; MODE=""; CHANNEL=""; TSERVER=""; TPORT=""
      . "$TUN_DIR/${base}.conf"
      n=0; [ -n "$PORTS" ] && n=$(awk -F, '{print NF}' <<<"$PORTS")
      hr
      say "${C_WHITE}Tunnel:${C_RESET} ${C_BOLD}${base}${C_RESET}"
      case "$MODE" in
        tunnel-server) say "  mode: tunnel exit, relay+${CHANNEL} on :${TPORT}" ;;
        tunnel-client) say "  mode: tunnel entry -> ${TSERVER}:${TPORT} (relay+${CHANNEL}), target ${DEST}, ${PROTO}, ${n} port(s)" ;;
        *)             say "  mode: direct forward -> ${DEST} (IPv${IPV}), ${PROTO}, ${n} port(s)" ;;
      esac
      for unit in $(unit_list "$base"); do
        state=$(systemctl is-active "$unit" 2>/dev/null)
        if [ "$state" = "active" ]; then
          say "  ${C_GREEN}*${C_RESET} $unit ($state)"
        else
          say "  ${C_RED}*${C_RESET} $unit ($state)"
        fi
      done
    done <<<"$names"
  fi
  hr
  if systemctl is-active --quiet gost-watchdog.service 2>/dev/null; then
    say "${C_WHITE}Watchdog:${C_RESET} ${C_GREEN}active${C_RESET} (log: $WATCHDOG_LOG)"
  else
    say "${C_WHITE}Watchdog:${C_RESET} ${C_YELLOW}stopped${C_RESET}"
  fi
  say "${C_WHITE}Congestion:${C_RESET} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / qdisc $(sysctl -n net.core.default_qdisc 2>/dev/null)"
}

# ----------------------------------------------------------- diagnostics ----
probe_tcp() { # host port timeout -> 0 ok, 1 fail, 2 cannot test
  local h="$1" p="$2" t="${3:-4}"
  if looks_like_ipv6 "$h"; then
    if have nc; then nc -z -6 -w "$t" "$h" "$p" >/dev/null 2>&1 && return 0 || return 1; fi
    return 2
  fi
  timeout "$t" bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null
}

action_diagnose() {
  local names base DEST PORTS PROTO MODE CHANNEL TSERVER TPORT unit first rc
  hr
  say "${C_BOLD}1. gost core${C_RESET}"
  if [ -x "$GOST_BIN" ]; then ok "   $(gost_version_string)"; else err "   not installed"; fi

  say "${C_BOLD}2. Kernel${C_RESET}"
  say "   congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null) ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) nofile=$(ulimit -n)"
  [ -f "$SYSCTL_FILE" ] || warn "   tuning file missing - run menu option 9."

  say "${C_BOLD}3. Firewall${C_RESET}"
  if have iptables; then
    say "   INPUT policy: $(iptables -S INPUT 2>/dev/null | awk '/-P INPUT/{print $3}')"
    say "   gost ACCEPT rules: $(iptables -S INPUT 2>/dev/null | grep -c multiport)"
  else
    warn "   iptables unavailable"
  fi

  names=$(tunnel_names)
  [ -z "$names" ] && { warn "No tunnels configured - nothing else to check."; return 0; }

  say "${C_BOLD}4. Tunnels${C_RESET}"
  while IFS= read -r base; do
    DEST=""; PORTS=""; PROTO=""; MODE=""; CHANNEL=""; TSERVER=""; TPORT=""
    . "$TUN_DIR/${base}.conf"
    hr
    say "   ${C_BOLD}${base}${C_RESET} (${MODE})"
    for unit in $(unit_list "$base"); do
      if systemctl is-active --quiet "$unit"; then
        ok "   + $unit active"
      else
        err "   ! $unit $(systemctl is-active "$unit" 2>/dev/null)"
        journalctl -u "$unit" -n 8 --no-pager 2>/dev/null | sed 's/^/       /'
      fi
    done

    if [ "$MODE" = "tunnel-server" ]; then
      if listening tcp "$TPORT"; then ok "   + listening on tunnel port ${TPORT}"; else err "   ! NOT listening on ${TPORT}"; fi
    else
      first="${PORTS%%,*}"
      if [ -n "$first" ]; then
        case "$PROTO" in
          udp) listening udp "$first" && ok "   + udp/${first} bound" || err "   ! udp/${first} not bound" ;;
          *)   listening tcp "$first" && ok "   + tcp/${first} bound" || err "   ! tcp/${first} not bound" ;;
        esac
      fi
      # The number one real cause of "installed but nothing works": the other
      # end is not listening, or the path to it is blocked.
      if [ "$MODE" = "tunnel-client" ]; then
        probe_tcp "$TSERVER" "$TPORT" 5; rc=$?
        case "$rc" in
          0) ok "   + reachable: ${TSERVER}:${TPORT} (tunnel endpoint)" ;;
          2) warn "   ? cannot test IPv6 endpoint without netcat" ;;
          *) err "   ! CANNOT reach ${TSERVER}:${TPORT} - the exit side is down or blocked." ;;
        esac
      elif [ -n "$first" ] && [ "$PROTO" != "udp" ]; then
        probe_tcp "$DEST" "$first" 5; rc=$?
        case "$rc" in
          0) ok "   + reachable: ${DEST}:${first}" ;;
          2) warn "   ? cannot test IPv6 destination without netcat" ;;
          *) err "   ! CANNOT reach ${DEST}:${first} from this server - fix the destination first, gost will accept connections and then fail." ;;
        esac
      fi
    fi
  done <<<"$names"
  hr
  say "Watchdog log tail:"
  tail -n 5 "$WATCHDOG_LOG" 2>/dev/null | sed 's/^/   /'
}

# ------------------------------------------------------------- lifecycle ----
restart_all_tunnels() {
  local base unit any=0
  while IFS= read -r base; do
    [ -z "$base" ] && continue
    for unit in $(unit_list "$base"); do
      any=1
      systemctl restart "$unit"
    done
  done < <(tunnel_names)
  [ "${1:-}" = "quiet" ] && return 0
  if [ "$any" -eq 1 ]; then ok "All tunnel units restarted."; else warn "No tunnel units to restart."; fi
}

action_rebuild() {
  local names base
  names=$(tunnel_names)
  [ -z "$names" ] && { warn "No tunnels configured."; return; }
  while IFS= read -r base; do
    info "Rebuilding $base ..."
    write_units "$base"
  done <<<"$names"
  apply_firewall
}

action_delete_tunnel() {
  local names arr=() i=1 base sel
  names=$(tunnel_names)
  [ -z "$names" ] && { warn "No tunnels configured."; return; }
  while IFS= read -r base; do
    arr+=("$base"); say "  ${C_CYAN}${i}.${C_RESET} $base"; i=$((i+1))
  done <<<"$names"
  sel=$(read_choice "${C_WHITE}Delete which one: ${C_RESET}" 1 "${#arr[@]}") || return
  base="${arr[$((sel-1))]}"
  confirm "${C_YELLOW}Delete tunnel '${base}' and its units? (y/n): ${C_RESET}" || { say "Canceled."; return; }
  remove_units "$base"
  rm -f "$TUN_DIR/${base}.conf"
  ok "Deleted ${base}."
}

action_auto_restart() {
  local o h
  say "  ${C_CYAN}1.${C_RESET} Enable"
  say "  ${C_CYAN}2.${C_RESET} Disable"
  o=$(read_choice "${C_WHITE}Your choice: ${C_RESET}" 1 2) || return
  if [ "$o" -eq 1 ]; then
    h=$(read_choice "${C_WHITE}Restart every N hours (1-23): ${C_RESET}" 1 23) || return
    cat >"$AUTORESTART_SCRIPT" <<'AREOF'
#!/usr/bin/env bash
# Units are enumerated explicitly: `systemctl restart gost_*.service` only
# matches already-loaded units and is not expanded by cron's shell.
systemctl daemon-reload
for u in /etc/systemd/system/gost_*.service; do
  [ -e "$u" ] || continue
  systemctl restart "$(basename "$u")"
done
AREOF
    chmod +x "$AUTORESTART_SCRIPT"
    ( crontab -l 2>/dev/null | grep -v 'gost-auto-restart\|gost_auto_restart'; \
      echo "0 */$h * * * $AUTORESTART_SCRIPT >/dev/null 2>&1" ) | crontab -
    ok "Scheduled every ${h}h. (The watchdog already heals dead units; use this only if you want blind restarts too.)"
  else
    ( crontab -l 2>/dev/null | grep -v 'gost-auto-restart\|gost_auto_restart' ) | crontab - 2>/dev/null
    rm -f "$AUTORESTART_SCRIPT" "$LEGACY_AUTORESTART"
    ok "Auto restart disabled."
  fi
}

action_update_script() {
  local tmp backup
  confirm "${C_GREEN}Fetch the latest script from the repo? (y/n): ${C_RESET}" || { say "Canceled."; return; }
  mkdir -p "$GOST_DIR"
  tmp="$TMPD/update.sh"; backup="${SELF_INSTALL}.bak.$(date +%Y%m%d%H%M%S)"
  fetch_github "$REPO_UPDATE_URL" "$tmp" 60 || { err "Download failed. Nothing changed."; return 1; }
  head -c 20 "$tmp" | grep -q '^#!' || { err "That is not a script. Nothing changed."; return 1; }
  # Never install a script that does not even parse.
  bash -n "$tmp" 2>/dev/null || { err "Downloaded script has syntax errors. Nothing changed."; return 1; }
  [ -f "$SELF_INSTALL" ] && cp -f "$SELF_INSTALL" "$backup" && ok "Backup: $backup"
  install -m 0755 "$tmp" "$SELF_INSTALL"
  ok "Updated. Restarting ..."
  exec bash "$SELF_INSTALL"
}

action_uninstall() {
  local base u
  warn "This removes gost, every tunnel unit, the watchdog, tuning and firewall rules."
  confirm "${C_RED}Type y to continue: ${C_RESET}" || { say "Canceled."; return; }
  while IFS= read -r base; do
    [ -n "$base" ] && remove_units "$base"
  done < <(tunnel_names)
  for u in "$UNIT_DIR"/gost_*.service; do
    [ -e "$u" ] || continue
    systemctl disable --now "$(basename "$u")" >/dev/null 2>&1
    rm -f "$u"
  done
  systemctl disable --now gost-watchdog.service >/dev/null 2>&1
  rm -f "$WATCHDOG_UNIT" "$WATCHDOG_SCRIPT" "$WATCHDOG_LOG" "$LEGACY_WATCHDOG" "$LEGACY_AUTORESTART"
  ( crontab -l 2>/dev/null | grep -v 'gost-auto-restart\|gost_auto_restart\|drop_caches' ) | crontab - 2>/dev/null
  remove_firewall
  rm -f "$GOST_BIN" "$SYSCTL_FILE" "$LIMITS_FILE" "$MODULES_FILE" "$AUTORESTART_SCRIPT" "$LAUNCHER"
  rm -rf "$GOST_DIR"
  sed -i '/alias gost=/d;/alias gost-tunnel=/d' ~/.bashrc 2>/dev/null
  sysctl --system >/dev/null 2>&1
  systemctl daemon-reload
  ok "Uninstalled. Kernel defaults come back after the next reboot."
}

ensure_self_installed() {
  mkdir -p "$GOST_DIR" "$TUN_DIR"
  if [ -f "$SELF_PATH" ] && [ "$SELF_PATH" != "$SELF_INSTALL" ]; then
    install -m 0755 "$SELF_PATH" "$SELF_INSTALL"
  fi
  cat >"$LAUNCHER" <<EOF
#!/bin/sh
exec bash "$SELF_INSTALL" "\$@"
EOF
  chmod +x "$LAUNCHER"
  # the old alias shadowed the real gost binary - drop it
  sed -i '/alias gost="bash \/etc\/gost\/install.sh"/d' ~/.bashrc 2>/dev/null
}

# ------------------------------------------------------------------ menu -----
main_menu() {
  local c v o
  while true; do
    clear 2>/dev/null
    banner
    say "  ${C_CYAN} 1.${C_RESET} Create tunnel  (destination = IPv4)"
    say "  ${C_CYAN} 2.${C_RESET} Create tunnel  (destination = IPv6)"
    say "  ${C_CYAN} 3.${C_RESET} Status"
    say "  ${C_CYAN} 4.${C_RESET} Diagnose  ${C_GREEN}<- start here when it installs but does not work${C_RESET}"
    say "  ${C_CYAN} 5.${C_RESET} Install / change gost core"
    say "  ${C_CYAN} 6.${C_RESET} Rebuild units from config"
    say "  ${C_CYAN} 7.${C_RESET} Restart all tunnels"
    say "  ${C_CYAN} 8.${C_RESET} Delete a tunnel"
    say "  ${C_CYAN} 9.${C_RESET} Speed / stability tuning (BBR + sysctl + MSS clamp)"
    say "  ${C_CYAN}10.${C_RESET} Watchdog on/off"
    say "  ${C_CYAN}11.${C_RESET} Timed auto-restart"
    say "  ${C_CYAN}12.${C_RESET} Update this script"
    say "  ${C_CYAN}13.${C_RESET} Uninstall everything"
    say "  ${C_CYAN}14.${C_RESET} Exit"
    say ""
    c=$(read_choice "${C_WHITE}Your choice: ${C_RESET}" 1 14) || exit 0
    say ""
    case "$c" in
      1)  action_create_tunnel 4 ;;
      2)  action_create_tunnel 6 ;;
      3)  action_status ;;
      4)  action_diagnose ;;
      5)  install_deps
          say "  ${C_CYAN}1.${C_RESET} gost 2.x (pinned ${GOST2_PIN})"
          say "  ${C_CYAN}2.${C_RESET} gost 3.x (latest)"
          v=$(read_choice "${C_WHITE}Your choice: ${C_RESET}" 1 2) && install_gost "$v" ;;
      6)  action_rebuild ;;
      7)  restart_all_tunnels ;;
      8)  action_delete_tunnel ;;
      9)  apply_kernel_tuning; apply_firewall ;;
      10) say "  ${C_CYAN}1.${C_RESET} Enable"; say "  ${C_CYAN}2.${C_RESET} Disable"
          if o=$(read_choice "${C_WHITE}Your choice: ${C_RESET}" 1 2); then
            if [ "$o" -eq 1 ]; then enable_watchdog; else disable_watchdog; fi
          fi ;;
      11) action_auto_restart ;;
      12) action_update_script ;;
      13) action_uninstall ;;
      14) ok "Bye."; exit 0 ;;
    esac
    say ""
    printf '%s' "${C_WHITE}Press Enter to return to the menu ...${C_RESET}"
    read -r _
  done
}

# ----------------------------------------------------------------- entry ----
require_root
ensure_self_installed
case "${1:-}" in
  --status)   action_status; exit 0 ;;
  --diagnose) action_diagnose; exit 0 ;;
  --rebuild)  action_rebuild; exit 0 ;;
  --restart)  restart_all_tunnels; exit 0 ;;
  --tune)     apply_kernel_tuning; apply_firewall; exit 0 ;;
  --version)  say "gost-tunnel manager v$VERSION"; exit 0 ;;
  -h|--help)
    say "Usage: gost-tunnel [--status|--diagnose|--rebuild|--restart|--tune|--version]"
    say "No arguments: interactive menu."
    exit 0 ;;
esac
main_menu
