#!/bin/bash

# qBittorrent WireGuard Port Sync Script
# Monitors WireGuard listening port and updates qBittorrent when it changes
# Designed for Debian systems with qBittorrent Web UI and WireGuard

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/port-sync.log"
QBITTORRENT_HOST="localhost"
QBITTORRENT_PORT="8080"
QBITTORRENT_URL="http://${QBITTORRENT_HOST}:${QBITTORRENT_PORT}"
WG_INTERFACE="wg0"  # Default WireGuard interface name

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
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
        # Extract listen_port from JSON response
        echo "$response" | grep -o '"listen_port":[0-9]*' | cut -d':' -f2 || echo ""
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
        log "ERROR: qBittorrent Web UI is not accessible at ${QBITTORRENT_URL}"
        log "Please ensure qBittorrent is running and Web UI is enabled"
        exit 1
    fi
    
    # Get current WireGuard port
    local current_wg_port
    if ! current_wg_port=$(get_wireguard_port); then
        log "ERROR: Could not determine WireGuard listening port"
        log "Please ensure WireGuard interface '${WG_INTERFACE}' is active"
        exit 1
    fi
    
    log "Current WireGuard port: $current_wg_port"
    
    # Get current qBittorrent port
    local current_qbt_port
    current_qbt_port=$(get_qbittorrent_port)
    
    if [[ -z "$current_qbt_port" ]]; then
        log "ERROR: Could not determine current qBittorrent port"
        exit 1
    fi
    
    log "Current qBittorrent port: $current_qbt_port"
    
    # Compare ports and update if different
    if [[ "$current_qbt_port" != "$current_wg_port" ]]; then
        log "Port mismatch detected - updating qBittorrent from $current_qbt_port to $current_wg_port"
        
        # Update qBittorrent port
        if set_qbittorrent_port "$current_wg_port"; then
            log "Successfully updated qBittorrent port to: $current_wg_port"
            
            # Verify the change
            local verified_port
            verified_port=$(get_qbittorrent_port)
            if [[ "$verified_port" == "$current_wg_port" ]]; then
                log "Port update verified: qBittorrent is now using port $verified_port"
            else
                log "WARNING: Port verification failed. qBittorrent reports port: $verified_port"
            fi
        else
            log "ERROR: Failed to update qBittorrent port to: $current_wg_port"
            exit 1
        fi
    else
        log "Ports match ($current_wg_port), no action needed"
    fi
    
    log "Port sync check completed successfully"
}

# Handle script arguments
case "${1:-}" in
    --check)
        # Just check current status without making changes
        echo "WireGuard port: $(get_wireguard_port || echo 'ERROR')"
        echo "qBittorrent port: $(get_qbittorrent_port || echo 'ERROR')"
        ;;
    --force)
        # Force update qBittorrent to match WireGuard
        current_port=$(get_wireguard_port)
        if [[ -n "$current_port" ]]; then
            log "Force updating qBittorrent port to: $current_port"
            if set_qbittorrent_port "$current_port"; then
                log "Force update completed successfully"
            else
                log "ERROR: Force update failed"
                exit 1
            fi
        else
            log "ERROR: Could not determine WireGuard port for force update"
            exit 1
        fi
        ;;
    --help|-h)
        echo "qBittorrent WireGuard Port Sync Script"
        echo "Usage: $0 [--check|--force|--help]"
        echo ""
        echo "Options:"
        echo "  (no args)  Normal operation - sync ports if changed"
        echo "  --check    Display current port status without changes"
        echo "  --force    Force update qBittorrent to match WireGuard"
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
        echo "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
esac