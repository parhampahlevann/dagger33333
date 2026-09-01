#!/bin/bash

# === DaggerConnect Ultimate Installer (TUN Fix Edition) ===
# Smart binary + Status + Full Uninstall + TUN Interface Auto-Setup

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

LAUNCHER="/usr/local/bin/DaggerConnect"
CONFIG_DIR="/etc/DaggerConnect"
CONFIG=""
CONFIG_FMT=""
SERVICE_NAME=""
SERVICE_FILE=""
TRANSPORT=""
SERVER_PUBLIC_IP=""
SERVER_IP=""
SERVER_PORT=""
PORT=""
PSK=""
CLIENT_CONN_POOL="8"

BINARY_URL="https://github.com/parhampahlevann/dagger/releases/download/v1.0/DaggerConnect3.2.zip"

WS_PATH=""
HTTP_DOMAIN=""
HTTP_PATH=""
TUN_LOCAL_IP=""
TUN_PEER_IP=""
TUN_LOCAL_ADDR=""
TUN_REMOTE_ADDR=""
TUN_ENCAP="ipx"
TUN_PROFILE="tcp"
TUN_L4_PORT=""
TUN_IFACE=""
TUN_NAME="dagger0"
TUN_HEARTBEAT_SEC="5"
TUN_IDLE_TIMEOUT_SEC="60"
TUN_MTU="1400"

_ts()   { date '+%H:%M:%S'; }
info()  { echo -e "${DIM}$(_ts)${NC} ${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${DIM}$(_ts)${NC} ${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${DIM}$(_ts)${NC} ${YELLOW}[WARN]${NC}  $*"; }
step()  { echo -e "${DIM}$(_ts)${NC} ${MAGENTA}[STEP]${NC}  $*"; }
error() { echo -e "${DIM}$(_ts)${NC} ${RED}[ERR ]${NC}  $*"; exit 1; }
hr()    { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }

ask() {
    local var="$1" prompt="$2" default="$3"
    local input=""
    if [ -n "$default" ]; then
        echo -ne "${YELLOW}?${NC} $prompt [${default}]: " > /dev/tty
    else
        echo -ne "${YELLOW}?${NC} $prompt: " > /dev/tty
    fi
    if [ -c /dev/tty ]; then
        read -r input < /dev/tty
    else
        read -r input
    fi
    [ -z "$input" ] && [ -n "$default" ] && input="$default"
    eval "$var=\"$input\""
}

ask_required() {
    local var="$1" prompt="$2"
    while true; do
        ask "$var" "$prompt" ""
        eval "local val=\$$var"
        [ -n "$val" ] && break
        warn "This field cannot be empty." > /dev/tty
    done
}

validate_label() { echo "$1" | grep -qE '^[A-Za-z0-9_-]+$'; }
validate_ip() { echo "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }

ask_service_name() {
    local svc_name svc_file
    while true; do
        ask LABEL "Service Name (e.g. iran1, client-home)" ""
        if [ -z "$LABEL" ]; then warn "Service Name cannot be empty."; continue; fi
        if ! validate_label "$LABEL"; then warn "Only letters, numbers, - and _ are allowed."; continue; fi
        svc_name="${LABEL}"
        svc_file="/etc/systemd/system/${svc_name}.service"
        if [ -f "$svc_file" ] || [ -f "${CONFIG_DIR}/${svc_name}.json" ] || [ -f "${CONFIG_DIR}/${svc_name}.yaml" ]; then
            echo ""
            warn "Already exists: ${svc_name}"
            ask OVERWRITE "Overwrite? (y/n)" "n"
            if [ "$OVERWRITE" = "y" ] || [ "$OVERWRITE" = "Y" ]; then break; fi
            info "Enter a different service name."
            echo ""
            continue
        fi
        break
    done
    while true; do
        ask FMT "Config Format (json/yaml)" "json"
        case "$FMT" in json|yaml) break ;; *) warn "Please enter json or yaml." ;; esac
    done
    CONFIG_FMT="$FMT"
    SERVICE_NAME="${LABEL}"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    CONFIG="${CONFIG_DIR}/${SERVICE_NAME}.${CONFIG_FMT}"
    echo ""
    info "Service Name : ${SERVICE_NAME}"
    info "Config File  : ${CONFIG}"
}

