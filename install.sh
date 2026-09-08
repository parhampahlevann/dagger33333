#!/bin/bash
#
# Gost Ip6 Script v2.5.1 (hardened/fixed fork)
# Original by Masoud Gb - Special Thanks Hamid Router
#
# Fixes in v2.5.1:
#  - Added 'kcp' protocol to UDP socket watchdog check (prevented 15s restart loop).
#  - Handled distinct asset formats for Gost v2 (.gz) and v3 (.tar.gz).
#  - Added automatic CPU architecture detection (amd64 / arm64).
#  - Fixed IPv4 octal-base parsing error for numbers with leading zeros.
#  - Optimized watchdog socket lookup regex using word boundaries.
#  - Fixed systemctl daemon-reload placement outside tunnel generation loops.
#  - Added iproute2 to dependencies for reliable 'ss' execution.
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
    local prompt="$1" min="$2" max="$3" val
    while true; do
        read -rp "$prompt" val
        if is_number "$val" && [ "$val" -ge "$min" ] && [ "$val" -le "$max" ]; then
            echo "$val"; return 0
        fi
        echo -e "${C_RED}Invalid option, try again.${C_RESET}" >&2
    done
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        *) echo "amd64" ;;
    esac
}

looks_like_ipv4() {
    local ip="$1" IFS=. o1 o2 o3 o4
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    read -r o1 o2 o3 o4 <<< "${ip}"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ "$((10#$o))" -le 255 ] 2>/dev/null || return 1
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
    echo -e "${C_MAGENTA}Gost Ip6 Script v2.5.1 (hardened & fixed)${C_RESET}"
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

# ---------- kernel / TCP+UDP tuning ----------
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
        echo "net.core.netdev_max_backlog = 250000"
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
        echo "fs.file-max = 2097152"
        if [ "$bbr_ok" -eq 1 ]; then
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
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
WGET_OPTS="--timeout=20 --tries=2 --waitretry=2"
CURL_OPTS="--connect-timeout 10 --max-time 25 --retry 2 --retry-delay 2 -s"
GH_MIRRORS=("" "https://gh-proxy.com/" "https://gh-proxy.org/" "https://ghproxy.net/")

GOST2_PINNED_VERSION="2.11.5"
GOST3_PINNED_VERSION="3.3.0"

