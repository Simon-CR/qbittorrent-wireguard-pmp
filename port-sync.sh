#!/bin/bash

# qBittorrent WireGuard Port Sync Script
# Monitors WireGuard listening port and updates qBittorrent when it changes
# Designed for Debian systems with qBittorrent Web UI and WireGuard

# Check if we're running with bash, not sh
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash, not sh"
    echo "Please run with: bash $0 or ./$0"
    exit 1
fi

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/port-sync.log"
DEBUG="${DEBUG:-0}"
QBITTORRENT_HOST="${QBITTORRENT_HOST:-localhost}"
# Allow service env var QB_PORT or QBITTORRENT_PORT to override default 8080
QBITTORRENT_PORT="${QBITTORRENT_PORT:-${QB_PORT:-8080}}"
QBITTORRENT_URL="http://${QBITTORRENT_HOST}:${QBITTORRENT_PORT}"
QBITTORRENT_RESTART_COMMAND="${QBITTORRENT_RESTART_COMMAND:-${QBT_RESTART_COMMAND:-}}"
QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:-${QB_USERNAME:-}}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-${QB_PASSWORD:-}}"
PORT_SYNC_TMPDIR_DEFAULT="${PORT_SYNC_TMPDIR:-${TMPDIR:-${SCRIPT_DIR}/tmp}}"
PORT_SYNC_TMPDIR="${PORT_SYNC_TMPDIR_DEFAULT%/}"

if [[ ! -d "$PORT_SYNC_TMPDIR" ]]; then
    if ! mkdir -p "$PORT_SYNC_TMPDIR"; then
        echo "Error: Unable to create temporary directory at $PORT_SYNC_TMPDIR" >&2
        exit 1
    fi
fi

chmod 700 "$PORT_SYNC_TMPDIR" 2>/dev/null || true
export TMPDIR="$PORT_SYNC_TMPDIR"

if ! QBITTORRENT_COOKIE_JAR="$(mktemp "${TMPDIR}/qbittorrent_cookie_XXXXXX")"; then
    echo "Error: Unable to create temporary cookie jar" >&2
    exit 1
fi
QBITTORRENT_LAST_PREFS=""
QBITTORRENT_LAST_MAINDATA=""
WG_INTERFACE="${WG_INTERFACE:-wg0}"  # Default WireGuard interface name

cleanup() {
    if [[ -n "$QBITTORRENT_COOKIE_JAR" && -f "$QBITTORRENT_COOKIE_JAR" ]]; then
        rm -f "$QBITTORRENT_COOKIE_JAR"
    fi
}

trap cleanup EXIT

# Colored logging function
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "${CYAN}${message}${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo -e "${RED}${message}${NC}" | tee -a "$LOG_FILE"
}

log_success() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1"
    echo -e "${GREEN}${message}${NC}" | tee -a "$LOG_FILE"
}

log_warning() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1"
    echo -e "${YELLOW}${message}${NC}" | tee -a "$LOG_FILE"
}

# Debug logging (only when DEBUG=1)
debug() {
    if [[ "$DEBUG" == "1" ]]; then
        local message="[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $1"
        echo -e "${BLUE}${message}${NC}" | tee -a "$LOG_FILE" >&2
    fi
}

qbittorrent_login() {
    if [[ -n "$QBITTORRENT_USERNAME" && -n "$QBITTORRENT_PASSWORD" ]]; then
        debug "Logging into qBittorrent WebUI"
        local login_url="http://${QBITTORRENT_HOST}:${QBITTORRENT_PORT}/api/v2/auth/login"
        local response
        response=$(curl -sS -X POST "$login_url" \
            -d "username=$QBITTORRENT_USERNAME" \
            -d "password=$QBITTORRENT_PASSWORD" \
            -c "$QBITTORRENT_COOKIE_JAR" \
            --max-time 10)
        if [[ "$response" != "Ok." ]]; then
            log_error "qBittorrent login failed: $response"
            return 1
        fi
        debug "qBittorrent login successful"
    fi
    return 0
}