download_binary() {
    hr "Downloading Cracked Binary"
    local tmp_dir="/tmp/dagger-install-$$"
    mkdir -p "$tmp_dir"
    
    info "Installing unzip if needed..."
    if ! command -v unzip &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq unzip
        elif command -v yum &>/dev/null; then
            yum install -y -q unzip
        elif command -v dnf &>/dev/null; then
            dnf install -y -q unzip
        fi
    fi
    
    info "Downloading from: $BINARY_URL"
    if ! curl -fsSL -o "$tmp_dir/DaggerConnect.zip" "$BINARY_URL"; then
        error "Failed to download binary."
    fi
    
    info "Extracting..."
    cd "$tmp_dir" || error "Cannot access temp directory"
    if ! unzip -o DaggerConnect.zip; then
        error "Failed to extract zip file."
    fi
    
    find . -maxdepth 1 -type f -exec chmod +x {} \;
    
    local exe_file=""
    for f in DaggerConnect3.2.patched DaggerConnect.patched dagger.patched dagger-cracked core-patched DaggerConnect dagger dagger-core core; do
        if [ -f "$f" ] && file "$f" 2>/dev/null | grep -qE "ELF|executable"; then
            exe_file="$f"
            break
        fi
    done
    
    [ -z "$exe_file" ] && exe_file=$(find . -maxdepth 1 -type f -name "*.patched" | head -1)
    [ -z "$exe_file" ] && exe_file=$(find . -maxdepth 1 -type f -iname "*dagger*" | head -1)
    [ -z "$exe_file" ] && exe_file=$(find . -maxdepth 1 -type f -executable | head -1)
    
    if [ -z "$exe_file" ]; then
        warn "Could not auto-detect binary. Available files:" > /dev/tty
        find . -maxdepth 1 -type f
        ask MANUAL_BIN "Enter the filename manually (without ./)" ""
        [ -f "./$MANUAL_BIN" ] && exe_file="./$MANUAL_BIN" || error "File not found: $MANUAL_BIN"
    fi
    
    info "Found executable: ${BOLD}$exe_file${NC}"
    cp "$exe_file" "$LAUNCHER"
    chmod +x "$LAUNCHER"
    ok "Binary installed to: $LAUNCHER"
    
    cd /
    rm -rf "$tmp_dir"
}

test_binary() {
    info "Testing binary..."
    local output=$($LAUNCHER --version 2>&1)
    local exit_code=$?
    if [ $exit_code -eq 0 ] || echo "$output" | grep -qiE "version|dagger|connect"; then
        ok "Binary is working!"
    else
        warn "Binary test output: $output"
    fi
}