is_elf_binary() { [ -f "$1" ] && [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; }

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

resolve_gost_release() {
    local major="$1" arch="$2" repo pinned version url asset

    if [ "$major" -eq 1 ]; then
        repo="ginuerzh/gost"
        pinned="$GOST2_PINNED_VERSION"
        version="$pinned"
        asset="gost-linux-${arch}-${version}.gz"
        url="https://github.com/${repo}/releases/download/v${version}/${asset}"
    else
        repo="go-gost/gost"
        pinned="$GOST3_PINNED_VERSION"

        version=$(curl $CURL_OPTS -o /dev/null -w '%{redirect_url}' "https://github.com/${repo}/releases/latest" 2>/dev/null \
                  | grep -oE '[^/]+$' | sed 's/^v//')

        if [ -z "$version" ]; then
            version=$(curl $CURL_OPTS "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
                      | grep -oP '"tag_name":\s*"v?\K[^"]+' | head -n1)
        fi

        if [ -z "$version" ]; then
            echo -e "${C_YELLOW}Could not resolve latest version for ${repo} - using pinned ${pinned}.${C_RESET}" >&2
            version="$pinned"
        fi

        asset="gost_${version}_linux_${arch}.tar.gz"
        url="https://github.com/${repo}/releases/download/v${version}/${asset}"
    fi

    echo "${version} ${url} ${asset} ${repo}"
}

verify_checksum() {
    local file="$1" repo="$2" version="$3" asset="$4" sums="/tmp/gost_checksums_$$.txt" expected actual

    if ! fetch_with_mirrors "https://github.com/${repo}/releases/download/v${version}/checksums.txt" "$sums"; then
        return 0
    fi

    expected=$(grep "  ${asset}\$" "$sums" | awk '{print $1}')
    rm -f "$sums"
    [ -z "$expected" ] && return 0

    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo -e "${C_RED}Checksum mismatch for ${asset}.${C_RESET}"
        return 1
    fi
    echo -e "${C_GREEN}Checksum verified.${C_RESET}"
    return 0
}

install_gost() {
    local version_choice="$1"
    apt-get update -qq && apt-get install -y -qq wget nano tar curl gzip iproute2 > /dev/null

    local arch; arch=$(detect_arch)
    local resolved version url asset repo
    resolved=$(resolve_gost_release "$version_choice" "$arch")
    read -r version url asset repo <<< "$resolved"

    echo -e "${C_GREEN}Installing gost ${version} (${arch})...${C_RESET}"

    local download_target="/tmp/${asset}"
    if ! fetch_with_mirrors "$url" "$download_target"; then
        echo -e "${C_RED}Download failed on all mirrors. Check network connectivity.${C_RESET}"
        return 1
    fi

    if [ "$version_choice" -eq 2 ]; then
        verify_checksum "$download_target" "$repo" "$version" "$asset" || { rm -f "$download_target"; return 1; }
        tar -xzf "$download_target" -C /usr/local/bin/ gost 2>/dev/null
    else
        gzip -d -c "$download_target" > /usr/local/bin/gost 2>/dev/null
    fi

    chmod +x /usr/local/bin/gost 2>/dev/null
    rm -f "$download_target"

    if ! is_elf_binary /usr/local/bin/gost; then
        echo -e "${C_RED}Installed file is not a valid ELF binary. Aborting.${C_RESET}"
        rm -f /usr/local/bin/gost
        return 1
    fi

    echo -e "${C_GREEN}Gost ${version} installed successfully.${C_RESET}"
}

ensure_gost_for_protocol() {
    local protocol="$1"

    if [ ! -x /usr/local/bin/gost ]; then
        if [ "$protocol" == "grpc" ] || [ "$protocol" == "quic" ]; then
            echo -e "${C_YELLOW}${protocol} requires Gost 3.x - installing automatically.${C_RESET}"
            install_gost 2
            return $?
        fi
        echo -e "${C_GREEN}Gost is not installed yet.${C_RESET}"
        echo -e "${C_CYAN}1. ${C_RESET}Gost 2.x (stable, official v2.11.5)"
        echo -e "${C_CYAN}2. ${C_RESET}Gost 3.x (latest, required for grpc/quic)"
        local v; v=$(read_choice $'\e[97mYour choice: \e[0m' 1 2)
        install_gost "$v"
        return $?
    fi

    if [ "$protocol" == "grpc" ] || [ "$protocol" == "quic" ]; then
        local ver_line
        ver_line=$(/usr/local/bin/gost -V 2>&1 | head -1)
        if echo "$ver_line" | grep -qE '(^| )gost( |v)?2\.'; then
            echo -e "${C_YELLOW}Installed Gost is 2.x - upgrading to 3.x for ${protocol}...${C_RESET}"
            install_gost 2
            return $?
        fi
    fi
    return 0
}

# ---------- systemd tunnel builder ----------
build_tunnel_service() {
    local unit_name="$1" destination_ip="$2" ports_csv="$3" protocol="$4"

    local suffix=""
    case "$protocol" in
        tcp)  suffix="?keepalive=true&keepalive.idle=60s&keepalive.interval=10s&keepalive.count=6" ;;
        udp)  suffix="?keepalive=true&ttl=10s" ;;
        quic) suffix="?keepAlive=true&ttl=10s" ;;
        kcp)  suffix="?kcp.mode=fast" ;;
    esac

    IFS=',' read -ra port_array <<< "$ports_csv"
    local port_count=${#port_array[@]}
    local max_ports_per_unit=1000
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
    done

    systemctl daemon-reload
    for ((file_index = 0; file_index < file_count; file_index++)); do
        systemctl restart "${unit_name}_${file_index}.service"
    done

    apply_mss_clamp
    enable_watchdog silent

    echo -e "${C_GREEN}Tunnel configuration applied (${file_count} service unit(s)). Watchdog is active.${C_RESET}"
}

