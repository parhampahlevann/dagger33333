#!/bin/bash
#
# Gost Ip6 Script v2.5.0 (hardened/optimized fork)
# Original by Masoud Gb - Special Thanks Hamid Router
#
# Changes in v2.5.0 (this revision):
#  - LATEST-VERSION FETCHING WAS BROKEN FOR GOST 2.x: it was hardcoded to
#    v2.11.5 forever. The real latest is fetched live now (currently
#    v2.12.0), the same way v3 already did it, using one shared resolver
#    for both branches (see resolve_gost_release). The old JSON-scraping
#    method for v3 is replaced with a lighter releases/latest redirect
#    lookup, which is not subject to the same tight rate limit as
#    api.github.com (confirmed by testing: the API call got rate-limited
#    while the redirect lookup kept working from the same IP).
#  - CONFIRMED REAL BUG, SEVERE: the udp listener's metadata key is
#    "keepalive" (lowercase) - the script was sending "keepAlive"
#    (capital A). Traced this in gost's actual source
#    (x/listener/udp/listener.go): when keepalive isn't recognized, every
#    single WriteTo() closes the per-client connection immediately after
#    replying, so a udp tunnel effectively rebuilds its forwarding session
#    on every packet instead of reusing one. This alone can explain
#    "udp works then drops" symptoms. Fixed the casing.
#  - Also fixed the mirrored issue on quic: quic's key is "keepAlive"
#    (capital A), the script had "keepalive". Lower impact there (quic
#    defaults to keepalive-on when the key is absent), but now it's
#    explicit and correct instead of accidentally-fine.
#  - Added gost-level TCP keepalive (keepalive + idle/interval/count) to
#    every tcp -L listener, tuned to match the kernel keepalive sysctls
#    below. Previously the sysctl tuning alone had no effect on gost's own
#    sockets unless gost explicitly turns SO_KEEPALIVE on for them - this
#    is what was asked for as "tcp should connect fast and stay stable".
#  - Added SHA256 verification of downloaded gost binaries against the
#    checksums.txt each release publishes, fetched through the same
#    mirror chain. Complements (doesn't replace) the existing ELF-header
#    check. Never hard-fails the install if checksums.txt itself can't be
#    fetched - only fails on an actual mismatch.
#  - Mirror list refreshed (gh-proxy.com kept, added gh-proxy.org and
#    ghproxy.net) - see the comment above GH_MIRRORS, this list WILL go
#    stale again over time, that's just the nature of these services.
#  - WATCHDOG REBUILT: was a cron job checking every 2 minutes. Now a
#    real systemd service running a tight ~15s loop, so a dead tunnel is
#    caught and restarted in seconds instead of up to 2 minutes. It also
#    now enables itself automatically at the end of every tunnel
#    creation - previously it required a separate manual menu step.
#    Restarts are logged to /var/log/gost-watchdog.log (self-trimmed) so
#    you can actually verify it's doing something.
#  - Fixed action_status: it checked `command -v gost`, which depends on
#    PATH, while everything else in this script uses the fixed absolute
#    path /usr/local/bin/gost. Made it consistent.
#  - The "By IP4" / "By IP6" menu choice was collected into $ip_version
#    and then never used anywhere - both paths ran identically. Verified
#    directly against gost's parser that always-bracketing the
#    destination (what this script already did) is correctly accepted for
#    BOTH IPv4 and IPv6, so that part was never actually broken. What WAS
#    missing is that the menu choice did nothing - it now validates the
#    address you type actually looks like the family you picked, so a
#    typo/paste mistake gets caught immediately instead of silently
#    creating a broken tunnel.
#  - action_update_script now backs up the current install.sh before
#    overwriting it, and checks the fetched file is non-empty and starts
#    with a shebang before replacing anything. NOTE: the update URL still
#    points at the original upstream repo, which does not contain any of
#    this hardening - point REPO_UPDATE_URL below at your own fork if you
#    maintain one, otherwise "Update Script" will overwrite the hardening
#    with the plain upstream version. Backing up at least means you can
#    recover if that happens by accident.
#  - Auto-restart hour input now rejects 0 (produced an invalid `*/0`
#    cron field) and is capped at 23 (values above 23 silently collapsed
#    to "once a day" in cron and gave a misleading impression of what was
#    scheduled).
#  - Minor: kernel-version parsing for the BBR check is now defensive
#    against a non-numeric minor version instead of assuming one.
#  - Everything else from v2.4.0 (input validation, MSS clamp, single
#    case-statement menu dispatch, sysctl.d/limits.d instead of
#    rc.local, self-install to /etc/gost/install.sh) is unchanged.
#
set -o pipefail

# ---------- colors ----------
C_RESET='\e[0m'; C_GREEN='\e[32m'; C_CYAN='\e[36m'; C_MAGENTA='\e[35m'
C_WHITE='\e[97m'; C_YELLOW='\e[33m'; C_RED='\e[31m'