show_status() {
    hr "DaggerConnect Status & Health"
    
    echo ""
    echo -e "${BOLD}${BLUE}1. Binary Status:${NC}"
    if [ -f "$LAUNCHER" ]; then
        ok "Binary exists: $LAUNCHER"
        file "$LAUNCHER" | grep -q "ELF" && ok "Binary is valid ELF executable" || warn "Binary might be corrupted"
        info "Binary size: $(stat -c%s "$LAUNCHER" 2>/dev/null || stat -f%z "$LAUNCHER") bytes"
    else
        error "Binary not found at $LAUNCHER"
    fi
    
    echo ""
    echo -e "${BOLD}${BLUE}2. Running Services:${NC}"
    local services=$(systemctl list-units --type=service --state=running 2>/dev/null | grep -i dagger || true)
    if [ -z "$services" ]; then
        warn "No running DaggerConnect services found"
    else
        echo "$services"
        for svc in $(systemctl list-units --type=service --state=running 2>/dev/null | grep -i dagger | awk '{print $1}'); do
            echo -e "${CYAN}=== $svc ===${NC}"
            systemctl status "$svc" --no-pager -l | head -20
        done
    fi
    
    echo ""
    echo -e "${BOLD}${BLUE}3. TUN Interfaces:${NC}"
    if command -v ip &>/dev/null; then
        ip -br link show | grep -E "dagger|tun|tunl" || warn "No TUN interfaces found"
        echo ""
        info "TUN interface IPs:"
        ip -br addr show | grep -E "dagger|tun|tunl" || warn "No TUN IPs assigned"
    fi
    
    echo ""
    echo -e "${BOLD}${BLUE}4. Listening Ports:${NC}"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -i dagger || warn "No listening ports found for DaggerConnect"
    fi
    
    echo ""
    echo -e "${BOLD}${BLUE}5. Config Files:${NC}"
    if [ -d "$CONFIG_DIR" ]; then
        for cfg in "$CONFIG_DIR"/*; do
            [ -f "$cfg" ] && { echo -e "${CYAN}=== $cfg ===${NC}"; head -30 "$cfg"; }
        done
    else
        warn "Config directory not found: $CONFIG_DIR"
    fi
    
    echo ""
    echo -e "${BOLD}${BLUE}6. Recent Logs (last 15 lines):${NC}"
    for svc in $(systemctl list-units --type=service --all 2>/dev/null | grep -i dagger | awk '{print $1}'); do
        echo -e "${CYAN}=== $svc ===${NC}"
        journalctl -u "$svc" -n 15 --no-pager 2>/dev/null || echo "No logs available"
    done
    
    echo ""
    echo -e "${BOLD}${BLUE}7. Active Connections:${NC}"
    ss -tnp 2>/dev/null | grep -i dagger || warn "No active connections"
}

full_uninstall() {
    hr "Full Uninstall"
    
    warn "This will remove EVERYTHING:"
    echo "  - All DaggerConnect services"
    echo "  - Binary at $LAUNCHER"
    echo "  - Config directory at $CONFIG_DIR"
    echo "  - All TUN interfaces (dagger*)"
    echo "  - All logs and temporary files"
    echo ""
    
    ask CONFIRM "Are you ABSOLUTELY sure? Type 'yes' to continue" "no"
    [ "$CONFIRM" != "yes" ] && { info "Cancelled."; return; }
    
    step "Stopping services..."
    for svc in $(systemctl list-units --type=service --all 2>/dev/null | grep -i dagger | awk '{print $1}' | sed 's/.service//'); do
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "/etc/systemd/system/${svc}.service"
        ok "Removed service: $svc"
    done
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null
    
    step "Removing TUN interfaces..."
    for iface in $(ip -br link show 2>/dev/null | grep -E "dagger|tun0" | awk '{print $1}'); do
        ip link delete "$iface" 2>/dev/null && ok "Removed TUN: $iface"
    done
    
    step "Removing binary..."
    rm -f "$LAUNCHER" && ok "Removed binary"
    
    step "Removing configs..."
    rm -rf "$CONFIG_DIR" && ok "Removed config directory"
    
    step "Removing temp files..."
    rm -rf /tmp/dagger-install-* /tmp/DaggerConnect* 2>/dev/null
    
    echo ""
    ok "Full uninstall complete! System is clean."
}

detect_server_public_ip() {
    local ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    return 1
}

ask_server_public_ip() {
    echo ""
    local detected=$(detect_server_public_ip)
    if [ -n "$detected" ]; then
        info "Public IP : ${detected} (auto-detected)"
        ask USE_DETECTED "Use this IP? (y/n)" "y"
        if [ "$USE_DETECTED" = "y" ] || [ "$USE_DETECTED" = "Y" ]; then
            SERVER_PUBLIC_IP="$detected"
            return
        fi
    fi
    while true; do
        ask SERVER_PUBLIC_IP "Enter server public IP manually" "$detected"
        [ -z "$SERVER_PUBLIC_IP" ] && { warn "IP cannot be empty."; continue; }
        validate_ip "$SERVER_PUBLIC_IP" && break
        warn "Invalid IP format."
    done
    info "Public IP : ${SERVER_PUBLIC_IP}"
}

ask_transport() {
    echo ""
    echo -e "  ${BOLD}Available Transports:${NC}"
    echo "    1) tcp     — Raw TCP tunnel"
    echo "    2) ws      — WebSocket tunnel"
    echo "    3) wss     — WebSocket Secure (TLS)"
    echo "    4) http    — HTTP Mimicry"
    echo "    5) https   — HTTP Mimicry Secure (TLS)"
    echo "    6) tun     — TUN kernel interface"
    echo ""
    while true; do
        ask T_CHOICE "Transport" "1"
        case "$T_CHOICE" in
            1|tcp)   TRANSPORT="tcp";   break ;;
            2|ws)    TRANSPORT="ws";    break ;;
            3|wss)   TRANSPORT="wss";   break ;;
            4|http)  TRANSPORT="http";  break ;;
            5|https) TRANSPORT="https"; break ;;
            6|tun)   TRANSPORT="tun";   break ;;
            *) warn "Please enter 1-6." ;;
        esac
    done
    info "Transport : ${TRANSPORT}"
}

ask_ports() {
    echo ""
    echo -e "  Ports to forward (e.g. 22, 2222=22, 800,3005)"
    PORTS=()
    while true; do
        ask P "Port (empty to finish)" ""
        [ -z "$P" ] && break
        local ptype
        while true; do
            ask ptype "Type for '$P' (tcp/udp)" "tcp"
            ptype="$(echo "$ptype" | tr '[:upper:]' '[:lower:]')"
            case "$ptype" in tcp|udp) break ;; *) warn "Please type 'tcp' or 'udp'." ;; esac
        done
        IFS="," read -ra _parts <<< "$P"
        for _p in "${_parts[@]}"; do
            _p="${_p// /}"
            [ -z "$_p" ] && continue
            PORTS+=("${_p}/${ptype}")
        done
    done
    [ ${#PORTS[@]} -eq 0 ] && { warn "No ports defined. Adding default 2222=22."; PORTS=("2222=22/tcp"); }
}

parse_port_entry() {
    local entry="$1" ptype="tcp" pbind ptarget
    [[ "$entry" == */* ]] && { ptype="${entry##*/}"; entry="${entry%/*}"; }
    if [[ "$entry" == *=* ]]; then
        pbind="${entry%%=*}"; ptarget="${entry#*=}"
    else
        pbind="$entry"; ptarget="$entry"
    fi
    echo "${ptype}|${pbind}|${ptarget}"
}