apply_mss_clamp() {
    command -v iptables &>/dev/null || return 0
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        echo -e "${C_GREEN}MSS clamping enabled.${C_RESET}"
    fi
}

prompt_protocol() {
    echo -e "${C_GREEN}Select the protocol:${C_RESET}" >&2
    echo -e "${C_CYAN}1. ${C_RESET}tcp   plain TCP relay" >&2
    echo -e "${C_CYAN}2. ${C_RESET}udp   plain UDP relay" >&2
    echo -e "${C_CYAN}3. ${C_RESET}grpc  HTTP/2 + TLS wrapped (forces Gost 3.x)" >&2
    echo -e "${C_CYAN}4. ${C_RESET}quic  UDP + TLS1.3 (forces Gost 3.x)" >&2
    echo -e "${C_CYAN}5. ${C_RESET}kcp   UDP-based FEC for lossy links" >&2
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
        echo -e "${C_RED}Invalid IPv4 address format.${C_RESET}"
        return
    fi
    if [ "$ip_version" -eq 6 ] && ! looks_like_ipv6 "$destination_ip"; then
        echo -e "${C_RED}Invalid IPv6 address format.${C_RESET}"
        return
    fi

    ports=$(prompt_ports) || return
    protocol=$(prompt_protocol)

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
        echo -e "${C_GREEN}Backed up to ${backup}${C_RESET}"
    fi

    local tmp="/tmp/gost_install_update.sh"
    if ! wget -q -O "$tmp" "$REPO_UPDATE_URL" || [ ! -s "$tmp" ] || ! head -c 20 "$tmp" | grep -q '^#!'; then
        echo -e "${C_RED}Download failed or invalid script. Canceled.${C_RESET}"
        rm -f "$tmp"
        return 1
    fi

    mv -f "$tmp" "$GOST_DIR/install.sh"
    chmod +x "$GOST_DIR/install.sh"
    echo -e "${C_GREEN}Updated. Restarting...${C_RESET}"
    exec bash "$GOST_DIR/install.sh"
}

action_change_version() {
    echo -e "${C_CYAN}1. ${C_RESET}Gost 2.x (v2.11.5 stable)"
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
    else
        rm -f /usr/bin/gost_auto_restart.sh
        (crontab -l 2>/dev/null | grep -v gost_auto_restart.sh) | crontab - 2>/dev/null
        echo -e "${C_GREEN}Auto restart disabled.${C_RESET}"
    fi
}

# ---------- watchdog ----------
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

        if [ "\$proto" = "udp" ] || [ "\$proto" = "quic" ] || [ "\$proto" = "kcp" ]; then
            ss -uln 2>/dev/null | grep -qE "[: ]\${port}\b" || { systemctl restart "\$name"; log "restarted \$name (\$proto socket missing on port \$port)"; }
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
Description=Gost tunnel watchdog
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
    generate_watchdog_script
    systemctl enable --now gost-watchdog.service > /dev/null 2>&1
    [ "$1" == "silent" ] || echo -e "${C_GREEN}Watchdog enabled (checks every ~15s).${C_RESET}"
}

disable_watchdog() {
    systemctl disable --now gost-watchdog.service > /dev/null 2>&1
    echo -e "${C_GREEN}Watchdog disabled.${C_RESET}"
}

action_watchdog() {
    echo -e "${C_GREEN}Watchdog auto-heals tunnels every ~15 seconds. Log: $WATCHDOG_LOG${C_RESET}"
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
    echo -e "${C_CYAN}Optional: run external bbr script? (y/n)${C_RESET}"
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
    echo -e "${C_CYAN}7. ${C_RESET}Connection Watchdog (auto-heal, ~15s)"
    echo -e "${C_CYAN}8. ${C_RESET}Auto Clear Cache"
    echo -e "${C_CYAN}9. ${C_RESET}Apply Speed/Stability Tuning (BBR + Sysctl)"
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