SELF_PATH="$(readlink -f "$0")"
GOST_DIR="/etc/gost"
SYSCTL_FILE="/etc/sysctl.d/99-gost-tunnel.conf"
LIMITS_FILE="/etc/security/limits.d/99-gost-tunnel.conf"
WATCHDOG_SCRIPT="/usr/bin/gost_watchdog.sh"
WATCHDOG_UNIT="/etc/systemd/system/gost-watchdog.service"
WATCHDOG_LOG="/var/log/gost-watchdog.log"
# Point this at your own fork before relying on "Update Script" (option 4)
# if you want it to keep the hardening - see changelog note above.
REPO_UPDATE_URL="https://github.com/masoudgb/Gost-ip6/raw/main/install.sh"

# ---------- helpers ----------
require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${C_GREEN}Please run with root privileges.${C_RESET}"
        exit 1
    fi
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

read_choice() {
    # $1 = prompt, $2 = min, $3 = max -> echoes validated integer
    local prompt="$1" min="$2" max="$3" val
    while true; do
        read -rp "$prompt" val
        if is_number "$val" && [ "$val" -ge "$min" ] && [ "$val" -le "$max" ]; then
            echo "$val"; return 0
        fi
        echo -e "${C_RED}Invalid option, try again.${C_RESET}" >&2
    done
}

# Rough but effective: catches the common case of a typo'd/pasted-wrong
# address family. Not a full RFC validator - gost itself is the final
# authority on whether an address is usable.
looks_like_ipv4() {
    local ip="$1" IFS=. o1 o2 o3 o4
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    read -r o1 o2 o3 o4 <<< "${ip}"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ "$o" -le 255 ] || return 1
    done
    return 0
}
looks_like_ipv6() { [[ "$1" == *:* ]] && [[ "$1" != *.* || "$1" == *:*.* ]]; }