qbittorrent_curl() {
    local endpoint="$1"
    shift

    if [[ -n "$QBITTORRENT_USERNAME" && -n "$QBITTORRENT_PASSWORD" ]]; then
        qbittorrent_login || return 1
    fi

    local url="http://${QBITTORRENT_HOST}:${QBITTORRENT_PORT}${endpoint}"
    debug "Requesting $url"

    curl -sS \
        ${QBITTORRENT_COOKIE_JAR:+-b "$QBITTORRENT_COOKIE_JAR"} \
        --max-time 10 \
        "$@" \
        "$url"
}

qbittorrent_curl_and_log() {
    local endpoint="$1"
    shift

    local err_file
    if ! err_file="$(mktemp "${TMPDIR}/qbittorrent_curl_err_XXXXXX")"; then
        log_error "Failed to create temporary file for curl stderr"
        return 1
    fi

    local response
    response=$(qbittorrent_curl "$endpoint" "$@" 2>"$err_file")
    local status=$?
    local err_output
    err_output=$(<"$err_file" 2>/dev/null || true)
    rm -f "$err_file"

    if (( status != 0 )); then
        log_error "qBittorrent request to $endpoint failed: ${err_output:-curl exit $status}"
        return 1
    fi

    debug "Response from $endpoint: $response"
    echo "$response"
    return 0
}

get_qbittorrent_use_random_port() {
    local json="${1:-$QBITTORRENT_LAST_PREFS}"
    if [[ -z "$json" ]]; then
        echo "unknown"
        return 0
    fi
    if echo "$json" | grep -q '"use_random_port"[[:space:]]*:[[:space:]]*true'; then
        echo "true"
        return 0
    fi
    if echo "$json" | grep -q '"use_random_port"[[:space:]]*:[[:space:]]*false'; then
        echo "false"
        return 0
    fi
    echo "unknown"
    return 0
}


restart_qbittorrent_service() {
    if [[ -n "$QBITTORRENT_RESTART_COMMAND" ]]; then
        log "Restarting qBittorrent using configured command"
        if bash -c "$QBITTORRENT_RESTART_COMMAND"; then
            log_success "qBittorrent restart command completed"
            return 0
        else
            log_warning "Restart command failed; ensure qBittorrent reloads settings manually"
            return 1
        fi
    fi

    log_warning "No restart command configured. If qBittorrent does not reload settings automatically, restart the service manually."
    return 1
}