build_ports_json() {
    local first=1 p ptype pbind ptarget
    for p in "$@"; do
        IFS='|' read -r ptype pbind ptarget <<< "$(parse_port_entry "$p")"
        if [ "$first" = "1" ]; then
            printf '        { "type": "%s", "bind": "0.0.0.0:%s", "target": "127.0.0.1:%s" }' "$ptype" "$pbind" "$ptarget"
            first=0
        else
            printf ',\n        { "type": "%s", "bind": "0.0.0.0:%s", "target": "127.0.0.1:%s" }' "$ptype" "$pbind" "$ptarget"
        fi
    done
}

write_server_config_tcp() {
    local port="$1" psk="$2"; shift 2
    local ports_json=$(build_ports_json "$@")
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "tcp",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "tcp",
      "maps": [
${ports_json}
      ]
    }
  ]
}
EOF
}

write_client_config_tcp() {
    local server_ip="$1" server_port="$2" psk="$3"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "tcp",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "tcp",
      "addr": "${server_ip}:${server_port}",
      "connection_pool": ${CLIENT_CONN_POOL},
      "retry_interval": 3,
      "dial_timeout": 10
    }
  ]
}
EOF
}

write_server_config_ws() {
    local port="$1" psk="$2" ws_path="$3"; shift 3
    local ports_json=$(build_ports_json "$@")
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "ws",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "ws",
      "maps": [
${ports_json}
      ]
    }
  ],
  "ws_settings": { "path": "${ws_path}" }
}
EOF
}

write_client_config_ws() {
    local server_ip="$1" server_port="$2" psk="$3" ws_path="$4"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "ws",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "ws",
      "addr": "${server_ip}:${server_port}",
      "connection_pool": ${CLIENT_CONN_POOL},
      "retry_interval": 3,
      "dial_timeout": 10
    }
  ],
  "ws_settings": { "path": "${ws_path}" }
}
EOF
}

