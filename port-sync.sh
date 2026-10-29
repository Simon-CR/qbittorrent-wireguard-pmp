#!/bin/bash

# qBittorrent WireGuard Port Sync Script
# Monitors ProtonVPN / RFC-6886 NAT-PMP forwarded port and hot-updates qBittorrent
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
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/port-sync.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-5242880}"  # Rotate LOG_FILE at 5 MiB
DEBUG="${DEBUG:-0}"
DEBUG_PAYLOAD_PREVIEW="${DEBUG_PAYLOAD_PREVIEW:-512}"
QBITTORRENT_HOST="${QBITTORRENT_HOST:-localhost}"
# Allow service env var QB_PORT or QBITTORRENT_PORT to override default 8080
QBITTORRENT_PORT="${QBITTORRENT_PORT:-${QB_PORT:-8080}}"
QBITTORRENT_URL="http://${QBITTORRENT_HOST}:${QBITTORRENT_PORT}"
QBITTORRENT_RESTART_COMMAND="${QBITTORRENT_RESTART_COMMAND:-${QBT_RESTART_COMMAND:-}}"
QBITTORRENT_RESTART_WAIT="${QBITTORRENT_RESTART_WAIT:-5}"  # Seconds to wait after fallback restart
QBITTORRENT_FORCE_RESTART="${QBITTORRENT_FORCE_RESTART:-0}"
QBITTORRENT_RESTART_ON_FAILURE="${QBITTORRENT_RESTART_ON_FAILURE:-1}"
QBITTORRENT_HOT_VERIFY_DELAY="${QBITTORRENT_HOT_VERIFY_DELAY:-1}"
QBITTORRENT_VERIFY_DELAY="${QBITTORRENT_VERIFY_DELAY:-2}"
QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:-${QB_USERNAME:-}}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-${QB_PASSWORD:-}}"

# RFC-6886 NAT-PMP lease & renewal cadence settings
NATPMP_LIFETIME="${NATPMP_LIFETIME:-120}"
NATPMP_RETRIES="${NATPMP_RETRIES:-3}"
NATPMP_RETRY_DELAY="${NATPMP_RETRY_DELAY:-0.4}"
CHECK_INTERVAL="${CHECK_INTERVAL:-25}"
DAEMON_MAX_LOOPS="${DAEMON_MAX_LOOPS:-0}"

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

if ! NATPMP_STATE_FILE="$(mktemp "${TMPDIR}/natpmp_state_XXXXXX")"; then
    echo "Error: Unable to create temporary NAT-PMP state file" >&2
    rm -f "$QBITTORRENT_COOKIE_JAR"
    exit 1
fi

QBITTORRENT_LAST_PREFS=""
QBITTORRENT_LAST_MAINDATA=""
LAST_VERIFIED_QBT_PORT=""
LAST_GRANTED_LIFETIME="${LAST_GRANTED_LIFETIME:-0}"
LAST_KNOWN_NATPMP_PORT="${LAST_KNOWN_NATPMP_PORT:-}"
PARTIAL_NATPMP_STREAK="${PARTIAL_NATPMP_STREAK:-0}"
NATPMP_GW_ARGS=()
_NATPMP_OUT=""
_NATPMP_PORT=""
_NATPMP_GRANTED_LIFETIME=""
WG_INTERFACE="${WG_INTERFACE:-wg0}"  # Default WireGuard interface name

cleanup() {
    if [[ -n "${QBITTORRENT_COOKIE_JAR:-}" && -f "$QBITTORRENT_COOKIE_JAR" ]]; then
        rm -f "$QBITTORRENT_COOKIE_JAR"
    fi
    if [[ -n "${NATPMP_STATE_FILE:-}" && -f "$NATPMP_STATE_FILE" ]]; then
        rm -f "$NATPMP_STATE_FILE"
    fi
}

trap cleanup EXIT

# Rotate LOG_FILE to LOG_FILE.1 when it exceeds LOG_MAX_BYTES (default 5 MiB).
rotate_log_if_needed() {
    if [[ -z "${LOG_FILE:-}" || ! -f "$LOG_FILE" ]]; then
        return 0
    fi

    local size=0
    if size=$(wc -c <"$LOG_FILE" 2>/dev/null); then
        size="${size//[[:space:]]/}"
    else
        size=0
    fi

    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > LOG_MAX_BYTES )); then
        mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    fi
}

# Persist NAT-PMP state across command-substitution subshells ($(get_protonvpn_port)).
_save_natpmp_state() {
    if [[ -z "${NATPMP_STATE_FILE:-}" ]]; then
        return 0
    fi
    printf 'LAST_GRANTED_LIFETIME=%s\nLAST_KNOWN_NATPMP_PORT=%s\nPARTIAL_NATPMP_STREAK=%s\n' \
        "${LAST_GRANTED_LIFETIME:-0}" \
        "${LAST_KNOWN_NATPMP_PORT:-}" \
        "${PARTIAL_NATPMP_STREAK:-0}" >"$NATPMP_STATE_FILE" 2>/dev/null || true
}