banner() {
    echo -e "${C_MAGENTA}  ___|              |        _ _|  _ \\   /
 |      _ \\    __|  __|        |  |   |  _ \\
 |   | (   | \\__ \\  |          |  ___/  (   |
\\____|\\___/  ____/ \\__|      ___|_|    \\___/ ${C_RESET}"
    echo -e "${C_CYAN}Created By Masoud Gb  Special Thanks Hamid Router${C_RESET}"
    echo -e "${C_MAGENTA}Gost Ip6 Script v2.5.0 (hardened)${C_RESET}"
}

ensure_self_installed() {
    mkdir -p "$GOST_DIR"
    if [ ! -f "$GOST_DIR/install.sh" ]; then
        cp -f "$SELF_PATH" "$GOST_DIR/install.sh"
        chmod +x "$GOST_DIR/install.sh"
    fi
    if ! grep -q "alias gost=" ~/.bashrc 2>/dev/null; then
        echo "alias gost=\"bash $GOST_DIR/install.sh\"" >> ~/.bashrc
    fi
}

# ---------- kernel / TCP+UDP tuning for speed + stability ----------
apply_kernel_tuning() {
    echo -e "${C_GREEN}Applying kernel/TCP/UDP tuning for throughput and stability...${C_RESET}"

    local kernel_major kernel_minor bbr_ok=1
    kernel_major=$(uname -r | cut -d. -f1)
    kernel_minor=$(uname -r | cut -d. -f2 | grep -oE '^[0-9]+')
    kernel_major=${kernel_major:-0}; kernel_minor=${kernel_minor:-0}
    if [ "$kernel_major" -lt 4 ] || { [ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ]; }; then
        bbr_ok=0
        echo -e "${C_YELLOW}Kernel < 4.9, BBR not available - skipping congestion control change.${C_RESET}"
    fi
    # Note: BBR is a TCP-only congestion control. It has zero effect on
    # udp/quic traffic - quic's congestion control lives inside gost's
    # quic-go library, not the kernel. Don't expect BBR to help quic.

    {
        echo "net.ipv4.ip_local_port_range = 1024 65535"
        echo "net.core.rmem_max = 67108864"
        echo "net.core.wmem_max = 67108864"
        echo "net.core.rmem_default = 1048576"
        echo "net.core.wmem_default = 1048576"
        echo "net.ipv4.tcp_rmem = 4096 87380 67108864"
        echo "net.ipv4.tcp_wmem = 4096 65536 67108864"
        echo "net.ipv4.udp_rmem_min = 131072"
        echo "net.ipv4.udp_wmem_min = 131072"
        # Raises the kernel's receive backlog queue so bursts of udp/quic
        # packets aren't dropped before the app (gost) reads them - the
        # default (1000) is too low for a busy udp/quic relay and is a
        # common silent cause of "packet loss" that never shows up in
        # gost's own logs because the kernel drops the packet first.
        echo "net.core.netdev_max_backlog = 250000"
        echo "net.core.somaxconn = 65535"
        echo "net.ipv4.tcp_max_syn_backlog = 65535"
        echo "net.ipv4.tcp_syncookies = 1"
        echo "net.ipv4.tcp_fin_timeout = 15"
        echo "net.ipv4.tcp_tw_reuse = 1"
        echo "net.ipv4.tcp_slow_start_after_idle = 0"
        # System-level keepalive defaults. These only bite for sockets
        # that have SO_KEEPALIVE turned on - see the gost -L keepalive
        # flags added below, which is what actually turns it on for
        # gost's own listeners. The two are meant to match.
        echo "net.ipv4.tcp_keepalive_time = 60"
        echo "net.ipv4.tcp_keepalive_intvl = 10"
        echo "net.ipv4.tcp_keepalive_probes = 6"
        echo "net.ipv4.tcp_mtu_probing = 1"
        echo "fs.file-max = 2097152"
        if [ "$bbr_ok" -eq 1 ]; then
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
        # A relay box juggling thousands of forwarded connections can
        # silently exhaust the default conntrack table (65536 on most
        # distros) - once full, new connections get dropped with no
        # error in gost's own logs, which just looks like "sometimes it
        # doesn't work". Only written if the module is actually present.
        if modprobe nf_conntrack 2>/dev/null || [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
            echo "net.netfilter.nf_conntrack_max = 1048576"
            echo "net.netfilter.nf_conntrack_tcp_timeout_established = 3600"
        fi
    } > "$SYSCTL_FILE"

    sysctl --system > /dev/null 2>&1

    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        echo 262144 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null
    fi

    {
        echo "* soft nofile 1048576"
        echo "* hard nofile 1048576"
        echo "* soft nproc 1048576"
        echo "* hard nproc 1048576"
    } > "$LIMITS_FILE"

    echo -e "${C_GREEN}Kernel/TCP/UDP tuning applied.${C_RESET}"
}

# ---------- gost install ----------
# IMPORTANT: if direct GitHub access from this server is blocked/reset
# (not just slow), no amount of retrying the direct URL will help. So we
# fall back through a couple of well-known public GitHub download mirrors.
# These are third-party services, not run by us or Anthropic - use at
# your own judgment. Because of that, every downloaded file is checked
# for a real ELF header AND (best-effort) a matching SHA256 from the
# release's own checksums.txt before being installed.
#
# Mirror availability drifts constantly - both which mirrors exist and
# which ones a given network blocks change independently and often. The
# three below were verified reachable at the time this script was
# written. If every one of them eventually stops working for you, search
# "github proxy mirror" for current ones and edit this array; the format
# is always "https://<mirror-host>/" prepended directly to the full
# https://github.com/... URL. Keep the empty "" entry first - it means
# "try GitHub directly" before falling back to any mirror.
WGET_OPTS="--timeout=20 --tries=2 --waitretry=2"
CURL_OPTS="--connect-timeout 10 --max-time 25 --retry 2 --retry-delay 2 -s"
GH_MIRRORS=("" "https://gh-proxy.com/" "https://gh-proxy.org/" "https://ghproxy.net/")
# Last-resort fallback ONLY, used if live version discovery below fails
# completely (e.g. github.com itself is unreachable). Update these
# occasionally so the fallback doesn't go too stale.
GOST2_PINNED_VERSION="2.12.0"
GOST3_PINNED_VERSION="3.3.0"

is_elf_binary() { [ -f "$1" ] && [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; }

# fetch_with_mirrors <full https://github.com/... url> <output-path>
# Tries the URL directly, then through each mirror prefix, in order.
fetch_with_mirrors() {
    local url="$1" out="$2" m label
    for m in "${GH_MIRRORS[@]}"; do
        label="direct GitHub"; [ -n "$m" ] && label="mirror $m"
        echo -e "${C_GREEN}Trying ${label}...${C_RESET}"
        rm -f "$out"
        if wget $WGET_OPTS -q -O "$out" "${m}${url}" && [ -s "$out" ]; then
            return 0
        fi
    done
    return 1
}

# resolve_gost_release <owner/repo> <pinned_version_fallback>
# Prints "VERSION URL" on stdout. ginuerzh/gost (v2) and go-gost/gost (v3)
# both publish identical goreleaser-style assets
# (gost_VERSION_linux_amd64.tar.gz + checksums.txt), confirmed by
# inspecting both repos' actual releases - so one resolver covers both,
# where previously v2 was hardcoded and only v3 tried to be dynamic.
#
# Tries, in order:
#   1. The releases/latest redirect - just reads the Location header, so
#      it's a single lightweight request, and it is NOT subject to
#      api.github.com's much tighter unauthenticated rate limit (this was
#      confirmed directly: the API call below got rate-limited in testing
#      while this redirect lookup kept working from the same IP).
#   2. The GitHub API, in case github.com's web redirect is blocked but
#      the API host isn't (uncommon, but cheap to try).
#   3. The hardcoded pinned version, if both of the above fail.
resolve_gost_release() {
    local repo="$1" pinned="$2" version=""

    version=$(curl $CURL_OPTS -o /dev/null -w '%{redirect_url}' "https://github.com/${repo}/releases/latest" 2>/dev/null \
              | grep -oE '[^/]+$' | sed 's/^v//')

    if [ -z "$version" ]; then
        version=$(curl $CURL_OPTS "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
                  | grep -oP '"tag_name":\s*"v?\K[^"]+' | head -n1)
    fi

    if [ -z "$version" ]; then
        echo -e "${C_YELLOW}Could not reach GitHub to check the latest ${repo} version - using last-known version ${pinned} instead.${C_RESET}" >&2
        version="$pinned"
    fi

    echo "${version} https://github.com/${repo}/releases/download/v${version}/gost_${version}_linux_amd64.tar.gz"
}

# verify_checksum <downloaded-file> <owner/repo> <version> <asset-filename>
# Best-effort SHA256 check against the release's published checksums.txt,
# fetched through the same mirror chain as the binary itself. This is on
# top of, not instead of, the ELF-header check below - the ELF check
# catches "got an HTML error page instead of a binary", this catches
# "got a corrupted or substituted file that still happens to be an ELF".
# Never hard-fails the install just because checksums.txt couldn't be
# fetched at all (that alone isn't evidence of tampering) - only fails on
# an actual mismatch.
verify_checksum() {
    local file="$1" repo="$2" version="$3" asset="$4" sums="/tmp/gost_checksums_$$.txt" expected actual

    if ! fetch_with_mirrors "https://github.com/${repo}/releases/download/v${version}/checksums.txt" "$sums"; then
        echo -e "${C_YELLOW}Could not fetch checksums.txt - skipping checksum verification (the ELF check below still applies).${C_RESET}"
        return 0
    fi

    expected=$(grep "  ${asset}\$" "$sums" | awk '{print $1}')
    rm -f "$sums"
    if [ -z "$expected" ]; then
        echo -e "${C_YELLOW}${asset} wasn't listed in checksums.txt - skipping checksum verification.${C_RESET}"
        return 0
    fi

    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo -e "${C_RED}Checksum mismatch for ${asset}.${C_RESET}"
        echo -e "${C_RED}  expected: ${expected}${C_RESET}"
        echo -e "${C_RED}  got:      ${actual}${C_RESET}"
        echo -e "${C_RED}Aborting - this means a corrupted download or a mirror serving something other than the real file.${C_RESET}"
        return 1
    fi
    echo -e "${C_GREEN}Checksum verified.${C_RESET}"
    return 0
}

install_gost() {
    local version_choice="$1" repo pinned version url asset
    apt-get update -qq && apt-get install -y -qq wget nano tar curl > /dev/null

    if [ "$version_choice" -eq 1 ]; then
        repo="ginuerzh/gost"; pinned="$GOST2_PINNED_VERSION"
    else
        repo="go-gost/gost"; pinned="$GOST3_PINNED_VERSION"
    fi

    echo -e "${C_GREEN}Checking the latest ${repo} release...${C_RESET}"
    read -r version url <<< "$(resolve_gost_release "$repo" "$pinned")"
    asset="gost_${version}_linux_amd64.tar.gz"
    echo -e "${C_GREEN}Installing gost ${version}.${C_RESET}"

    if ! fetch_with_mirrors "$url" /tmp/gost.tar.gz; then
        echo -e "${C_RED}Download failed on direct GitHub and every mirror. Your server likely has no usable path to GitHub at all right now.${C_RESET}"
        echo -e "${C_YELLOW}If you have a working proxy, export it and re-run: export https_proxy=http://IP:PORT; export http_proxy=http://IP:PORT${C_RESET}"
        return 1
    fi

    verify_checksum /tmp/gost.tar.gz "$repo" "$version" "$asset" || { rm -f /tmp/gost.tar.gz; return 1; }

    tar -xzf /tmp/gost.tar.gz -C /usr/local/bin/ gost 2>/dev/null
    chmod +x /usr/local/bin/gost 2>/dev/null

    if ! is_elf_binary /usr/local/bin/gost; then
        echo -e "${C_RED}The installed file isn't a valid binary (likely an error page from a mirror, or a bad archive). Aborting install.${C_RESET}"
        rm -f /usr/local/bin/gost
        return 1
    fi
    rm -f /tmp/gost.tar.gz
    echo -e "${C_GREEN}Gost ${version} installed successfully.${C_RESET}"
}

# grpc and quic need Gost 3.x - 2.x's implementations of both are older
# and are the most likely reason they misbehave (dropped traffic / total
# failure). tcp/udp/kcp work fine on either version, so we only force the
# version when it actually matters.
ensure_gost_for_protocol() {
    local protocol="$1"

    if [ ! -x /usr/local/bin/gost ]; then
        if [ "$protocol" == "grpc" ] || [ "$protocol" == "quic" ]; then
            echo -e "${C_YELLOW}${protocol} requires Gost 3.x - installing the latest 3.x automatically.${C_RESET}"
            install_gost 2
            return $?
        fi
        echo -e "${C_GREEN}Gost is not installed yet.${C_RESET}"
        echo -e "${C_CYAN}1. ${C_RESET}Gost 2.x (latest, official, tcp/udp/kcp)"
        echo -e "${C_CYAN}2. ${C_RESET}Gost 3.x (latest, required for grpc/quic)"
        local v; v=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
        install_gost "$v"
        return $?
    fi

    if [ "$protocol" == "grpc" ] || [ "$protocol" == "quic" ]; then
        # best-effort version probe - if it fails we just proceed, we don't
        # want a fragile version-string parse to block a working setup
        local ver_line
        ver_line=$(/usr/local/bin/gost -V 2>&1 | head -1)
        if echo "$ver_line" | grep -qE '(^| )gost( |v)?2\.'; then
            echo -e "${C_YELLOW}Installed Gost looks like a 2.x build - ${protocol} needs 3.x. Reinstalling latest 3.x...${C_RESET}"
            install_gost 2
            return $?
        fi
    fi
    return 0
}

# ---------- build/refresh a tunnel systemd unit ----------
# args: unit_name  destination_ip  ports_csv  protocol
build_tunnel_service() {
    local unit_name="$1" destination_ip="$2" ports_csv="$3" protocol="$4"

    # Reliability query params appended to every -L listener.
    #
    # udp: gost's udp listener metadata key is "keepalive" (lowercase) -
    # confirmed directly in gost's source (x/listener/udp/listener.go and
    # the shared internal/net/udp connection wrapper). Without it
    # recognized, every WriteTo() closes that client's forwarding session
    # right after replying, so a udp tunnel silently rebuilds its session
    # on every single packet instead of reusing one for the ttl window -
    # this is very likely why udp "works, then drops".
    #
    # quic: the key there is "keepAlive" (capital A) - confirmed the same
    # way. ttl is lowercase "ttl" for both.
    #
    # tcp: adds gost-level SO_KEEPALIVE with idle/interval/count tuned to
    # match the kernel sysctls in apply_kernel_tuning, so dead TCP peers
    # get detected and cleaned up instead of hanging as half-open
    # connections. This is what makes "tcp stays stable" actually apply
    # at the gost socket level, not just at the kernel default level.
    local suffix=""
    case "$protocol" in
        tcp)  suffix="?keepalive=true&keepalive.idle=60s&keepalive.interval=10s&keepalive.count=6" ;;
        udp)  suffix="?keepalive=true&ttl=10s" ;;
        quic) suffix="?keepAlive=true&ttl=10s" ;;
        kcp)  suffix="?kcp.mode=fast" ;;
    esac

    IFS=',' read -ra port_array <<< "$ports_csv"
    local port_count=${#port_array[@]}
    local max_ports_per_unit=4000   # keep ExecStart lines sane and startup fast
    local file_count=$(( (port_count + max_ports_per_unit - 1) / max_ports_per_unit ))

    for ((file_index = 0; file_index < file_count; file_index++)); do
        local this_unit="${unit_name}_${file_index}"
        local exec_start="ExecStart=/usr/local/bin/gost"
        local start=$((file_index * max_ports_per_unit))
        local end=$(( (file_index + 1) * max_ports_per_unit ))
        [ "$end" -gt "$port_count" ] && end=$port_count

        for ((i = start; i < end; i++)); do
            local port="${port_array[i]}"
            exec_start+=" -L=${protocol}://:${port}/[${destination_ip}]:${port}${suffix}"
        done

        cat > "/etc/systemd/system/${this_unit}.service" <<EOF
[Unit]
Description=GO Simple Tunnel (${this_unit})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Environment="GOST_LOGGER_LEVEL=fatal"
${exec_start}
Restart=always
RestartSec=2
TimeoutStopSec=5
LimitNOFILE=1048576
LimitNPROC=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable "${this_unit}.service" > /dev/null 2>&1
        systemctl daemon-reload
        systemctl restart "${this_unit}.service"
    done

    apply_mss_clamp
    enable_watchdog silent

    echo -e "${C_GREEN}Tunnel configuration applied (${file_count} service unit(s)). Watchdog is active.${C_RESET}"
    if [ "$protocol" == "quic" ]; then
        echo -e "${C_YELLOW}Note: quic runs over UDP. If it never connects at all (not just slow/packet loss), that is almost always the network path blocking/throttling UDP, not this script. Try tcp as a control to confirm.${C_RESET}"
    fi
}

# TLS/gRPC framing adds bytes on top of the real payload; if a packet then
# exceeds path MTU it gets fragmented or silently dropped by routers that
# block fragments - a common cause of "works but unstable/slow" over grpc.
# Clamping MSS to the actual path MTU avoids this without needing to know
# the exact MTU in advance. NOTE: this only helps TCP-based protocols
# (tcp, grpc) - it does nothing for udp/quic, which don't use MSS.
apply_mss_clamp() {
    command -v iptables &>/dev/null || return 0
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        echo -e "${C_GREEN}MSS clamping enabled (reduces fragmentation-related packet loss on tcp/grpc).${C_RESET}"
    fi
}

prompt_protocol() {
    echo -e "${C_GREEN}Select the protocol:${C_RESET}" >&2
    echo -e "${C_CYAN}1. ${C_RESET}tcp   plain TCP relay - fastest when the path is clean, but on a lossy/long-haul link TCP's own congestion control will make it feel slow" >&2
    echo -e "${C_CYAN}2. ${C_RESET}udp   plain UDP relay" >&2
    echo -e "${C_CYAN}3. ${C_RESET}grpc  HTTP/2 + TLS wrapped (forces Gost 3.x)" >&2
    echo -e "${C_CYAN}4. ${C_RESET}quic  UDP + TLS1.3, lowest latency of the wrapped options (forces Gost 3.x - some networks throttle/block UDP-based QUIC, test tcp first if unsure)" >&2
    echo -e "${C_CYAN}5. ${C_RESET}kcp   UDP-based with forward-error-correction/aggressive retransmit - built specifically for lossy international links where plain tcp feels slow but doesn't drop" >&2
    local opt
    opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 5)
    case "$opt" in
        1) echo "tcp" ;;
        2) echo "udp" ;;
        3) echo "grpc" ;;
        4) echo "quic" ;;
        5) echo "kcp" ;;
    esac
}