write_server_config_http() {
    local port="$1" psk="$2" http_domain="$3" http_path="$4"; shift 4
    local ports_json=$(build_ports_json "$@")
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "http",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "http",
      "maps": [
${ports_json}
      ]
    }
  ],
  "http_settings": { "fake_domain": "${http_domain}", "path": "${http_path}" }
}
EOF
}

write_client_config_http() {
    local server_ip="$1" server_port="$2" psk="$3" http_domain="$4" http_path="$5"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "http",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "http",
      "addr": "${server_ip}:${server_port}",
      "connection_pool": ${CLIENT_CONN_POOL},
      "retry_interval": 3,
      "dial_timeout": 10
    }
  ],
  "http_settings": { "fake_domain": "${http_domain}", "path": "${http_path}" }
}
EOF
}

# 🎯 FIXED: TUN Server Config with health_check and proper settings
write_server_config_tun() {
    local port="$1" psk="$2" local_ip="$3" peer_ip="$4" local_addr="$5" remote_addr="$6"; shift 6
    local ports_json=$(build_ports_json "$@")
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" << EOF
{
  "mode": "server",
  "transport": "tun",
  "psk": "${psk}",
  "log_level": "info",
  "listeners": [
    {
      "addr": "0.0.0.0:${port}",
      "transport": "tun",
      "maps": [
${ports_json}
      ]
    }
  ],
  "tun": {
    "encapsulation": "${TUN_ENCAP}",
    "name": "${TUN_NAME}",
    "local_addr": "${local_addr}",
    "remote_addr": "${remote_addr}",
    "mtu": ${TUN_MTU},
    "heartbeat_sec": ${TUN_HEARTBEAT_SEC},
    "idle_timeout_sec": ${TUN_IDLE_TIMEOUT_SEC}
  },
  "ipx": {
    "mode": "server",
    "profile": "${TUN_PROFILE}",
    "listen_ip": "${local_ip}",
    "dst_ip": "${peer_ip}"
  },
  "health_check": {
    "enabled": true,
    "interval_sec": 10,
    "timeout_sec": 5
  }
}
EOF
}

# 🎯 FIXED: TUN Client Config with health_check and proper settings
write_client_config_tun() {
    local server_port="$1" psk="$2" local_ip="$3" peer_ip="$4" local_addr="$5" remote_addr="$6"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG" << EOF
{
  "mode": "client",
  "transport": "tun",
  "psk": "${psk}",
  "log_level": "info",
  "paths": [
    {
      "transport": "tun",
      "addr": "${peer_ip}:${server_port}",
      "retry_interval": 3,
      "dial_timeout": 30
    }
  ],
  "tun": {
    "encapsulation": "${TUN_ENCAP}",
    "name": "${TUN_NAME}",
    "local_addr": "${local_addr}",
    "remote_addr": "${remote_addr}",
    "mtu": ${TUN_MTU},
    "heartbeat_sec": ${TUN_HEARTBEAT_SEC},
    "idle_timeout_sec": ${TUN_IDLE_TIMEOUT_SEC}
  },
  "ipx": {
    "mode": "client",
    "profile": "${TUN_PROFILE}",
    "listen_ip": "${local_ip}",
    "dst_ip": "${peer_ip}"
  },
  "health_check": {
    "enabled": true,
    "interval_sec": 10,
    "timeout_sec": 5
  }
}
EOF
}