_load_natpmp_state() {
    if [[ -z "${NATPMP_STATE_FILE:-}" || ! -s "$NATPMP_STATE_FILE" ]]; then
        return 0
    fi

    local key val
    while IFS='=' read -r key val; do
        case "$key" in
            LAST_GRANTED_LIFETIME)
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    LAST_GRANTED_LIFETIME="$val"
                fi
                ;;
            LAST_KNOWN_NATPMP_PORT)
                if [[ -z "$val" || "$val" =~ ^[0-9]+$ ]]; then
                    LAST_KNOWN_NATPMP_PORT="$val"
                fi
                ;;
            PARTIAL_NATPMP_STREAK)
                if [[ "$val" =~ ^[0-9]+$ ]]; then
                    PARTIAL_NATPMP_STREAK="$val"
                fi
                ;;
        esac
    done <"$NATPMP_STATE_FILE"
}

# Compute effective renewal target interval:
# min(CHECK_INTERVAL, max(15, LAST_GRANTED_LIFETIME * 2 / 5)) when LAST_GRANTED_LIFETIME > 0.
compute_target_interval() {
    local base_interval="${CHECK_INTERVAL:-25}"
    local granted="${LAST_GRANTED_LIFETIME:-0}"

    if [[ ! "$base_interval" =~ ^[0-9]+$ ]] || (( base_interval < 1 )); then
        base_interval=25
    fi

    if [[ "$granted" =~ ^[0-9]+$ ]] && (( granted > 0 )); then
        local adaptive=$(( granted * 2 / 5 ))
        if (( adaptive < 15 )); then
            adaptive=15
        fi
        if (( adaptive < base_interval )); then
            echo "$adaptive"
            return 0
        fi
    fi

    echo "$base_interval"
}

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