prompt_ports() {
    local opt ports_out
    opt=$(read_choice $'\e[32mPorts:\n\e[0m\e[36m1. \e[0mManual (comma separated)\n\e[36m2. \e[0mRange\n\e[32mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        read -rp $'\e[36mEnter ports (comma separated): \e[0m' ports_out
        IFS=',' read -ra check_arr <<< "$ports_out"
        for p in "${check_arr[@]}"; do
            if ! is_number "$p" || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
                echo -e "${C_RED}Invalid port: $p${C_RESET}" >&2; return 1
            fi
        done
    else
        local range start end
        read -rp $'\e[36mEnter port range (e.g. 2000,2100): \e[0m' range
        IFS=',' read -ra rarr <<< "$range"
        start="${rarr[0]:-}"; end="${rarr[1]:-}"
        if ! is_number "$start" || ! is_number "$end" || [ "$start" -lt 1 ] || [ "$end" -gt 65535 ] || [ "$start" -gt "$end" ]; then
            echo -e "${C_RED}Invalid range.${C_RESET}" >&2; return 1
        fi
        ports_out=$(seq -s, "$start" "$end")
    fi
    echo "$ports_out"
}

action_create_tunnel() {
    local ip_version="$1" destination_ip ports protocol
    read -rp $'\e[97mEnter destination (Kharej) IP: \e[0m' destination_ip
    [ -z "$destination_ip" ] && { echo -e "${C_RED}IP cannot be empty.${C_RESET}"; return; }

    if [ "$ip_version" -eq 4 ] && ! looks_like_ipv4 "$destination_ip"; then
        echo -e "${C_RED}That doesn't look like a valid IPv4 address (you're in the IPv4 menu). If it's actually IPv6, use option 2 from the main menu instead.${C_RESET}"
        return
    fi
    if [ "$ip_version" -eq 6 ] && ! looks_like_ipv6 "$destination_ip"; then
        echo -e "${C_RED}That doesn't look like a valid IPv6 address (you're in the IPv6 menu). If it's actually IPv4, use option 1 from the main menu instead.${C_RESET}"
        return
    fi

    ports=$(prompt_ports) || return
    protocol=$(prompt_protocol)

    echo -e "${C_WHITE}Destination:${C_RESET} $destination_ip  ${C_WHITE}Protocol:${C_RESET} $protocol  ${C_WHITE}Ports:${C_RESET} $(echo "$ports" | cut -c1-40)..."

    ensure_gost_for_protocol "$protocol" || return

    local unit_name="gost_$(echo "$destination_ip" | tr -c 'a-zA-Z0-9' '_')"
    build_tunnel_service "$unit_name" "$destination_ip" "$ports" "$protocol"
    apply_kernel_tuning
}

action_status() {
    if [ ! -x /usr/local/bin/gost ]; then
        echo -e "${C_YELLOW}Gost is not installed.${C_RESET}"
        return
    fi
    local found=0
    for svc in /etc/systemd/system/gost_*.service; do
        [ -e "$svc" ] || continue
        found=1
        local active dest proto ports
        active=$(systemctl is-active "$(basename "$svc")" 2>/dev/null)
        dest=$(grep -oP 'ExecStart=.*?-L=\S+://:\d+/\[\K[^\]]+' "$svc" | head -1)
        proto=$(grep -oP 'ExecStart=.*?-L=\K[a-z]+(?=://)' "$svc" | head -1)
        ports=$(grep -oP -- '-L=\S+?://:\K[0-9]+' "$svc" | wc -l)
        echo -e "${C_WHITE}Unit:${C_RESET} $(basename "$svc")  ${C_WHITE}State:${C_RESET} $active  ${C_WHITE}IP:${C_RESET} $dest  ${C_WHITE}Proto:${C_RESET} $proto  ${C_WHITE}Ports:${C_RESET} $ports"
    done
    [ "$found" -eq 0 ] && echo -e "${C_YELLOW}No tunnel services configured.${C_RESET}"

    if systemctl is-active --quiet gost-watchdog.service 2>/dev/null; then
        echo -e "${C_WHITE}Watchdog:${C_RESET} ${C_GREEN}active${C_RESET} (log: $WATCHDOG_LOG)"
    else
        echo -e "${C_WHITE}Watchdog:${C_RESET} ${C_YELLOW}not running${C_RESET}"
    fi
}

action_update_script() {
    read -rp $'\e[32mUpdate script from repo? (y/n): \e[0m' ans
    [ "$ans" != "y" ] && { echo "Canceled."; return; }
    mkdir -p "$GOST_DIR"

    local backup="${GOST_DIR}/install.sh.bak.$(date +%Y%m%d%H%M%S)"
    if [ -f "$GOST_DIR/install.sh" ]; then
        cp -f "$GOST_DIR/install.sh" "$backup"
        echo -e "${C_GREEN}Backed up current script to ${backup}${C_RESET}"
    fi

    local tmp="/tmp/gost_install_update.sh"
    if ! wget -q -O "$tmp" "$REPO_UPDATE_URL" || [ ! -s "$tmp" ] || ! head -c 20 "$tmp" | grep -q '^#!'; then
        echo -e "${C_RED}Download failed or the fetched file doesn't look like a valid script. Nothing was changed.${C_RESET}"
        rm -f "$tmp"
        return 1
    fi

    mv -f "$tmp" "$GOST_DIR/install.sh"
    chmod +x "$GOST_DIR/install.sh"
    echo -e "${C_YELLOW}Note: this pulls from the upstream repo, which does not include this script's hardening/fixes unless REPO_UPDATE_URL near the top has been pointed at your own fork. Your previous version is saved at ${backup} if you need to go back.${C_RESET}"
    echo -e "${C_GREEN}Updated. Restarting...${C_RESET}"
    exec bash "$GOST_DIR/install.sh"
}

action_change_version() {
    echo -e "${C_CYAN}1. ${C_RESET}Gost 2.x (latest)"
    echo -e "${C_CYAN}2. ${C_RESET}Gost 3.x (latest)"
    local v; v=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    install_gost "$v"
    systemctl restart gost_*.service 2>/dev/null
}

action_auto_restart() {
    echo -e "${C_CYAN}1. ${C_RESET}Enable"
    echo -e "${C_CYAN}2. ${C_RESET}Disable"
    local opt; opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        local hours
        hours=$(read_choice $'\e[97mRestart interval in hours (1-23): \e[0m' 1 23)
        cat > /usr/bin/gost_auto_restart.sh <<'EOF'
#!/bin/bash
systemctl daemon-reload
systemctl restart gost_*.service
EOF
        chmod +x /usr/bin/gost_auto_restart.sh
        (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh; echo "0 */$hours * * * /usr/bin/gost_auto_restart.sh") | crontab -
        echo -e "${C_GREEN}Auto restart scheduled every $hours hour(s).${C_RESET}"
        echo -e "${C_YELLOW}Note: this restarts tunnels unconditionally on a timer, even if they're healthy, which means a brief planned interruption every $hours hour(s). The watchdog (option 7) only restarts what's actually unhealthy and reacts within seconds - for "never let it drop", the watchdog alone is usually the better fit. This blind timer is here if you want it in addition.${C_RESET}"
    else
        rm -f /usr/bin/gost_auto_restart.sh
        (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh) | crontab - 2>/dev/null
        echo -e "${C_GREEN}Auto restart disabled.${C_RESET}"
    fi
}

# ---------- watchdog: probes the actual port and self-heals fast ----------
# Runs as a persistent systemd service with a ~15s loop (not a 2-minute
# cron job like before), so a dead tunnel is caught and restarted within
# seconds instead of up to 2 minutes later. Restarts are logged so you can
# verify it's actually doing something.
generate_watchdog_script() {
    cat > "$WATCHDOG_SCRIPT" <<WDEOF
#!/bin/bash
LOG="$WATCHDOG_LOG"
INTERVAL=15
MAX_LOG_LINES=5000

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1" >> "\$LOG"; }

trim_log() {
    [ -f "\$LOG" ] || return 0
    local lines; lines=\$(wc -l < "\$LOG" 2>/dev/null || echo 0)
    if [ "\$lines" -gt "\$MAX_LOG_LINES" ]; then
        tail -n "\$MAX_LOG_LINES" "\$LOG" > "\${LOG}.tmp" && mv -f "\${LOG}.tmp" "\$LOG"
    fi
}

while true; do
    for unit in /etc/systemd/system/gost_*.service; do
        [ -e "\$unit" ] || continue
        name="\$(basename "\$unit" .service)"

        if ! systemctl is-active --quiet "\$name"; then
            systemctl restart "\$name"
            log "restarted \$name (was inactive)"
            continue
        fi

        port="\$(grep -oP -- '-L=\S+?://:\K[0-9]+' "\$unit" | head -1)"
        proto="\$(grep -oP 'ExecStart=.*?-L=\K[a-z]+(?=://)' "\$unit" | head -1)"
        [ -z "\$port" ] && continue

        if [ "\$proto" = "udp" ] || [ "\$proto" = "quic" ]; then
            # UDP/QUIC are connectionless - a real end-to-end probe isn't
            # reliable here, so this only confirms the socket is still bound.
            ss -uln 2>/dev/null | grep -q ":\${port} " || { systemctl restart "\$name"; log "restarted \$name (\$proto socket missing on port \$port)"; }
        else
            timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/\${port}" 2>/dev/null || { systemctl restart "\$name"; log "restarted \$name (\$proto probe failed on port \$port)"; }
        fi
    done
    trim_log
    sleep "\$INTERVAL"
done
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > "$WATCHDOG_UNIT" <<EOF
[Unit]
Description=Gost tunnel watchdog (probes each tunnel port, restarts on failure)
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

# enable_watchdog [silent]
# Called automatically at the end of every tunnel creation, and also
# reachable directly from the menu (option 7). Safe to call repeatedly -
# `systemctl enable --now` on an already-running service is a no-op, it
# will not interrupt an existing tunnel's watchdog coverage.
enable_watchdog() {
    generate_watchdog_script
    systemctl enable --now gost-watchdog.service > /dev/null 2>&1
    [ "$1" == "silent" ] || echo -e "${C_GREEN}Watchdog enabled (checks every ~15s).${C_RESET}"
}

disable_watchdog() {
    systemctl disable --now gost-watchdog.service > /dev/null 2>&1
    echo -e "${C_GREEN}Watchdog disabled.${C_RESET}"
}

action_watchdog() {
    echo -e "${C_GREEN}Probes each tunnel's port roughly every 15 seconds and restarts only the${C_RESET}"
    echo -e "${C_GREEN}unit that's actually unhealthy. Runs automatically after every tunnel${C_RESET}"
    echo -e "${C_GREEN}you create - use this menu only to check status, disable it, or turn it${C_RESET}"
    echo -e "${C_GREEN}back on manually. Log: $WATCHDOG_LOG${C_RESET}"
    echo -e "${C_CYAN}1. ${C_RESET}Enable"
    echo -e "${C_CYAN}2. ${C_RESET}Disable"
    local opt; opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        enable_watchdog
    else
        disable_watchdog
    fi
}

action_auto_clear_cache() {
    echo -e "${C_YELLOW}Note: dropping page cache does not speed up an already-running tunnel and can briefly hurt performance right after it runs; only useful on memory-starved boxes.${C_RESET}"
    echo -e "${C_CYAN}1. ${C_RESET}Enable"
    echo -e "${C_CYAN}2. ${C_RESET}Disable"
    local opt; opt=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
    if [ "$opt" -eq 1 ]; then
        local days; read -rp $'\e[97mInterval in days: \e[0m' days
        is_number "$days" || { echo -e "${C_RED}Invalid number.${C_RESET}"; return; }
        (crontab -l 2>/dev/null | grep -v drop_caches; echo "0 0 */$days * * sync; echo 3 > /proc/sys/vm/drop_caches") | crontab -
        echo -e "${C_GREEN}Scheduled.${C_RESET}"
    else
        (crontab -l 2>/dev/null | grep -v drop_caches) | crontab - 2>/dev/null
        echo -e "${C_GREEN}Disabled.${C_RESET}"
    fi
}

action_install_bbr() {
    apply_kernel_tuning
    echo -e "${C_CYAN}Optional: also run teddysun/across bbr.sh for alternate congestion-control algorithms (bbrplus/etc)? (y/n)${C_RESET}"
    read -rp "> " ans
    if [ "$ans" == "y" ]; then
        wget -qN --no-check-certificate https://github.com/teddysun/across/raw/master/bbr.sh && chmod +x bbr.sh && bash bbr.sh
    fi
}

action_uninstall() {
    read -rp $'\e[91mWarning\e[33m: this removes Gost and all tunnel data. Continue? (y/n): \e[0m' ans
    [ "$ans" != "y" ] && { echo "Canceled."; return; }
    rm -f /usr/bin/gost_auto_restart.sh "$WATCHDOG_SCRIPT" "$WATCHDOG_LOG"
    (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh | grep -v drop_caches) | crontab - 2>/dev/null
    systemctl stop gost-watchdog.service 2>/dev/null
    systemctl disable gost-watchdog.service 2>/dev/null
    rm -f "$WATCHDOG_UNIT"
    systemctl stop gost_*.service 2>/dev/null
    systemctl disable gost_*.service 2>/dev/null
    rm -f /etc/systemd/system/gost_*.service
    rm -f /usr/local/bin/gost
    rm -rf "$GOST_DIR"
    rm -f "$SYSCTL_FILE" "$LIMITS_FILE"
    systemctl daemon-reload
    echo -e "${C_GREEN}Gost uninstalled.${C_RESET}"
}

main_menu() {
    banner
    echo -e "${C_CYAN}1. ${C_RESET}Gost Tunnel By IP4"
    echo -e "${C_CYAN}2. ${C_RESET}Gost Tunnel By IP6"
    echo -e "${C_CYAN}3. ${C_RESET}Gost Status"
    echo -e "${C_CYAN}4. ${C_RESET}Update Script"
    echo -e "${C_CYAN}5. ${C_RESET}Change Gost Version"
    echo -e "${C_CYAN}6. ${C_RESET}Auto Restart Gost (timed, blind)"
    echo -e "${C_CYAN}7. ${C_RESET}Connection Watchdog (auto-heal, ~15s, on by default after tunnel creation)"
    echo -e "${C_CYAN}8. ${C_RESET}Auto Clear Cache"
    echo -e "${C_CYAN}9. ${C_RESET}Apply Speed/Stability Tuning (BBR + TCP/UDP tuning)"
    echo -e "${C_CYAN}10. ${C_RESET}Uninstall"
    echo -e "${C_CYAN}11. ${C_RESET}Exit"

    local choice; choice=$(read_choice $'\e[97mYour choice: \e[0m' 1 11)
    case "$choice" in
        1) action_create_tunnel 4 ;;
        2) action_create_tunnel 6 ;;
        3) action_status ;;
        4) action_update_script ;;
        5) action_change_version ;;
        6) action_auto_restart ;;
        7) action_watchdog ;;
        8) action_auto_clear_cache ;;
        9) action_install_bbr ;;
        10) action_uninstall ;;
        11) echo -e "${C_GREEN}Bye.${C_RESET}"; exit 0 ;;
    esac
}

# ---------- entry point ----------
require_root
ensure_self_installed
main_menu