# 🆕 NEW: Setup TUN interface manually before service starts
setup_tun_interface() {
    local mode="$1"  # "server" or "client"
    local tun_name="$2"
    local local_addr="$3"
    local remote_addr="$4"
    
    hr "Setting up TUN Interface: ${tun_name}"
    
    step "Loading TUN kernel module..."
    modprobe tun 2>/dev/null || true
    
    # Check if interface already exists
    if ip link show "$tun_name" &>/dev/null; then
        warn "Interface $tun_name already exists. Removing..."
        ip link delete "$tun_name" 2>/dev/null
        sleep 1
    fi
    
    step "Creating TUN interface: $tun_name"
    ip tuntap add dev "$tun_name" mode tun user root 2>/dev/null || \
    ip tuntap add dev "$tun_name" mode tun 2>/dev/null || {
        warn "ip tuntap failed, trying alternative method..."
    }
    
    if ! ip link show "$tun_name" &>/dev/null; then
        error "Failed to create TUN interface $tun_name"
    fi
    ok "Interface $tun_name created"
    
    step "Bringing interface up..."
    ip link set "$tun_name" up
    ip link set "$tun_name" mtu ${TUN_MTU:-1400}
    ok "Interface is UP with MTU ${TUN_MTU:-1400}"
    
    step "Assigning IP addresses..."
    if [ "$mode" = "server" ]; then
        ip addr add "${local_addr}/30" dev "$tun_name" 2>/dev/null || \
        ip addr add "${local_addr}/24" dev "$tun_name"
        ok "Server IP assigned: ${local_addr}"
        # Add route to client
        ip route add "${remote_addr}/32" dev "$tun_name" 2>/dev/null || true
        ok "Route to client added: ${remote_addr}"
    else
        ip addr add "${local_addr}/30" dev "$tun_name" 2>/dev/null || \
        ip addr add "${local_addr}/24" dev "$tun_name"
        ok "Client IP assigned: ${local_addr}"
        # Add route to server
        ip route add "${remote_addr}/32" dev "$tun_name" 2>/dev/null || true
        ok "Route to server added: ${remote_addr}"
    fi
    
    echo ""
    info "TUN Interface Status:"
    ip -br addr show "$tun_name"
    echo ""
    ok "TUN interface setup complete!"
}

install_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=DaggerConnect Tunnel (${SERVICE_NAME})
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/sbin/modprobe tun
ExecStart=${LAUNCHER} -c ${CONFIG}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=DaggerConnect
# Ensure it has permissions to create TUN
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    ok "Service installed: ${SERVICE_NAME}"
}

start_service() {
    systemctl restart "$SERVICE_NAME"
    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Service is running."
    else
        warn "Service failed to start. Checking logs..."
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager
    fi
}

install_server() {
    hr "Install Server (Cracked Version)"
    download_binary
    test_binary
    echo ""
    ask_service_name
    echo ""
    ask_server_public_ip
    echo ""
    ask_transport
    echo ""
    if [ "$TRANSPORT" = "tun" ]; then
        PORT="8443"
    else
        ask PORT "Listen port" "8443"
        echo ""
    fi
    ask_required PSK "PSK (must match client)"
    echo ""
    case "$TRANSPORT" in
        ws|wss)
            ask WS_PATH "WebSocket path" "/ws"
            echo "" ;;
        http|https)
            ask HTTP_DOMAIN "Fake domain (e.g. www.google.com)" "www.google.com"
            ask HTTP_PATH "Fake path (e.g. /search)" "/search"
            echo "" ;;
        tun)
            echo -e "  ${BOLD}TUN Configuration:${NC}"
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Server real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Client real IP"
            ask_required TUN_LOCAL_ADDR "TUN local IP (server side, e.g. 10.0.0.1)"
            ask_required TUN_REMOTE_ADDR "TUN remote IP (client side, e.g. 10.0.0.2)"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            ask TUN_MTU "MTU (1400 recommended)" "1400"
            echo ""
            
            # 🆕 Setup TUN interface BEFORE writing config
            setup_tun_interface "server" "$TUN_NAME" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR"
            echo "" ;;
    esac
    ask_ports
    echo ""
    case "$TRANSPORT" in
        tcp)  write_server_config_tcp "$PORT" "$PSK" "${PORTS[@]}" ;;
        ws)   write_server_config_ws "$PORT" "$PSK" "$WS_PATH" "${PORTS[@]}" ;;
        http) write_server_config_http "$PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" "${PORTS[@]}" ;;
        tun)  write_server_config_tun "$PORT" "$PSK" "$TUN_LOCAL_IP" "$TUN_PEER_IP" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" "${PORTS[@]}" ;;
    esac
    ok "Config written: ${CONFIG}"
    install_service
    start_service
    echo ""
    echo -e "${GREEN}${BOLD}Server installed successfully!${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Public IP : ${BOLD}${SERVER_PUBLIC_IP}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    echo -e "  Port      : ${BOLD}${PORT}${NC}"
    echo -e "  PSK       : ${BOLD}${PSK}${NC}"
    [ "$TRANSPORT" = "ws" ] && echo -e "  WS Path   : ${BOLD}${WS_PATH}${NC}"
    if [ "$TRANSPORT" = "http" ]; then
        echo -e "  Fake Domain : ${BOLD}${HTTP_DOMAIN}${NC}"
        echo -e "  Fake Path   : ${BOLD}${HTTP_PATH}${NC}"
    fi
    if [ "$TRANSPORT" = "tun" ]; then
        echo -e "  TUN Local : ${BOLD}${TUN_LOCAL_ADDR}${NC}"
        echo -e "  TUN Peer  : ${BOLD}${TUN_REMOTE_ADDR}${NC}"
        echo -e "  Wire IP   : ${BOLD}${TUN_LOCAL_IP} -> ${TUN_PEER_IP}${NC}"
        echo -e "  MTU       : ${BOLD}${TUN_MTU}${NC}"
    fi
    echo -e "  Config    : ${BOLD}${CONFIG}${NC}"
    echo ""
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""
}