debug_payload() {
    if [[ "$DEBUG" != "1" ]]; then
        return
    fi

    local label="$1"
    local data="${2:-}"
    local max_len="$DEBUG_PAYLOAD_PREVIEW"
    local flattened="${data//$'\n'/ | }"
    local length=${#flattened}

    if (( length <= max_len )); then
        debug "$label: $flattened"
    else
        debug "$label: ${flattened:0:max_len}... (truncated, total ${length} chars)"
    fi
}

# Extract a numeric value from a simple JSON blob without jq.
extract_json_number() {
    local json="$1"
    local key="$2"

    if [[ -z "$json" || -z "$key" ]]; then
        return 1
    fi

    local value
    value=$(printf '%s\n' "$json" | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" | grep -oE '[0-9]+$' | head -1 || true)

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
        return 0
    fi

    return 1
}

# Authenticate against the qBittorrent WebUI when credentials are provided.
qbittorrent_login() {
    if [[ -n "$QBITTORRENT_USERNAME" && -n "$QBITTORRENT_PASSWORD" ]]; then
        debug "Logging into qBittorrent WebUI"
        local login_url="http://${QBITTORRENT_HOST}:${QBITTORRENT_PORT}/api/v2/auth/login"
        local response=""
        if ! response=$(curl -sS -X POST "$login_url" \
            -d "username=$QBITTORRENT_USERNAME" \
            -d "password=$QBITTORRENT_PASSWORD" \
            -c "$QBITTORRENT_COOKIE_JAR" \
            --max-time 10); then
            log_error "qBittorrent login request failed" >&2
            return 1
        fi
        if [[ "$response" != "Ok." ]]; then
            log_error "qBittorrent login failed: $response" >&2
            return 1
        fi
        debug "qBittorrent login successful"
    fi
    return 0
}

# Perform an authenticated curl request against the qBittorrent API.
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

# Perform a qBittorrent API call with error handling and optional logging.
qbittorrent_curl_and_log() {
    local endpoint="$1"
    shift

    local err_file
    if ! err_file="$(mktemp "${TMPDIR}/qbittorrent_curl_err_XXXXXX")"; then
        log_error "Failed to create temporary file for curl stderr" >&2
        return 1
    fi

    local response=""
    local status=0
    response=$(qbittorrent_curl "$endpoint" "$@" 2>"$err_file") || status=$?
    local err_output
    err_output=$(<"$err_file" 2>/dev/null || true)
    rm -f "$err_file"

    if (( status != 0 )); then
        log_error "qBittorrent request to $endpoint failed: ${err_output:-curl exit $status}" >&2
        return 1
    fi

    debug_payload "Response from $endpoint" "$response"
    echo "$response"
    return 0
}

# Restart qBittorrent (emergency fallback only) and block until the WebUI becomes reachable again.
restart_qbittorrent_service() {
    if [[ -n "$QBITTORRENT_RESTART_COMMAND" ]]; then
        log "Restarting qBittorrent using configured command"
        if bash -c "$QBITTORRENT_RESTART_COMMAND"; then
            log_success "qBittorrent restart command completed"

            # Wait for qBittorrent to fully restart and be ready
            if [[ "$QBITTORRENT_RESTART_WAIT" -gt 0 ]]; then
                log "Waiting ${QBITTORRENT_RESTART_WAIT}s for qBittorrent to be ready..."
                sleep "$QBITTORRENT_RESTART_WAIT"

                # Check if qBittorrent is accessible after restart
                local wait_attempts=10
                local wait_delay=2
                local i
                for ((i = 1; i <= wait_attempts; i++)); do
                    if check_qbittorrent 2>/dev/null; then
                        log_success "qBittorrent is ready after restart"
                        return 0
                    fi
                    if (( i < wait_attempts )); then
                        debug "qBittorrent not ready yet, waiting... (attempt $i/$wait_attempts)"
                        sleep "$wait_delay"
                    fi
                done
                log_warning "qBittorrent may not be fully ready yet after restart"
            fi
            return 0
        else
            log_warning "Restart command failed; ensure qBittorrent reloads settings manually"
            return 1
        fi
    fi

    log_warning "No restart command configured. If qBittorrent does not reload settings automatically, restart the service manually."
    return 1
}

# Execute natpmpc for a single protocol with timeout + retry handling.
# Populates _NATPMP_OUT, _NATPMP_PORT, and _NATPMP_GRANTED_LIFETIME.
_run_natpmpc_proto() {
    local proto="$1"
    local lifetime="$2"
    local pub_port_hint="${3:-1}"
    local max_attempts="${NATPMP_RETRIES:-3}"
    local retry_delay="${NATPMP_RETRY_DELAY:-0.4}"

    if [[ ! "$max_attempts" =~ ^[0-9]+$ ]] || (( max_attempts < 1 )); then
        max_attempts=3
    fi

    _NATPMP_OUT=""
    _NATPMP_PORT=""
    _NATPMP_GRANTED_LIFETIME=""

    local cmd_prefix=()
    if command -v timeout >/dev/null 2>&1; then
        cmd_prefix=("timeout" "4")
    fi

    local attempt out rc mapped_port granted_lt
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        rc=0
        out=$("${cmd_prefix[@]}" natpmpc "${NATPMP_GW_ARGS[@]}" -a "$pub_port_hint" 0 "$proto" "$lifetime" 2>&1) || rc=$?
        _NATPMP_OUT="$out"
        debug_payload "natpmpc -a ${pub_port_hint} 0 ${proto} ${lifetime} (attempt ${attempt}/${max_attempts}, exit=${rc})" "$out"

        mapped_port=$(printf '%s\n' "$out" | grep -Eo 'Mapped public port[^0-9]*[0-9]+' | grep -Eo '[0-9]+' | head -1 || true)
        granted_lt=$(printf '%s\n' "$out" | grep -Eo 'lif[e]?time[^0-9]*[0-9]+' | grep -Eo '[0-9]+' | head -1 || true)

        if [[ "$lifetime" == "0" ]]; then
            if [[ "$mapped_port" == "0" || "$rc" -eq 0 ]]; then
                _NATPMP_PORT="${mapped_port:-0}"
                _NATPMP_GRANTED_LIFETIME="${granted_lt:-0}"
                return 0
            fi
        else
            if [[ "$mapped_port" =~ ^[0-9]+$ ]] && (( mapped_port > 0 )); then
                _NATPMP_PORT="$mapped_port"
                if [[ "$granted_lt" =~ ^[0-9]+$ ]] && (( granted_lt > 0 )); then
                    _NATPMP_GRANTED_LIFETIME="$granted_lt"
                fi
                return 0
            fi
        fi

        if (( attempt < max_attempts )); then
            debug "natpmpc ${proto} attempt ${attempt}/${max_attempts} failed (rc=${rc}); retrying in ${retry_delay}s"
            sleep "$retry_delay"
        fi
    done

    return 1
}

# Refresh the NAT-PMP mapping and return the ProtonVPN forwarded port.
get_protonvpn_port() {
    _load_natpmp_state

    if ! command -v natpmpc >/dev/null 2>&1; then
        log_warning "natpmpc not found, attempting to install..." >&2
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update >&2 && sudo apt-get install -y natpmpc >&2
        elif command -v brew >/dev/null 2>&1; then
            brew install natpmpc >&2
        else
            log_error "Could not auto-install natpmpc. Please install it manually." >&2
            return 1
        fi
    fi

    local gw="${NATPMP_GATEWAY:-}"
    if [[ -z "$gw" ]]; then
        # Heuristic: derive gateway as x.y.z.1 from wg interface IPv4
        local iface_ip=""
        if command -v ip >/dev/null 2>&1; then
            iface_ip=$(ip -4 addr show dev "$WG_INTERFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1 | cut -d'/' -f1 || true)
        fi
        if [[ "$iface_ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
            gw="${BASH_REMATCH[1]}.1"
            debug "Derived NAT-PMP gateway from $WG_INTERFACE IP $iface_ip -> $gw"
        fi
    else
        debug "Using NATPMP_GATEWAY from env: $gw"
    fi

    NATPMP_GW_ARGS=()
    if [[ -n "$gw" ]]; then
        NATPMP_GW_ARGS=("-g" "$gw")
        log "Using NAT-PMP gateway: ${BLUE}$gw${NC}" >&2
    else
        log_warning "NATPMP_GATEWAY not set and could not derive from $WG_INTERFACE; attempting without -g (may fail)" >&2
    fi

    # Request/refresh NAT-PMP mapping for UDP and TCP back-to-back
    local port_udp="" port_tcp="" lt_udp="" lt_tcp=""
    if _run_natpmpc_proto udp "$NATPMP_LIFETIME" 1; then
        port_udp="$_NATPMP_PORT"
        lt_udp="$_NATPMP_GRANTED_LIFETIME"
    fi
    if _run_natpmpc_proto tcp "$NATPMP_LIFETIME" 1; then
        port_tcp="$_NATPMP_PORT"
        lt_tcp="$_NATPMP_GRANTED_LIFETIME"
    fi

    # Automatic UDP/TCP port split self-healing
    if [[ "$port_udp" =~ ^[0-9]+$ && "$port_tcp" =~ ^[0-9]+$ && "$port_udp" != "$port_tcp" ]]; then
        log_warning "UDP/TCP mapped ports differ (udp=$port_udp tcp=$port_tcp); attempting NAT-PMP resync" >&2

        # Step 1: Attempt requesting TCP with public-port hint $port_udp
        if _run_natpmpc_proto tcp "$NATPMP_LIFETIME" "$port_udp"; then
            port_tcp="$_NATPMP_PORT"
            if [[ -n "$_NATPMP_GRANTED_LIFETIME" ]]; then
                lt_tcp="$_NATPMP_GRANTED_LIFETIME"
            fi
        fi

        # Step 2: If still mismatched, release both leases (lifetime 0) and re-request UDP + TCP back-to-back once
        if [[ "$port_udp" != "$port_tcp" ]]; then
            log_warning "Hinted TCP resync still mismatched (udp=$port_udp tcp=${port_tcp:-<none>}); releasing both mappings and re-requesting" >&2
            _run_natpmpc_proto udp 0 1 || true
            _run_natpmpc_proto tcp 0 1 || true

            local resync_udp="" resync_tcp=""
            if _run_natpmpc_proto udp "$NATPMP_LIFETIME" 1; then
                resync_udp="$_NATPMP_PORT"
                if [[ -n "$_NATPMP_GRANTED_LIFETIME" ]]; then
                    lt_udp="$_NATPMP_GRANTED_LIFETIME"
                fi
            fi
            if _run_natpmpc_proto tcp "$NATPMP_LIFETIME" 1; then
                resync_tcp="$_NATPMP_PORT"
                if [[ -n "$_NATPMP_GRANTED_LIFETIME" ]]; then
                    lt_tcp="$_NATPMP_GRANTED_LIFETIME"
                fi
            fi

            [[ -n "$resync_udp" ]] && port_udp="$resync_udp"
            [[ -n "$resync_tcp" ]] && port_tcp="$resync_tcp"
        fi

        if [[ -n "$port_udp" && "$port_udp" == "$port_tcp" ]]; then
            log_success "NAT-PMP UDP/TCP split self-healed to symmetric port $port_udp" >&2
        else
            log_warning "UDP/TCP mapped ports remain split after resync (udp=${port_udp:-<none>} tcp=${port_tcp:-<none>}); using UDP value" >&2
        fi
    fi

    # Record minimum positive granted lifetime across UDP and TCP
    local min_lt=0
    if [[ "$lt_udp" =~ ^[0-9]+$ ]] && (( lt_udp > 0 )) && [[ "$lt_tcp" =~ ^[0-9]+$ ]] && (( lt_tcp > 0 )); then
        if (( lt_udp <= lt_tcp )); then
            min_lt="$lt_udp"
        else
            min_lt="$lt_tcp"
        fi
    elif [[ "$lt_udp" =~ ^[0-9]+$ ]] && (( lt_udp > 0 )); then
        min_lt="$lt_udp"
    elif [[ "$lt_tcp" =~ ^[0-9]+$ ]] && (( lt_tcp > 0 )); then
        min_lt="$lt_tcp"
    fi
    if (( min_lt > 0 )); then
        LAST_GRANTED_LIFETIME="$min_lt"
    fi

    # Resolve effective port with partial single-protocol failure guard
    local port=""
    if [[ "$port_udp" =~ ^[0-9]+$ && "$port_tcp" =~ ^[0-9]+$ ]]; then
        port="$port_udp"
        PARTIAL_NATPMP_STREAK=0
        LAST_KNOWN_NATPMP_PORT="$port"
    elif [[ "$port_udp" =~ ^[0-9]+$ || "$port_tcp" =~ ^[0-9]+$ ]]; then
        local single_port="" ok_proto="" failed_proto=""
        if [[ "$port_udp" =~ ^[0-9]+$ ]]; then
            single_port="$port_udp"
            ok_proto="udp"
            failed_proto="tcp"
        else
            single_port="$port_tcp"
            ok_proto="tcp"
            failed_proto="udp"
        fi

        PARTIAL_NATPMP_STREAK=$(( ${PARTIAL_NATPMP_STREAK:-0} + 1 ))

        if [[ -n "${LAST_KNOWN_NATPMP_PORT:-}" && "$LAST_KNOWN_NATPMP_PORT" != "$single_port" ]] && (( PARTIAL_NATPMP_STREAK < 2 )); then
            log_warning "Partial NAT-PMP read (${failed_proto} failed, ${ok_proto}=${single_port}) differs from last known port ${LAST_KNOWN_NATPMP_PORT}; keeping ${LAST_KNOWN_NATPMP_PORT} for 1 degraded cycle" >&2
            port="$LAST_KNOWN_NATPMP_PORT"
        else
            if [[ -n "${LAST_KNOWN_NATPMP_PORT:-}" && "$LAST_KNOWN_NATPMP_PORT" != "$single_port" ]]; then
                log_warning "Partial NAT-PMP read persisted for ${PARTIAL_NATPMP_STREAK} consecutive cycles (${failed_proto} failed, ${ok_proto}=${single_port}); adopting ${single_port}" >&2
            else
                log_warning "Partial NAT-PMP read (${failed_proto} failed, ${ok_proto}=${single_port}); using ${single_port}" >&2
            fi
            port="$single_port"
            LAST_KNOWN_NATPMP_PORT="$port"
        fi
    fi

    _save_natpmp_state

    if [[ -n "$port" ]]; then
        # CRITICAL: External health monitoring (ct127-health.py) parses this exact log line pattern
        log "NAT-PMP mapped public port: ${GREEN}$port${NC}" >&2
        echo "$port"
        return 0
    fi

    log_error "Failed to obtain NAT-PMP mapped public port. Set NATPMP_GATEWAY (e.g., 10.x.x.1)." >&2
    return 1
}

# Fallback helper for reading the WireGuard listen port directly.
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
        port=$(ss -ulnp 2>/dev/null | grep -E ":([0-9]+).*wireguard" | head -1 | sed -E 's/.*:([0-9]+).*/\1/' || echo "")
        if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi
    return 1
}

# Get the currently configured qBittorrent port from preferences.
get_qbittorrent_port() {
    local response port

    response=$(qbittorrent_curl_and_log "/api/v2/app/preferences" -f || echo "")
    QBITTORRENT_LAST_PREFS="$response"

    if [[ -z "$response" ]]; then
        echo ""
        return 0
    fi

    if port=$(extract_json_number "$response" "listen_port"); then
        echo "$port"
        return 0
    fi

    if port=$(extract_json_number "$response" "port"); then
        echo "$port"
        return 0
    fi

    if printf '%s\n' "$response" | grep -q '"listen_port"'; then
        log_warning "Unable to parse listen_port from qBittorrent preferences response" >&2
    fi

    echo ""
}

# Query qBittorrent runtime data to obtain the active listen port (if exposed).
get_qbittorrent_runtime_port() {
    local response port

    response=$(qbittorrent_curl_and_log "/api/v2/sync/maindata" -f || echo "")
    QBITTORRENT_LAST_MAINDATA="$response"

    if [[ -z "$response" ]]; then
        return 1
    fi

    if port=$(extract_json_number "$response" "listen_port"); then
        echo "$port"
        return 0
    fi

    return 1
}

# Poll qBittorrent until the expected port appears in preferences/runtime or retries are exhausted.
verify_qbittorrent_port() {
    local expected="$1"
    local attempts="${2:-5}"
    local delay="${3:-1}"
    local initial_delay="${4:-0.3}"
    local attempt current="" runtime=""

    if [[ -n "$initial_delay" && "$initial_delay" != "0" ]]; then
        sleep "$initial_delay"
    fi

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if ! check_qbittorrent 2>/dev/null; then
            debug "Verification attempt ${attempt}/${attempts}: qBittorrent not accessible yet"
            if (( attempt < attempts )); then
                sleep "$delay"
            fi
            continue
        fi

        current=$(get_qbittorrent_port)
        runtime=$(get_qbittorrent_runtime_port 2>/dev/null || echo "")
        debug "Verification attempt ${attempt}/${attempts}: preferences=${current:-<empty>} runtime=${runtime:-<empty>}"

        if [[ "$current" == "$expected" ]] && [[ -z "$runtime" || "$runtime" == "$expected" ]]; then
            echo "$expected"
            return 0
        fi

        if [[ "$runtime" == "$expected" ]]; then
            local current_check
            current_check=$(get_qbittorrent_port)
            if [[ "$current_check" == "$expected" ]]; then
                echo "$expected"
                return 0
            fi
        fi

        if (( attempt < attempts )); then
            sleep "$delay"
        fi
    done

    echo "$current"
    return 1
}

# Hot-update qBittorrent's listen port via WebUI API; restart service ONLY as emergency fallback.
set_qbittorrent_port() {
    local new_port="$1"
    local payload="json={\"listen_port\":${new_port}}"
    LAST_VERIFIED_QBT_PORT=""

    if ! qbittorrent_curl_and_log "/api/v2/app/setPreferences" -f -X POST -d "$payload" >/dev/null; then
        log_error "Failed to update qBittorrent port to ${new_port}"
        return 1
    fi

    if [[ "$QBITTORRENT_FORCE_RESTART" != "1" ]]; then
        if verify_qbittorrent_port "$new_port" 5 "$QBITTORRENT_HOT_VERIFY_DELAY" 0.3 >/dev/null; then
            log "Preferences after port update: \"listen_port\":${new_port}"
            log_success "Hot-applied qBittorrent listen_port=${new_port} via WebUI API (zero restart)"
            LAST_VERIFIED_QBT_PORT="$new_port"
            return 0
        fi
    fi

    if [[ "$QBITTORRENT_FORCE_RESTART" == "1" ]]; then
        log_warning "QBITTORRENT_FORCE_RESTART=1 enabled; restarting qBittorrent service"
    elif [[ -n "$QBITTORRENT_RESTART_COMMAND" && "$QBITTORRENT_RESTART_ON_FAILURE" == "1" ]]; then
        log_warning "Hot-reload verification of listen_port=${new_port} failed; invoking fallback QBITTORRENT_RESTART_COMMAND"
    else
        log_warning "Hot-reload verification of listen_port=${new_port} did not confirm new port (fallback restart disabled or unconfigured)"
        return 1
    fi

    if [[ -n "$QBITTORRENT_RESTART_COMMAND" ]]; then
        restart_qbittorrent_service || true
    fi

    if verify_qbittorrent_port "$new_port" 8 "$QBITTORRENT_VERIFY_DELAY" 0.3 >/dev/null; then
        log "Preferences after port update: \"listen_port\":${new_port}"
        log_success "Applied qBittorrent listen_port=${new_port} after service restart"
        LAST_VERIFIED_QBT_PORT="$new_port"
        return 0
    fi

    local prefs_response=""
    if prefs_response=$(qbittorrent_curl_and_log "/api/v2/app/preferences" -f 2>/dev/null); then
        local updated_port=""
        if updated_port=$(extract_json_number "$prefs_response" "listen_port"); then
            log_warning "Preferences after failed port update still report: \"listen_port\":$updated_port"
        fi
    fi

    return 1
}

# Quick health check for the qBittorrent WebUI API.
check_qbittorrent() {
    if qbittorrent_curl "/api/v2/app/version" -f >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Single-run sync entry point.
main() {
    rotate_log_if_needed
    log "Starting port sync check..."

    # Check if qBittorrent is accessible
    if ! check_qbittorrent; then
        log_error "qBittorrent Web UI is not accessible at ${QBITTORRENT_URL}"
        log_error "Please ensure qBittorrent is running and Web UI is enabled"
        return 1
    fi

    # Obtain ProtonVPN / RFC-6886 NAT-PMP port
    local sync_port
    if ! sync_port=$(get_protonvpn_port); then
        _load_natpmp_state
        log_error "Could not determine ProtonVPN NAT-PMP port. Make sure natpmpc is installed and port forwarding is active."
        return 1
    fi
    _load_natpmp_state
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

        if set_qbittorrent_port "$sync_port"; then
            log_success "Updated qBittorrent port to: $sync_port"

            local verified_port="$sync_port"
            if [[ "${LAST_VERIFIED_QBT_PORT:-}" == "$sync_port" ]] || verified_port=$(verify_qbittorrent_port "$sync_port" 3 1 0.2); then
                log_success "Port update verified: qBittorrent is now using port ${verified_port:-$sync_port}"
            else
                local reported_port="${verified_port:-$(get_qbittorrent_port 2>/dev/null || echo "<unknown>")}"
                log_warning "Port verification failed after retries. qBittorrent reports port: $reported_port"
                log_warning "qBittorrent may require a manual restart or setting QBITTORRENT_RESTART_COMMAND."
                return 1
            fi
        else
            local reported_port
            reported_port=$(get_qbittorrent_port 2>/dev/null || echo "<unknown>")
            log_error "Failed to update qBittorrent port to: $sync_port (qBittorrent reports: ${reported_port:-<unknown>})"
            return 1
        fi
    else
        log_success "Ports match (${GREEN}$sync_port${NC}), no action needed"
    fi

    log_success "Port sync check completed successfully"
}

# Continuous monitoring loop intended for systemd service usage.
daemon_mode() {
    rotate_log_if_needed
    log "Starting daemon mode - continuous port monitoring"
    log "Monitoring VPN interface: $WG_INTERFACE"
    log "Monitoring qBittorrent at: $QBITTORRENT_URL"
    log "NAT-PMP requested lifetime: ${NATPMP_LIFETIME}s | base check interval: ${CHECK_INTERVAL}s"
    log "Debug logging: $([[ "$DEBUG" == "1" ]] && echo Enabled || echo Disabled)"

    local init_start init_end init_elapsed
    init_start=$(date +%s)
    if ! main; then
        log_warning "Initial sync encountered issues; continuing monitoring"
    fi
    init_end=$(date +%s)
    init_elapsed=$(( init_end - init_start ))

    local last_port="${LAST_KNOWN_NATPMP_PORT:-}"
    local config_check_interval=300  # Re-verify qBittorrent listen_port every 5 minutes even when NAT-PMP port is unchanged
    local last_config_check="$init_end"
    local loop_count=0

    # Sleep after successful fast initial sync so we don't double-poll 50ms after startup,
    # unless initial sync was slow (>=20s) or failed to record a port.
    if [[ -n "$last_port" ]] && (( init_elapsed >= 0 && init_elapsed < 20 )); then
        local init_target init_sleep
        init_target=$(compute_target_interval)
        init_sleep=$(( init_target - init_elapsed ))
        if (( init_sleep < 5 )); then
            init_sleep=5
        fi
        if (( DAEMON_MAX_LOOPS <= 0 )); then
            debug "[Init] Initial sync took ${init_elapsed}s; sleeping ${init_sleep}s before first renewal cycle"
            sleep "$init_sleep"
        fi
    fi

    while true; do
        rotate_log_if_needed
        loop_count=$(( loop_count + 1 ))

        local loop_start loop_end elapsed target_interval sleep_for
        loop_start=$(date +%s)

        local current_port=""
        if current_port=$(get_protonvpn_port); then
            _load_natpmp_state
            log "[Loop] Detected ProtonVPN NAT-PMP port: ${BLUE}$current_port${NC}"
        else
            _load_natpmp_state
            log_error "[Loop] Could not determine ProtonVPN NAT-PMP port. Make sure natpmpc is installed and port forwarding is active."
            current_port=""
        fi

        if [[ -n "$current_port" ]]; then
            local need_qbt_check=0
            if [[ "$current_port" != "$last_port" ]]; then
                need_qbt_check=1
                if [[ -n "$last_port" ]]; then
                    log_warning "[Loop] Port changed from $last_port to $current_port"
                fi
            elif (( loop_start - last_config_check >= config_check_interval )); then
                need_qbt_check=1
                last_config_check="$loop_start"
            fi

            if (( need_qbt_check == 1 )); then
                local current_qbt_port
                current_qbt_port=$(get_qbittorrent_port 2>/dev/null || echo "")
                if [[ -n "$current_qbt_port" && "$current_qbt_port" != "$current_port" ]]; then
                    log_warning "[Loop] Port mismatch detected - updating qBittorrent from $current_qbt_port to $current_port"

                    if set_qbittorrent_port "$current_port"; then
                        log_success "[Loop] Updated qBittorrent port to: $current_port"

                        local verified_port="$current_port"
                        if [[ "${LAST_VERIFIED_QBT_PORT:-}" == "$current_port" ]] || verified_port=$(verify_qbittorrent_port "$current_port" 3 1 0.2); then
                            log_success "[Loop] Port sync verified: Both services using port ${verified_port:-$current_port}"
                            last_port="$current_port"
                        else
                            local reported_port="${verified_port:-$(get_qbittorrent_port 2>/dev/null || echo "<unknown>")}"
                            log_warning "[Loop] Port verification failed after retries. qBittorrent reports: $reported_port"
                            if [[ -z "$QBITTORRENT_RESTART_COMMAND" ]]; then
                                log_warning "[Loop] Configure QBITTORRENT_RESTART_COMMAND to restart qBittorrent automatically if settings do not apply."
                            fi
                        fi
                    else
                        log_error "[Loop] Failed to update qBittorrent port to: $current_port"
                    fi
                elif [[ "$current_port" == "$current_qbt_port" ]]; then
                    if [[ "$current_port" != "$last_port" ]]; then
                        log "[Loop] Ports already match ($current_port), no action needed"
                    else
                        debug "[Loop] Periodic qBittorrent check confirmed listen_port=$current_port"
                    fi
                    last_port="$current_port"
                else
                    log_warning "[Loop] qBittorrent Web UI is not accessible - will retry on next cycle"
                    last_port=""
                fi
            fi
        else
            if [[ -n "$last_port" ]]; then
                log_warning "[Loop] VPN/WireGuard port appears to be down"
                last_port=""
            fi
        fi

        target_interval=$(compute_target_interval)
        loop_end=$(date +%s)
        elapsed=$(( loop_end - loop_start ))
        if (( elapsed < 0 )); then
            elapsed=0
        fi

        if (( elapsed >= 20 )); then
            log_warning "[Loop] Cycle took ${elapsed}s (>=20s); refreshing NAT-PMP lease immediately before sleeping"
            local post_op_port=""
            if post_op_port=$(get_protonvpn_port); then
                _load_natpmp_state
                target_interval=$(compute_target_interval)
                if [[ -n "$post_op_port" && "$post_op_port" != "$current_port" ]]; then
                    log_warning "[Loop] NAT-PMP port rotated during slow operation (${current_port:-<none>} -> $post_op_port); scheduling fast resync"
                    last_port=""
                    sleep_for=5
                else
                    sleep_for="$target_interval"
                fi
            else
                _load_natpmp_state
                sleep_for=5
            fi
        else
            sleep_for=$(( target_interval - elapsed ))
            if (( sleep_for < 5 )); then
                sleep_for=5
            fi
        fi

        debug "[Loop] Cycle #${loop_count} elapsed=${elapsed}s granted_lifetime=${LAST_GRANTED_LIFETIME:-0}s target_interval=${target_interval}s sleep=${sleep_for}s"

        if (( DAEMON_MAX_LOOPS > 0 && loop_count >= DAEMON_MAX_LOOPS )); then
            break
        fi

        sleep "$sleep_for"
    done
}

run_cli() {
    case "${1:-}" in
        --check)
            # Just check current status without making changes
            echo -e "${CYAN}WireGuard port:${NC} $(get_wireguard_port || echo -e "${RED}ERROR${NC}")"
            echo -e "${CYAN}qBittorrent port:${NC} $(get_qbittorrent_port || echo -e "${RED}ERROR${NC}")"

            # Debug: Show raw API response
            echo ""
            echo -e "${YELLOW}Debug information:${NC}"
            if qbittorrent_curl "/api/v2/app/version" -f >/dev/null 2>&1; then
                echo -e "${CYAN}qBittorrent API test:${NC} ${GREEN}OK${NC}"
            else
                echo -e "${CYAN}qBittorrent API test:${NC} ${RED}FAILED${NC}"
            fi

            # Show partial preferences response for debugging
            local debug_response
            debug_response=$(qbittorrent_curl "/api/v2/app/preferences" -f 2>/dev/null || echo "")
            if [[ -n "$debug_response" ]]; then
                echo -e "${CYAN}API response contains listen_port:${NC} $(printf '%s\n' "$debug_response" | grep -q "listen_port" && echo -e "${GREEN}YES${NC}" || echo -e "${RED}NO${NC}")"
                echo -e "${CYAN}Raw listen_port line:${NC} $(printf '%s\n' "$debug_response" | grep -o '"listen_port"[^,}]*' || echo -e "${RED}NOT FOUND${NC}")"
            else
                echo -e "${RED}No API response received${NC}"
            fi
            ;;
        --force)
            # Force update qBittorrent to match WireGuard
            local current_port
            current_port=$(get_wireguard_port || echo "")
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
            echo "  NAT-PMP lifetime request: ${NATPMP_LIFETIME}s (retries: ${NATPMP_RETRIES})"
            echo "  Renewal check interval: ${CHECK_INTERVAL}s"
            echo "  Force restart on port change: $QBITTORRENT_FORCE_RESTART"
            echo "  Fallback restart on hot-apply failure: $QBITTORRENT_RESTART_ON_FAILURE"
            echo "  Log file: $LOG_FILE (max ${LOG_MAX_BYTES} bytes)"
            echo

            echo -e "${YELLOW}Testing WireGuard...${NC}"
            if command -v wg >/dev/null 2>&1; then
                echo -e "  ${GREEN}✓${NC} wg command available"
                if wg show "$WG_INTERFACE" >/dev/null 2>&1; then
                    local wg_port
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
            local version
            if version=$(qbittorrent_curl "/api/v2/app/version" -f 2>/dev/null); then
                echo -e "  ${GREEN}✓${NC} qBittorrent API accessible"
                echo -e "  ${GREEN}✓${NC} Version: ${BLUE}$version${NC}"

                echo "  Testing preferences API..."
                local prefs_response
                if prefs_response=$(qbittorrent_curl "/api/v2/app/preferences" -f 2>/dev/null); then
                    echo -e "  ${GREEN}✓${NC} Preferences API working"
                    if printf '%s\n' "$prefs_response" | grep -q "listen_port"; then
                        echo -e "  ${GREEN}✓${NC} listen_port found in response"
                        local port_line parsed_port
                        port_line=$(printf '%s\n' "$prefs_response" | grep -o '"listen_port"[^,}]*' || true)
                        echo -e "  ${GREEN}✓${NC} Raw port data: ${BLUE}$port_line${NC}"
                        parsed_port=$(get_qbittorrent_port)
                        echo -e "  ${GREEN}✓${NC} Parsed port: ${BLUE}'$parsed_port'${NC}"
                        if [[ -z "$parsed_port" ]]; then
                            echo -e "  ${YELLOW}⚠${NC} Port parsing failed - trying manual extraction:"
                            echo "    Method 1: $(printf '%s\n' "$prefs_response" | grep -oE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$' || true)"
                            echo "    Method 2: $(printf '%s\n' "$prefs_response" | sed -n 's/.*"listen_port"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' || true)"
                        fi
                    else
                        echo -e "  ${RED}✗${NC} listen_port not found in preferences"
                        echo "  Checking for alternative field names..."
                        if printf '%s\n' "$prefs_response" | grep -q '"port"'; then
                            echo "    Found 'port' field: $(printf '%s\n' "$prefs_response" | grep -o '"port"[^,}]*' || true)"
                        fi
                        echo "  Response preview: $(printf '%s' "$prefs_response" | head -c 300)..."
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
            echo "Configuration variables (override via environment):"
            echo "  WG_INTERFACE                     WireGuard interface (default: wg0)"
            echo "  QBITTORRENT_HOST/PORT            WebUI address (default: localhost:8080)"
            echo "  QBITTORRENT_USERNAME/PASSWORD    Optional WebUI credentials"
            echo "  QBITTORRENT_RESTART_COMMAND      Emergency fallback restart command"
            echo "  QBITTORRENT_RESTART_WAIT         Seconds to wait after restart (default: $QBITTORRENT_RESTART_WAIT)"
            echo "  QBITTORRENT_FORCE_RESTART        Always restart on port change if 1 (default: $QBITTORRENT_FORCE_RESTART)"
            echo "  QBITTORRENT_RESTART_ON_FAILURE   Fallback restart if hot-apply fails (default: $QBITTORRENT_RESTART_ON_FAILURE)"
            echo "  NATPMP_GATEWAY                   Override detected NAT-PMP gateway"
            echo "  NATPMP_LIFETIME                  Requested NAT-PMP lease lifetime in seconds (default: $NATPMP_LIFETIME)"
            echo "  NATPMP_RETRIES                   Max natpmpc attempts per protocol (default: $NATPMP_RETRIES)"
            echo "  CHECK_INTERVAL                   Target renewal interval in seconds (default: $CHECK_INTERVAL)"
            echo "  LOG_MAX_BYTES                    Rotate log file above size in bytes (default: $LOG_MAX_BYTES)"
            echo "  DEBUG=1                          Enable debug logging"
            echo "  DEBUG_PAYLOAD_PREVIEW            Max debug payload length (default: $DEBUG_PAYLOAD_PREVIEW)"
            echo ""
            echo "Log file location: $LOG_FILE"
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
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_cli "$@"
fi