# Get external port by requesting/refreshing NAT-PMP mapping (ProtonVPN)
get_protonvpn_port() {
    if ! command -v natpmpc >/dev/null 2>&1; then
        log_warning "natpmpc not found, attempting to install..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y natpmpc
        elif command -v brew >/dev/null 2>&1; then
            brew install natpmpc
        else
            log_error "Could not auto-install natpmpc. Please install it manually."
            return 1
        fi
    fi

    local gw="${NATPMP_GATEWAY:-}"
    if [[ -z "$gw" ]]; then
        # Heuristic: derive gateway as x.y.z.1 from wg interface IPv4
        local iface_ip
        iface_ip=$(ip -4 addr show dev "$WG_INTERFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1 | cut -d'/' -f1)
        if [[ "$iface_ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
            gw="${BASH_REMATCH[1]}.1"
            debug "Derived NAT-PMP gateway from $WG_INTERFACE IP $iface_ip -> $gw"
        fi
    else
        debug "Using NATPMP_GATEWAY from env: $gw"
    fi

    local gw_args=()
    if [[ -n "$gw" ]]; then
        gw_args=("-g" "$gw")
        log "Using NAT-PMP gateway: ${BLUE}$gw${NC}"
    else
        log_warning "NATPMP_GATEWAY not set and could not derive from $WG_INTERFACE; attempting without -g (may fail)"
    fi

    # Request/refresh a 60-second mapping for UDP and TCP
    local out_udp out_tcp port_udp port_tcp rc
    out_udp=$(natpmpc "${gw_args[@]}" -a 1 0 udp 60 2>&1) || rc=$?
    rc=${rc:-0}
    debug "natpmpc -a udp exit=$rc output: ${out_udp//$'\n'/ | }"
    out_tcp=$(natpmpc "${gw_args[@]}" -a 1 0 tcp 60 2>&1) || rc=$?
    rc=${rc:-0}
    debug "natpmpc -a tcp exit=$rc output: ${out_tcp//$'\n'/ | }"

    # Extract mapped public port
    port_udp=$(echo "$out_udp" | grep -Eo 'Mapped public port[^0-9]*[0-9]+' | grep -Eo '[0-9]+' | head -1)
    port_tcp=$(echo "$out_tcp" | grep -Eo 'Mapped public port[^0-9]*[0-9]+' | grep -Eo '[0-9]+' | head -1)

    local port=""
    if [[ "$port_udp" =~ ^[0-9]+$ ]]; then port="$port_udp"; fi
    if [[ "$port_tcp" =~ ^[0-9]+$ ]]; then
        if [[ -z "$port" ]]; then
            port="$port_tcp"
        elif [[ "$port" != "$port_tcp" ]]; then
            log_warning "UDP/TCP mapped ports differ (udp=$port tcp=$port_tcp); using UDP value"
        fi
    fi

    if [[ -n "$port" ]]; then
        log "NAT-PMP mapped public port: ${GREEN}$port${NC}"
        echo "$port"
        return 0
    fi

    log_error "Failed to obtain NAT-PMP mapped public port. Set NATPMP_GATEWAY (e.g., 10.x.x.1)."
    return 1
}

# Get WireGuard listening port (legacy/fallback)
get_wireguard_port() {
    local port
    # Method 1: Try to get from wg command
    if command -v wg >/dev/null 2>&1; then
        port=$(wg show "$WG_INTERFACE" listen-port 2>/dev/null || echo "")
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi
    # Method 2: Try to parse from wg-quick config (fallback)
    if [[ -f "/etc/wireguard/${WG_INTERFACE}.conf" ]]; then
        port=$(grep -E "^ListenPort\s*=" "/etc/wireguard/${WG_INTERFACE}.conf" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || echo "")
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi
    # Method 3: Try netstat/ss to find WireGuard process (last resort)
    if command -v ss >/dev/null 2>&1; then
        port=$(ss -ulnp | grep -E ":([0-9]+).*wireguard" | head -1 | sed -E 's/.*:([0-9]+).*/\1/' || echo "")
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi
    return 1
}

# Get current qBittorrent port
get_qbittorrent_port() {
    local response

    if ! response=$(qbittorrent_curl_and_log "/api/v2/app/preferences" -f); then
        response=""
    fi

    QBITTORRENT_LAST_PREFS="$response"

    if [[ -n "$response" ]]; then
        # Extract listen_port from JSON response - use multiple approaches
        local port
        
        # Method 1: Simple grep for the port number after listen_port
        port=$(echo "$response" | grep -oE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
        
        # Method 2: Use sed as fallback
        if [[ -z "$port" ]]; then
            port=$(echo "$response" | sed -n 's/.*"listen_port"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p')
        fi
        
        # Method 3: Try alternative field names that qBittorrent might use
        if [[ -z "$port" ]]; then
            port=$(echo "$response" | grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
        fi
        
        # Validate port is a number and in valid range
        if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1024 ]] && [[ "$port" -le 65535 ]]; then
            echo "$port"
        else
            echo ""
        fi
    else
        echo ""
    fi
}

get_qbittorrent_runtime_port() {
    local response port

    if ! response=$(qbittorrent_curl_and_log "/api/v2/sync/maindata" -f); then
        response=""
    fi

    QBITTORRENT_LAST_MAINDATA="$response"

    if [[ -n "$response" ]]; then
        port=$(echo "$response" | grep -oE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')
        if [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi

    return 1
}

verify_qbittorrent_port() {
    local expected="$1"
    local attempts="${2:-5}"
    local delay="${3:-2}"
    local attempt current runtime

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        current=$(get_qbittorrent_port)
        runtime=$(get_qbittorrent_runtime_port 2>/dev/null || echo "")
        debug "Verification attempt ${attempt}: preferences=${current:-<empty>} runtime=${runtime:-<empty>}"

        if [[ "$current" == "$expected" ]]; then
            echo "$current"
            return 0
        fi

        if [[ "$runtime" == "$expected" ]]; then
            echo "$runtime"
            return 0
        fi

        if (( attempt < attempts )); then
            sleep "$delay"
        fi
    done

    echo "$current"
    return 1
}

# Set qBittorrent port
set_qbittorrent_port() {
    local new_port="$1"
    local payload
    printf -v payload 'json={"listen_port":%s,"use_random_port":false}' "$new_port"

    local random_flag
    random_flag=$(get_qbittorrent_use_random_port)
    if [[ "$random_flag" == "true" ]]; then
        log_warning "Detected use_random_port=true; forcing it off while setting port"
    fi

    if ! qbittorrent_curl_and_log "/api/v2/app/setPreferences" -f -X POST -d "$payload" >/dev/null; then
        log_error "Failed to update qBittorrent port to ${new_port}"
        return 1
    fi

    restart_qbittorrent_service || true

    local prefs_response
    if prefs_response=$(qbittorrent_curl_and_log "/api/v2/app/preferences" -f); then
        log "Preferences after port update: $(echo "$prefs_response" | grep -o '"listen_port"[^,}]*')"
    else
        log_warning "Unable to fetch preferences after port update"
    fi

    return 0
}

# Check if qBittorrent is running and accessible
check_qbittorrent() {
    if qbittorrent_curl "/api/v2/app/version" -f >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Main execution
main() {
    log "Starting port sync check..."
    
    # Check if qBittorrent is accessible
    if ! check_qbittorrent; then
        log_error "qBittorrent Web UI is not accessible at ${QBITTORRENT_URL}"
        log_error "Please ensure qBittorrent is running and Web UI is enabled"
        return 1
    fi
    

    # Only use ProtonVPN NAT-PMP port
    local sync_port
    if ! sync_port=$(get_protonvpn_port); then
        log_error "Could not determine ProtonVPN NAT-PMP port. Make sure natpmpc is installed and port forwarding is active."
        return 1
    fi
    log "Detected ProtonVPN NAT-PMP port: ${BLUE}$sync_port${NC}"

    # Get current qBittorrent port
    local current_qbt_port
    current_qbt_port=$(get_qbittorrent_port)

    if [[ -z "$current_qbt_port" ]]; then
        log_error "Could not determine current qBittorrent port"
        return 1
    fi

    log "Current qBittorrent port: ${BLUE}$current_qbt_port${NC}"

    # Compare ports and update if different
    if [[ "$current_qbt_port" != "$sync_port" ]]; then
        log_warning "Port mismatch detected - updating qBittorrent from ${RED}$current_qbt_port${NC} to ${GREEN}$sync_port${NC}"

        # Update qBittorrent port
        if set_qbittorrent_port "$sync_port"; then
            log_success "Updated qBittorrent port to: $sync_port"

            local verified_port
            if verified_port=$(verify_qbittorrent_port "$sync_port"); then
                log_success "Port update verified: qBittorrent is now using port $verified_port"
            else
                local random_flag
                random_flag=$(get_qbittorrent_use_random_port)
                local reported_port="${verified_port:-$(get_qbittorrent_port 2>/dev/null || echo "<unknown>")}"
                log_warning "Port verification failed after retries. qBittorrent reports port: $reported_port (use_random_port=$random_flag)"
                log_warning "qBittorrent may require a manual restart or setting QBITTORRENT_RESTART_COMMAND."
                return 1
            fi
        else
            log_error "Failed to update qBittorrent port to: $sync_port"
            return 1
        fi
    else
        log_success "Ports match (${GREEN}$sync_port${NC}), no action needed"
    fi
    
    log_success "Port sync check completed successfully"
}

# Daemon mode - continuous monitoring with event detection
daemon_mode() {
    log "Starting daemon mode - continuous port monitoring"
    log "Monitoring VPN interface: $WG_INTERFACE"
    log "Monitoring qBittorrent at: $QBITTORRENT_URL"
    log "Debug logging: $([[ "$DEBUG" == "1" ]] && echo Enabled || echo Disabled)"
    
    # Initial sync
    if ! main; then
        log_warning "Initial sync encountered issues; continuing monitoring"
    fi

    local last_port=""
    local check_interval=45  # Refresh NAT-PMP mapping before 60s expiry
    local config_check_interval=300  # Check config file changes every 5 minutes
    local last_config_check=0

    while true; do
        current_time=$(date +%s)

        # Only use ProtonVPN NAT-PMP port
        current_port=""
        if current_port=$(get_protonvpn_port 2>/dev/null); then
            log "[Loop] Detected ProtonVPN NAT-PMP port: ${BLUE}$current_port${NC}"
        else
            log_error "[Loop] Could not determine ProtonVPN NAT-PMP port. Make sure natpmpc is installed and port forwarding is active."
            current_port=""
        fi

        if [[ -n "$current_port" ]]; then
            # Check if port changed
            if [[ "$current_port" != "$last_port" ]]; then
                if [[ -n "$last_port" ]]; then
                    log_warning "[Loop] Port changed from $last_port to $current_port"
                fi

                # Sync ports
                current_qbt_port=$(get_qbittorrent_port 2>/dev/null || echo "")
                if [[ -n "$current_qbt_port" && "$current_qbt_port" != "$current_port" ]]; then
                    log_warning "[Loop] Port mismatch detected - updating qBittorrent from $current_qbt_port to $current_port"

                    if set_qbittorrent_port "$current_port"; then
                        log_success "[Loop] Updated qBittorrent port to: $current_port"

                        if verified_port=$(verify_qbittorrent_port "$current_port"); then
                            log_success "[Loop] Port sync verified: Both services using port $verified_port"
                            last_port="$current_port"
                        else
                            local random_flag
                            random_flag=$(get_qbittorrent_use_random_port)
                            local reported_port="${verified_port:-$(get_qbittorrent_port 2>/dev/null || echo "<unknown>")}"
                            log_warning "[Loop] Port verification failed after retries. qBittorrent reports: $reported_port (use_random_port=$random_flag)"
                            if [[ -z "$QBITTORRENT_RESTART_COMMAND" ]]; then
                                log_warning "[Loop] Configure QBITTORRENT_RESTART_COMMAND to restart qBittorrent automatically if settings do not apply."
                            fi
                        fi
                    else
                        log_error "[Loop] Failed to update qBittorrent port to: $current_port"
                    fi
                elif [[ "$current_port" == "$current_qbt_port" ]]; then
                    log "[Loop] Ports already match ($current_port), no action needed"
                    last_port="$current_port"
                fi
            fi
        else
            if [[ -n "$last_port" ]]; then
                log_warning "[Loop] VPN/WireGuard port appears to be down"
                last_port=""
            fi
        fi

        # Periodic health check (every 5 minutes)
        if (( current_time - last_config_check > config_check_interval )); then
            if ! check_qbittorrent; then
                log_warning "[Loop] qBittorrent Web UI is not accessible - will retry on next cycle"
            fi
            last_config_check=$current_time
        fi

        # Sleep for the check interval
        sleep $check_interval
    done
}

# Handle script arguments
case "${1:-}" in
    --check)
        # Just check current status without making changes
        echo -e "${CYAN}WireGuard port:${NC} $(get_wireguard_port || echo -e '${RED}ERROR${NC}')"
        echo -e "${CYAN}qBittorrent port:${NC} $(get_qbittorrent_port || echo -e '${RED}ERROR${NC}')"
        
        # Debug: Show raw API response
        echo ""
        echo -e "${YELLOW}Debug information:${NC}"
        if qbittorrent_curl "/api/v2/app/version" -f >/dev/null 2>&1; then
            echo -e "${CYAN}qBittorrent API test:${NC} ${GREEN}OK${NC}"
        else
            echo -e "${CYAN}qBittorrent API test:${NC} ${RED}FAILED${NC}"
        fi

        # Show partial preferences response for debugging
        debug_response=$(qbittorrent_curl "/api/v2/app/preferences" -f 2>/dev/null || echo "")
        if [[ -n "$debug_response" ]]; then
            echo -e "${CYAN}API response contains listen_port:${NC} $(echo "$debug_response" | grep -q "listen_port" && echo -e "${GREEN}YES${NC}" || echo -e "${RED}NO${NC}")"
            echo -e "${CYAN}Raw listen_port line:${NC} $(echo "$debug_response" | grep -o '"listen_port"[^,}]*' || echo -e "${RED}NOT FOUND${NC}")"
        else
            echo -e "${RED}No API response received${NC}"
        fi
        ;;
    --force)
        # Force update qBittorrent to match WireGuard
        current_port=$(get_wireguard_port)
        if [[ -n "$current_port" ]]; then
            log "Force updating qBittorrent port to: $current_port"
            if set_qbittorrent_port "$current_port"; then
                log_success "Force update completed successfully"
            else
                log_error "Force update failed"
                exit 1
            fi
        else
            log_error "Could not determine WireGuard port for force update"
            exit 1
        fi
        ;;
    --debug)
        # Detailed debugging information
        echo -e "${BLUE}qBittorrent WireGuard Port Sync - Debug Mode${NC}"
        echo "============================================"
        echo
        
        echo -e "${YELLOW}Configuration:${NC}"
        echo "  WireGuard interface: $WG_INTERFACE"
        echo "  qBittorrent URL: $QBITTORRENT_URL"
        echo "  Log file: $LOG_FILE"
        echo
        
        echo -e "${YELLOW}Testing WireGuard...${NC}"
        if command -v wg >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} wg command available"
            if wg show "$WG_INTERFACE" >/dev/null 2>&1; then
                wg_port=$(wg show "$WG_INTERFACE" listen-port 2>/dev/null || echo "")
                echo -e "  ${GREEN}✓${NC} Interface $WG_INTERFACE is active"
                echo -e "  ${GREEN}✓${NC} WireGuard port: ${BLUE}$wg_port${NC}"
            else
                echo -e "  ${RED}✗${NC} Interface $WG_INTERFACE not found or inactive"
                echo "  Available interfaces: $(wg show interfaces 2>/dev/null || echo 'none')"
            fi
        else
            echo -e "  ${RED}✗${NC} wg command not found"
        fi
        echo
        
        echo -e "${YELLOW}Testing qBittorrent API...${NC}"
        if version=$(qbittorrent_curl "/api/v2/app/version" -f 2>/dev/null); then
            echo -e "  ${GREEN}✓${NC} qBittorrent API accessible"
            echo -e "  ${GREEN}✓${NC} Version: ${BLUE}$version${NC}"

            echo "  Testing preferences API..."
            if prefs_response=$(qbittorrent_curl "/api/v2/app/preferences" -f 2>/dev/null); then
                echo -e "  ${GREEN}✓${NC} Preferences API working"
                if echo "$prefs_response" | grep -q "listen_port"; then
                    echo -e "  ${GREEN}✓${NC} listen_port found in response"
                    port_line=$(echo "$prefs_response" | grep -o '"listen_port"[^,}]*')
                    echo -e "  ${GREEN}✓${NC} Raw port data: ${BLUE}$port_line${NC}"
                    parsed_port=$(get_qbittorrent_port)
                    echo -e "  ${GREEN}✓${NC} Parsed port: ${BLUE}'$parsed_port'${NC}"
                    if [[ -z "$parsed_port" ]]; then
                        echo -e "  ${YELLOW}⚠${NC} Port parsing failed - trying manual extraction:"
                        echo "    Method 1: $(echo "$prefs_response" | grep -oE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$')"
                        echo "    Method 2: $(echo "$prefs_response" | sed -n 's/.*"listen_port"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p')"
                    fi
                else
                    echo -e "  ${RED}✗${NC} listen_port not found in preferences"
                    echo "  Checking for alternative field names..."
                    if echo "$prefs_response" | grep -q '"port"'; then
                        echo "    Found 'port' field: $(echo "$prefs_response" | grep -o '"port"[^,}]*')"
                    fi
                    echo "  Response preview: $(echo "$prefs_response" | head -c 300)..."
                fi
            else
                echo -e "  ${RED}✗${NC} Preferences API failed"
            fi
        else
            echo -e "  ${RED}✗${NC} qBittorrent API not accessible at $QBITTORRENT_URL"
            echo "  Check that qBittorrent is running and Web UI is enabled"
        fi
        ;;
    --daemon)
        # Run in daemon mode for systemd service
        daemon_mode
        ;;
    --help|-h)
        echo -e "${BLUE}qBittorrent WireGuard Port Sync Script${NC}"
        echo "Usage: $0 [--check|--force|--debug|--daemon|--help]"
        echo ""
        echo "Options:"
        echo "  (no args)  Normal operation - sync ports if changed"
        echo "  --check    Display current port status without changes"
        echo "  --force    Force update qBittorrent to match WireGuard"
        echo "  --debug    Show detailed debugging information"
        echo "  --daemon   Run continuously as a service (for systemd)"
        echo "  --help     Show this help message"
        echo ""
        echo "Configuration (edit script to modify):"
        echo "  WireGuard interface: $WG_INTERFACE"
        echo "  qBittorrent URL: $QBITTORRENT_URL"
        echo "  Log file: $LOG_FILE"
        ;;
    "")
        # Normal operation
        main
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}"
        echo "Use --help for usage information"
        exit 1
        ;;
esac