install_client() {
    hr "Install Client (Cracked Version)"
    download_binary
    test_binary
    echo ""
    ask_service_name
    echo ""
    ask_transport
    echo ""
    [ "$TRANSPORT" != "tun" ] && ask CLIENT_CONN_POOL "Connections per path" "8"
    if [ "$TRANSPORT" = "tun" ]; then
        SERVER_PORT="8443"
    else
        while true; do
            ask SERVER_ADDR "Server IP And Port (e.g. 1.1.1.1:8443)" ""
            SERVER_IP="${SERVER_ADDR%%:*}"
            SERVER_PORT="${SERVER_ADDR##*:}"
            if [ -z "$SERVER_IP" ] || [ -z "$SERVER_PORT" ] || [ "$SERVER_IP" = "$SERVER_PORT" ]; then
                warn "Invalid format. Use IP:PORT"
            else
                break
            fi
        done
        echo ""
    fi
    ask_required PSK "PSK (must match server)"
    echo ""
    case "$TRANSPORT" in
        ws|wss)
            ask WS_PATH "WebSocket path (must match server)" "/ws"
            echo "" ;;
        http|https)
            ask HTTP_DOMAIN "Fake domain (must match server)" "www.google.com"
            ask HTTP_PATH "Fake path (must match server)" "/search"
            echo "" ;;
        tun)
            echo -e "  ${BOLD}TUN Configuration:${NC}"
            _DEFAULT_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
            ask TUN_LOCAL_IP "Client real IP" "${_DEFAULT_IP}"
            ask_required TUN_PEER_IP "Server real IP"
            ask_required TUN_LOCAL_ADDR "TUN local IP (client side, e.g. 10.0.0.2)"
            ask_required TUN_REMOTE_ADDR "TUN remote IP (server side, e.g. 10.0.0.1)"
            TUN_LOCAL_ADDR="$(echo "$TUN_LOCAL_ADDR" | cut -d/ -f1)"
            TUN_REMOTE_ADDR="$(echo "$TUN_REMOTE_ADDR" | cut -d/ -f1)"
            ask TUN_MTU "MTU (1400 recommended)" "1400"
            echo ""
            
            # 🆕 Setup TUN interface BEFORE writing config
            setup_tun_interface "client" "$TUN_NAME" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR"
            echo "" ;;
    esac
    case "$TRANSPORT" in
        tcp)  write_client_config_tcp "$SERVER_IP" "$SERVER_PORT" "$PSK" ;;
        ws)   write_client_config_ws "$SERVER_IP" "$SERVER_PORT" "$PSK" "$WS_PATH" ;;
        http) write_client_config_http "$SERVER_IP" "$SERVER_PORT" "$PSK" "$HTTP_DOMAIN" "$HTTP_PATH" ;;
        tun)  write_client_config_tun "$SERVER_PORT" "$PSK" "$TUN_LOCAL_IP" "$TUN_PEER_IP" "$TUN_LOCAL_ADDR" "$TUN_REMOTE_ADDR" ;;
    esac
    ok "Config written: ${CONFIG}"
    install_service
    start_service
    echo ""
    echo -e "${GREEN}${BOLD}Client installed successfully!${NC}"
    echo ""
    echo -e "  Service   : ${BOLD}${SERVICE_NAME}${NC}"
    echo -e "  Transport : ${BOLD}${TRANSPORT}${NC}"
    if [ "$TRANSPORT" = "tun" ]; then
        echo -e "  Server    : ${BOLD}${TUN_PEER_IP}${NC}"
        echo -e "  TUN Local : ${BOLD}${TUN_LOCAL_ADDR}${NC}"
        echo -e "  TUN Peer  : ${BOLD}${TUN_REMOTE_ADDR}${NC}"
        echo -e "  MTU       : ${BOLD}${TUN_MTU}${NC}"
    else
        echo -e "  Server    : ${BOLD}${SERVER_IP}:${SERVER_PORT}${NC}"
    fi
    echo -e "  PSK       : ${BOLD}${PSK}${NC}"
    [ "$TRANSPORT" = "ws" ] && echo -e "  WS Path   : ${BOLD}${WS_PATH}${NC}"
    if [ "$TRANSPORT" = "http" ]; then
        echo -e "  Fake Domain : ${BOLD}${HTTP_DOMAIN}${NC}"
        echo -e "  Fake Path   : ${BOLD}${HTTP_PATH}${NC}"
    fi
    echo -e "  Config    : ${BOLD}${CONFIG}${NC}"
    echo ""
    echo -e "  Logs      : journalctl -u ${SERVICE_NAME} -f"
    echo ""
    # 🆕 Test TUN connection
    if [ "$TRANSPORT" = "tun" ]; then
        echo ""
        info "Testing TUN connectivity in 5 seconds..."
        sleep 5
        if ping -c 2 -W 2 "$TUN_REMOTE_ADDR" &>/dev/null; then
            ok "TUN tunnel is working! You can ping $TUN_REMOTE_ADDR"
        else
            warn "TUN ping failed. Check logs with: journalctl -u ${SERVICE_NAME} -f"
        fi
    fi
    echo ""
}

