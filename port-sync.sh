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
QBITTORRENT_HOST="localhost"
QBITTORRENT_PORT="8080"
QBITTORRENT_URL="http://${QBITTORRENT_HOST}:${QBITTORRENT_PORT}"
WG_INTERFACE="wg0"  # Default WireGuard interface name

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

# Get WireGuard listening port
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
    
    # Get preferences from qBittorrent Web API
    response=$(curl -s -f "${QBITTORRENT_URL}/api/v2/app/preferences" 2>/dev/null || echo "")
    
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

# Set qBittorrent port
set_qbittorrent_port() {
    local new_port="$1"
    
    # Set the new port via qBittorrent Web API
    local response
    response=$(curl -s -f -X POST \
        "${QBITTORRENT_URL}/api/v2/app/setPreferences" \
        -d "json={\"listen_port\":${new_port}}" \
        2>/dev/null || echo "")
    
    if [[ $? -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Check if qBittorrent is running and accessible
check_qbittorrent() {
    if curl -s -f "${QBITTORRENT_URL}/api/v2/app/version" >/dev/null 2>&1; then
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
        exit 1
    fi
    
    # Get current WireGuard port
    local current_wg_port
    if ! current_wg_port=$(get_wireguard_port); then
        log_error "Could not determine WireGuard listening port"
        log_error "Please ensure WireGuard interface '${WG_INTERFACE}' is active"
        exit 1
    fi
    
    log "Current WireGuard port: ${BLUE}$current_wg_port${NC}"
    
    # Get current qBittorrent port
    local current_qbt_port
    current_qbt_port=$(get_qbittorrent_port)
    
    if [[ -z "$current_qbt_port" ]]; then
        log_error "Could not determine current qBittorrent port"
        exit 1
    fi
    
    log "Current qBittorrent port: ${BLUE}$current_qbt_port${NC}"
    
    # Compare ports and update if different
    if [[ "$current_qbt_port" != "$current_wg_port" ]]; then
        log_warning "Port mismatch detected - updating qBittorrent from ${RED}$current_qbt_port${NC} to ${GREEN}$current_wg_port${NC}"
        
        # Update qBittorrent port
        if set_qbittorrent_port "$current_wg_port"; then
            log_success "Updated qBittorrent port to: $current_wg_port"
            
            # Verify the change
            local verified_port
            verified_port=$(get_qbittorrent_port)
            if [[ "$verified_port" == "$current_wg_port" ]]; then
                log_success "Port update verified: qBittorrent is now using port $verified_port"
            else
                log_warning "Port verification failed. qBittorrent reports port: $verified_port"
            fi
        else
            log_error "Failed to update qBittorrent port to: $current_wg_port"
            exit 1
        fi
    else
        log_success "Ports match (${GREEN}$current_wg_port${NC}), no action needed"
    fi
    
    log_success "Port sync check completed successfully"
}

# Daemon mode - continuous monitoring with event detection
daemon_mode() {
    log "Starting daemon mode - continuous port monitoring"
    log "Monitoring WireGuard interface: $WG_INTERFACE"
    log "Monitoring qBittorrent at: $QBITTORRENT_URL"
    
    # Initial sync
    main
    
    local last_wg_port=""
    local check_interval=30  # Check every 30 seconds (more responsive than cron)
    local config_check_interval=300  # Check config file changes every 5 minutes
    local last_config_check=0
    
    while true; do
        current_time=$(date +%s)
        
        # Get current WireGuard port
        current_wg_port=$(get_wireguard_port 2>/dev/null || echo "")
        
        if [[ -n "$current_wg_port" ]]; then
            # Check if WireGuard port changed
            if [[ "$current_wg_port" != "$last_wg_port" ]]; then
                if [[ -n "$last_wg_port" ]]; then
                    log_warning "WireGuard port changed from $last_wg_port to $current_wg_port"
                fi
                
                # Sync ports
                current_qbt_port=$(get_qbittorrent_port 2>/dev/null || echo "")
                if [[ -n "$current_qbt_port" && "$current_qbt_port" != "$current_wg_port" ]]; then
                    log_warning "Port mismatch detected - updating qBittorrent from $current_qbt_port to $current_wg_port"
                    
                    if set_qbittorrent_port "$current_wg_port"; then
                        log_success "Updated qBittorrent port to: $current_wg_port"
                        
                        # Verify the change
                        verified_port=$(get_qbittorrent_port)
                        if [[ "$verified_port" == "$current_wg_port" ]]; then
                            log_success "Port sync verified: Both services using port $verified_port"
                        else
                            log_warning "Port verification failed. qBittorrent reports: $verified_port"
                        fi
                    else
                        log_error "Failed to update qBittorrent port to: $current_wg_port"
                    fi
                else
                    log "Ports already match ($current_wg_port), no action needed"
                fi
                
                last_wg_port="$current_wg_port"
            fi
        else
            if [[ -n "$last_wg_port" ]]; then
                log_warning "WireGuard interface $WG_INTERFACE appears to be down"
                last_wg_port=""
            fi
        fi
        
        # Periodic health check (every 5 minutes)
        if (( current_time - last_config_check > config_check_interval )); then
            if ! check_qbittorrent; then
                log_warning "qBittorrent Web UI is not accessible - will retry on next cycle"
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
        echo -e "${CYAN}qBittorrent API test:${NC} $(curl -s -f "${QBITTORRENT_URL}/api/v2/app/version" 2>/dev/null && echo -e " ${GREEN}OK${NC}" || echo -e " ${RED}FAILED${NC}")"
        
        # Show partial preferences response for debugging
        debug_response=$(curl -s -f "${QBITTORRENT_URL}/api/v2/app/preferences" 2>/dev/null || echo "")
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
        if curl -s -f "${QBITTORRENT_URL}/api/v2/app/version" >/dev/null 2>&1; then
            version=$(curl -s "${QBITTORRENT_URL}/api/v2/app/version" 2>/dev/null || echo "unknown")
            echo -e "  ${GREEN}✓${NC} qBittorrent API accessible"
            echo -e "  ${GREEN}✓${NC} Version: ${BLUE}$version${NC}"
            
            echo "  Testing preferences API..."
            prefs_response=$(curl -s -f "${QBITTORRENT_URL}/api/v2/app/preferences" 2>/dev/null || echo "")
            if [[ -n "$prefs_response" ]]; then
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