show_banner() {
    echo ""
    echo -e "  ${CYAN}${BOLD}DaggerConnect Ultimate Installer (TUN Fix Edition)${NC}"
    echo ""
}

show_menu() {
    echo -e "${BOLD}Select an option:${NC}"
    echo ""
    echo -e "${GREEN}Installation:${NC}"
    echo "  1) Install Server (with cracked binary)"
    echo "  2) Install Client (with cracked binary)"
    echo ""
    echo -e "${CYAN}Management:${NC}"
    echo "  3) Status & Health Check"
    echo "  4) Re-download binary only"
    echo "  5) Test installed binary"
    echo ""
    echo -e "${RED}Cleanup:${NC}"
    echo "  6) Full Uninstall - Remove EVERYTHING"
    echo ""
    echo "  0) Exit"
    echo ""
    ask CHOICE "Choice" "1"
}

pause() {
    echo ""
    echo -ne "${YELLOW}?${NC} Press Enter to return to the menu: " > /dev/tty
    if [ -c /dev/tty ]; then
        read -r _ < /dev/tty
    else
        read -r _
    fi
}

[ "$EUID" -ne 0 ] && { echo -e "${RED}[ERR ]${NC} Run as root: sudo bash install.sh"; exit 1; }

while true; do
    clear 2>/dev/null || true
    show_banner
    show_menu
    case "$CHOICE" in
        1) install_server ;;
        2) install_client ;;
        3) show_status ;;
        4) download_binary && test_binary ;;
        5) test_binary ;;
        6) full_uninstall ;;
        0) echo -e "\n  ${CYAN}Bye.${NC}\n"; exit 0 ;;
        *) warn "Invalid choice" ;;
    esac
    pause
done
