#!/bin/bash

# Quick installation script for qBittorrent WireGuard Port Sync

# ----------------------------------------------------------------------------
# Early constants and defaults (must be set before any use)
# ----------------------------------------------------------------------------
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/port-sync.sh"

# Repo metadata
GITHUB_RAW_URL="https://raw.githubusercontent.com/Simon-CR/qbittorrent-wireguard-pmp/main"
# Derive version from git if possible, else fallback
SCRIPT_VERSION="${SCRIPT_VERSION:-$(git -C "$SCRIPT_DIR" describe --tags --always 2>/dev/null || git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "dev")}"

# Core project files that should be kept in sync during updates
CORE_FILES=(
    "install.sh"
    "port-sync.sh"
    "service-manager.sh"
    "qbittorrent-wireguard-sync.service"
    "README.md"
)

# Help function
show_help() {
    echo "qBittorrent WireGuard Port Sync Installer v$SCRIPT_VERSION"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --update, -u     Self-update the installer and scripts"
    echo "  --manage, -m     Manage the systemd service"
    echo "  --help, -h       Show this help message"
    echo
    echo "Default behavior (no options): Run the full installation/setup wizard"
}

download_core_files() {
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "${RED}✗ curl is required to download updates${NC}"
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d) || {
        echo -e "${RED}✗ Failed to create temporary directory for updates${NC}"
        return 1
    }

    echo -e "${BLUE}Fetching latest project files...${NC}"

    local file success=true
    for file in "${CORE_FILES[@]}"; do
        local remote_url="${GITHUB_RAW_URL}/${file}"
        local tmp_path="${tmpdir}/${file}"

        echo -n "  • ${file}... "
        if curl -fsSL -o "$tmp_path" "$remote_url"; then
            echo -e "${GREEN}ok${NC}"
        else
            echo -e "${RED}failed${NC}"
            success=false
        fi
    done

    if [[ "$success" != true ]]; then
        echo -e "${RED}✗ One or more files could not be downloaded. Update aborted.${NC}"
        rm -rf "$tmpdir"
        return 1
    fi

    for file in "${CORE_FILES[@]}"; do
        local tmp_path="${tmpdir}/${file}"
        local dest_path="${SCRIPT_DIR}/${file}"

        install -D "$tmp_path" "$dest_path"

        case "$file" in
            *.sh)
                chmod 755 "$dest_path" 2>/dev/null || true
                ;;
            *.service)
                chmod 644 "$dest_path" 2>/dev/null || true
                ;;
            *)
                chmod 644 "$dest_path" 2>/dev/null || true
                ;;
        esac
    done

    rm -rf "$tmpdir"
    echo -e "${GREEN}✓ All project files refreshed${NC}"
    return 0
}

# Refresh installed systemd service unit to the latest template while preserving env
refresh_service_unit() {
    local svc_name="qbittorrent-wireguard-sync"
    local svc_path="/etc/systemd/system/${svc_name}.service"
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    if ! systemctl is-enabled "$svc_name" >/dev/null 2>&1; then
        return 0
    fi
    if [[ ! -f "$svc_path" ]]; then
        return 0
    fi

    local template_path="$SCRIPT_DIR/qbittorrent-wireguard-sync.service"
    if [[ ! -f "$template_path" ]]; then
        echo -e "${YELLOW}⚠ Service template not found; skipping automatic refresh${NC}"
        return 0
    fi

    if [[ ! "$template_path" -nt "$svc_path" ]]; then
        echo -e "${GREEN}✓ Service unit already matches current template${NC}"
        return 0
    fi

    echo -e "${BLUE}Refreshing installed systemd service unit${NC}"
    echo "Detected installed unit: $svc_path"

    # Parse current env values from the installed unit
    local cur_wg cur_qp cur_gw
    cur_wg=$(grep -E '^Environment=WG_INTERFACE=' "$svc_path" 2>/dev/null | head -1 | awk -F '=' '{print $3}')
    cur_qp=$(grep -E '^Environment=QB_PORT=' "$svc_path" 2>/dev/null | head -1 | awk -F '=' '{print $3}')
    cur_gw=$(grep -E '^Environment=NATPMP_GATEWAY=' "$svc_path" 2>/dev/null | head -1 | awk -F '=' '{print $3}')

    [[ -z "$cur_wg" ]] && cur_wg="wg0"
    [[ -z "$cur_qp" ]] && cur_qp="8080"

    echo "Current settings: WG_INTERFACE=${cur_wg}, QB_PORT=${cur_qp}, NATPMP_GATEWAY=${cur_gw:-<unset>}"

    if ask_confirm "Refresh service unit to latest template (preserve these values)?" Y; then
        local _out
        _out=$(mktemp)
        if sudo bash "$SCRIPT_DIR/service-manager.sh" --install -y \
            --wg-interface "$cur_wg" --qb-port "$cur_qp" \
            ${cur_gw:+--natpmp-gateway "$cur_gw"} --no-start >"$_out" 2>&1; then
            echo -e "${GREEN}✓ Service unit refreshed${NC}"
            sudo systemctl daemon-reload || true
            if ask_confirm "Restart ${svc_name} now to apply changes?" Y; then
                if sudo systemctl restart "$svc_name"; then
                    echo -e "${GREEN}✓ Service restarted${NC}"
                else
                    echo -e "${YELLOW}⚠ Failed to restart service. Check logs with: sudo journalctl -u ${svc_name} -n 50${NC}"
                fi
            else
                echo "You can restart later with: sudo systemctl restart ${svc_name}"
            fi
        else
            echo -e "${YELLOW}⚠ Service refresh encountered issues. Output (last 50 lines):${NC}"
            tail -n 50 "$_out" || true
        fi
        rm -f "$_out"
    fi
}

# Prompt helper: confirm with default
# Usage: ask_confirm "Message" [Default]
# Default: "Y" or "N" (case-insensitive). Returns 0 for Yes, 1 for No.
ask_confirm() {
    local prompt="$1"
    local default="${2:-Y}"
    local def_upper def_suffix reply
    def_upper=$(echo "$default" | tr '[:lower:]' '[:upper:]')
    if [[ "$def_upper" == "Y" ]]; then
        def_suffix="(Y/n)"
    else
        def_suffix="(y/N)"
    fi
    read -r -p "$prompt $def_suffix: " reply
    if [[ -z "$reply" ]]; then
        # Empty input -> take default
        if [[ "$def_upper" == "Y" ]]; then
            return 0
        else
            return 1
        fi
    fi
    case "$(echo "$reply" | tr '[:upper:]' '[:lower:]')" in
        y|yes) return 0 ;;
        n|no)  return 1 ;;
        *)
            # Unrecognized -> take default
            if [[ "$def_upper" == "Y" ]]; then
                return 0
            else
                return 1
            fi
            ;;
    esac
}

# Self-update function
self_update() {
    local assume_yes=0
    if [[ "${1:-}" == "--yes" ]]; then
        assume_yes=1
    fi
    echo -e "${BLUE}Self-Update${NC}"
    echo "==========="
    echo "Current version: $SCRIPT_VERSION"
    echo "Checking for updates..."
    
    # Check if we're in a git repository
    if [[ -d .git ]]; then
        echo "Git repository detected. Checking for updates..."
        
        # Fetch latest changes
        if git fetch origin main >/dev/null 2>&1; then
            # Check if we're behind
            if ! git diff --quiet HEAD origin/main; then
                echo -e "${YELLOW}Updates available!${NC}"
                echo
                git log --oneline HEAD..origin/main | head -5
                echo
                if [[ $assume_yes -eq 1 ]] || ask_confirm "Update to latest version?" N; then
                    echo "Updating..."
                    
                    # Stash any local changes to preserve file permissions
                    git stash push -m "Auto-stash before update" >/dev/null 2>&1
                    
                    # Pull latest changes
                    if git pull origin main; then
                        echo -e "${GREEN}✓ Updated successfully${NC}"
                        
                        # Restore executable permissions
                        chmod +x install.sh 2>/dev/null || true
                        chmod +x port-sync.sh 2>/dev/null || true
                        chmod +x service-manager.sh 2>/dev/null || true
                        
                        echo -e "${GREEN}✓ File permissions restored${NC}"
                        echo
                        echo "Update complete! You can now run the installer."
                        return 0
                    else
                        echo -e "${RED}✗ Failed to update${NC}"
                        return 1
                    fi
                else
                    echo "Update cancelled."
                    return 0
                fi
            else
                echo -e "${GREEN}✓ Already up to date${NC}"
                return 0
            fi
        else
            echo -e "${YELLOW}⚠ Could not check for updates (network/git issue)${NC}"
            return 1
        fi
    else
        echo "Direct download mode (no git repository detected)."

        local tmp_install
        tmp_install=$(mktemp) || {
            echo -e "${RED}✗ Failed to create temporary file for update check${NC}"
            return 1
        }

        if curl -fsSL -o "$tmp_install" "$GITHUB_RAW_URL/install.sh"; then
            if ! cmp -s "$SCRIPT_DIR/install.sh" "$tmp_install"; then
                echo -e "${YELLOW}⚠ Updates available for project files${NC}"
                if [[ $assume_yes -eq 1 ]] || ask_confirm "Download and replace core files now?" Y; then
                    if download_core_files; then
                        echo
                        echo -e "${GREEN}✓ Update complete. Please re-run the installer.${NC}"
                        rm -f "$tmp_install"
                        return 0
                    else
                        rm -f "$tmp_install"
                        return 1
                    fi
                else
                    echo "Continuing with current version."
                fi
            else
                echo -e "${GREEN}✓ Already up to date${NC}"
            fi
            rm -f "$tmp_install"
            return 0
        else
            echo -e "${RED}✗ Failed to check for updates (network/curl issue)${NC}"
            rm -f "$tmp_install"
            return 1
        fi
    fi
}

# Service helpers
service_installed() {
    systemctl is-enabled qbittorrent-wireguard-sync >/dev/null 2>&1
}

ensure_service_assets() {
    if [[ ! -f "$MAIN_SCRIPT" ]]; then
        echo "port-sync.sh not found. Attempting to download..."
        if command -v curl >/dev/null 2>&1 && curl -fsSL -o "$MAIN_SCRIPT" "$GITHUB_RAW_URL/port-sync.sh"; then
            chmod +x "$MAIN_SCRIPT"
            echo -e "  ${GREEN}✓ port-sync.sh downloaded${NC}"
        else
            echo -e "  ${RED}✗ Failed to download port-sync.sh${NC}"
        fi
    fi

    if [[ ! -f "$SCRIPT_DIR/service-manager.sh" ]]; then
        echo "service-manager.sh not found. Downloading..."
        if command -v curl >/dev/null 2>&1 && curl -fsSL -o "$SCRIPT_DIR/service-manager.sh" "$GITHUB_RAW_URL/service-manager.sh"; then
            chmod +x "$SCRIPT_DIR/service-manager.sh"
            echo -e "  ${GREEN}✓ service-manager.sh downloaded${NC}"
        else
            echo -e "  ${RED}✗ Failed to download service-manager.sh${NC}"
        fi
    fi

    if [[ ! -f "$SCRIPT_DIR/qbittorrent-wireguard-sync.service" ]]; then
        echo "qbittorrent-wireguard-sync.service missing. Downloading..."
        if command -v curl >/dev/null 2>&1 && curl -fsSL -o "$SCRIPT_DIR/qbittorrent-wireguard-sync.service" "$GITHUB_RAW_URL/qbittorrent-wireguard-sync.service"; then
            echo -e "  ${GREEN}✓ Service unit template downloaded${NC}"
        else
            echo -e "  ${RED}✗ Failed to download service unit template${NC}"
        fi
    fi
}

install_or_update_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}✗ systemctl not available. Systemd service cannot be installed.${NC}"
        return 1
    fi

    ensure_service_assets

    if [[ ! -f "$SCRIPT_DIR/service-manager.sh" ]]; then
        echo -e "${RED}✗ service-manager.sh could not be downloaded${NC}"
        return 1
    fi

    echo -e "${BLUE}Configuring systemd service...${NC}"

    local sm_gateway=""
    if command -v ip >/dev/null 2>&1; then
        local if_ip
        if_ip=$(ip -4 addr show dev "$WG_INTERFACE" 2>/dev/null | awk '/inet /{print $2}' | head -1 | cut -d'/' -f1)
        if [[ "$if_ip" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
            sm_gateway="${BASH_REMATCH[1]}.1"
        fi
    fi

    if [[ -n "$sm_gateway" ]]; then
        if natpmpc -g "$sm_gateway" -a 1 0 udp 1 >/dev/null 2>&1; then
            echo "  NAT-PMP gateway: $sm_gateway"
        else
            echo -e "${YELLOW}⚠ Unable to validate NAT-PMP gateway $sm_gateway, proceeding without explicit gateway.${NC}"
            sm_gateway=""
        fi
    else
        echo -e "${YELLOW}⚠ Unable to derive NAT-PMP gateway automatically.${NC}"
    fi

    local svc_log
    svc_log=$(mktemp)
    if bash "$SCRIPT_DIR/service-manager.sh" --install -y \
        --wg-interface "$WG_INTERFACE" --qb-port "$QB_PORT" \
        ${sm_gateway:+--natpmp-gateway "$sm_gateway"} --start >"$svc_log" 2>&1; then
        echo -e "${GREEN}✓ Systemd service installed/updated${NC}"
        rm -f "$svc_log"
        return 0
    else
        echo -e "${RED}✗ Failed to configure systemd service${NC}"
        echo -e "${YELLOW}— Service installer output (last 50 lines) —${NC}"
        tail -n 50 "$svc_log" || true
        rm -f "$svc_log"
        return 1
    fi
}

remove_service() {
    if [[ -f "$SCRIPT_DIR/service-manager.sh" ]]; then
        bash "$SCRIPT_DIR/service-manager.sh" --uninstall
    else
        echo -e "${YELLOW}⚠ service-manager.sh missing; attempting manual removal${NC}"
        sudo systemctl stop qbittorrent-wireguard-sync 2>/dev/null || true
        sudo systemctl disable qbittorrent-wireguard-sync 2>/dev/null || true
        sudo rm -f /etc/systemd/system/qbittorrent-wireguard-sync.service
        sudo systemctl daemon-reload
    fi
}

manage_deployments() {
    echo -e "${BLUE}Service Management${NC}"
    echo "=================="

    ensure_service_assets
    if [[ ! -f "$SCRIPT_DIR/service-manager.sh" ]]; then
        echo -e "${RED}✗ service-manager.sh is unavailable; try running '$0 --update' first.${NC}"
        return 1
    fi
    chmod +x "$SCRIPT_DIR/service-manager.sh" 2>/dev/null || true
    bash "$SCRIPT_DIR/service-manager.sh"
}

# Check for command line arguments
case "${1:-}" in
    "--update"|"-u")
        self_update
        exit $?
        ;;
    "--help"|"-h")
        show_help
        exit 0
        ;;
    "--manage"|"-m")
        manage_deployments
        exit $?
        ;;
esac

# Installation script for qBittorrent WireGuard Port Sync
# This script helps set up the port sync script and systemd service

:

# Check if we're running with bash, not sh
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash, not sh"
    echo "Please run with: bash $0 or chmod +x $0 && ./$0"
    exit 1
fi

set -euo pipefail

# ============================================================================
# MAIN INSTALLATION EXECUTION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="${SCRIPT_DIR}/port-sync.sh"

echo -e "${BLUE}qBittorrent WireGuard Port Sync - Installation Script${NC}"
echo "===================================================="
echo "Version: $SCRIPT_VERSION"
echo


# Check for updates first
echo "Checking for updates..."
if [[ -d .git ]] && command -v git >/dev/null 2>&1; then
    if git fetch origin main >/dev/null 2>&1; then
        if ! git diff --quiet HEAD origin/main; then
            echo -e "${YELLOW}⚠ Updates available!${NC}"
            echo
            git --no-pager log --oneline HEAD..origin/main | head -5
            echo
            if ask_confirm "Update now?" Y; then
                echo "Updating..."
                if self_update --yes; then
                    echo -e "${GREEN}✓ Updated. Restarting installer...${NC}"
                    exec bash "$0" "$@"
                else
                    echo -e "${YELLOW}⚠ Update failed or skipped.${NC}"
                    if ! ask_confirm "Continue with current version?" Y; then
                        echo "Exiting. Run '$0 --update' to retry update."
                        exit 1
                    fi
                fi
            else
                echo "Continuing with current version."
            fi
        else
            echo -e "${GREEN}✓ Already up to date${NC}"
            # If a systemd service is installed, offer to refresh unit from latest template
            refresh_service_unit
        fi
    fi
else
    if command -v curl >/dev/null 2>&1; then
        local tmp_remote_install
        tmp_remote_install=$(mktemp) || true
        if [[ -n "$tmp_remote_install" ]] && curl -fsSL -o "$tmp_remote_install" "$GITHUB_RAW_URL/install.sh"; then
            if [[ ! -f "$SCRIPT_DIR/install.sh" ]] || ! cmp -s "$SCRIPT_DIR/install.sh" "$tmp_remote_install"; then
                echo -e "${YELLOW}⚠ Updates available!${NC}"
                if ask_confirm "Download latest project files now?" Y; then
                    if download_core_files; then
                        echo -e "${GREEN}✓ Update complete. Restarting installer...${NC}"
                        rm -f "$tmp_remote_install"
                        exec bash "$0" "$@"
                    else
                        echo -e "${YELLOW}⚠ Update failed or skipped.${NC}"
                    fi
                else
                    echo "Continuing with current version."
                fi
            else
                echo -e "${GREEN}✓ Already up to date${NC}"
                refresh_service_unit
            fi
        fi
        rm -f "$tmp_remote_install" 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠ Skipping update check (curl not available)${NC}"
    fi
fi

# Check natpmpc dependency before proceeding
if ! command -v natpmpc >/dev/null 2>&1; then
    echo -e "${YELLOW}natpmpc not found. Attempting to install...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y natpmpc
    elif command -v brew >/dev/null 2>&1; then
        brew install natpmpc
    else
        echo -e "${RED}Could not auto-install natpmpc. Please install it manually and re-run the installer.${NC}"
        exit 1
    fi
    # Re-check natpmpc
    if ! command -v natpmpc >/dev/null 2>&1; then
        echo -e "${RED}natpmpc installation failed. Please install it manually and re-run the installer.${NC}"
        exit 1
    fi
fi

# Check if this is a re-run (existing service deployment)
service_present=false
if service_installed; then
    service_present=true
    echo -e "${YELLOW}Existing systemd service detected.${NC}"
    echo "  Use '--manage' to launch the service manager directly."
    echo
    echo "Options:"
    echo "1. Continue with setup (reconfigure service)"
    echo "2. Open service manager"
    echo "3. Exit"
    read -p "Choose option [1-3]: " existing_choice

    case $existing_choice in
        1)
            echo "Continuing with setup..."
            ;;
        2)
            manage_deployments
            exit $?
            ;;
        3)
            echo "Exiting. Use '$0 --manage' anytime to manage the service."
            exit 0
            ;;
        *)
            echo "Continuing with setup..."
            ;;
    esac
    echo
fi

# Check if main script exists
if [[ ! -f "$MAIN_SCRIPT" ]]; then
    echo -e "${RED}ERROR: port-sync.sh not found in $SCRIPT_DIR${NC}"
    echo "Please ensure you have the complete project files."
    exit 1
fi

# Make main script executable
chmod +x "$MAIN_SCRIPT"
echo -e "${GREEN}✓ Made port-sync.sh executable${NC}"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check dependencies
echo "Checking dependencies..."
dependencies_ok=true

if ! command_exists curl; then
    echo -e "${RED}✗ curl is not installed (required for qBittorrent API)${NC}"
    dependencies_ok=false
else
    echo -e "${GREEN}✓ curl is available${NC}"
fi

if ! command_exists wg; then
    echo -e "${RED}✗ WireGuard tools (wg command) not found${NC}"
    echo "  Install with: sudo apt update && sudo apt install wireguard-tools"
    dependencies_ok=false
else
    echo -e "${GREEN}✓ WireGuard tools are available${NC}"
fi

if [[ "$dependencies_ok" != "true" ]]; then
    echo
    echo "Please install missing dependencies and run this script again."
    exit 1
fi

echo

# Test WireGuard interface
echo "Checking WireGuard interface..."
WG_INTERFACE="wg0"  # Default - you can change this

if wg show "$WG_INTERFACE" >/dev/null 2>&1; then
    current_port=$(wg show "$WG_INTERFACE" listen-port 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✓ WireGuard interface '$WG_INTERFACE' is active (port: $current_port)${NC}"
else
    echo -e "${YELLOW}⚠ WireGuard interface '$WG_INTERFACE' not found or not active${NC}"
    echo "  Available interfaces:"
    available_ifaces_raw=$(wg show interfaces 2>/dev/null || true)
    if [[ -n "$available_ifaces_raw" ]]; then
        echo "$available_ifaces_raw"
    else
        echo "  None found"
    fi
    echo
    DEFAULT_IFACE="$WG_INTERFACE"
    if [[ -n "$available_ifaces_raw" ]]; then
        available_ifaces=$(echo "$available_ifaces_raw" | tr ' ' '\n' | awk 'NF')
        iface_count=$(echo "$available_ifaces" | wc -l | tr -d '[:space:]')
        if [[ "$iface_count" == "1" ]]; then
            DEFAULT_IFACE=$(echo "$available_ifaces" | head -1)
        fi
    fi
    read -p "Enter your WireGuard interface name (or press Enter to continue with '$DEFAULT_IFACE'): " user_interface
    if [[ -n "$user_interface" ]]; then
        WG_INTERFACE="$user_interface"
    else
        WG_INTERFACE="$DEFAULT_IFACE"
    fi
    echo -e "${BLUE}Will use interface: $WG_INTERFACE${NC}"
    echo -e "${GREEN}✓ Selected interface will be passed via environment${NC}"
fi

# Function to check if qBittorrent is running
check_qbittorrent_running() {
    # Check if qbittorrent process is running
    if pgrep -f qbittorrent >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Function to detect qBittorrent Web UI port from config
detect_qbittorrent_port() {
    local config_paths=(
        # Standard Linux locations
        "$HOME/.config/qBittorrent/qBittorrent.conf"
        "/root/.config/qBittorrent/qBittorrent.conf"
        # Flatpak location
        "$HOME/.var/app/org.qbittorrent.qBittorrent/config/qBittorrent/qBittorrent.conf"
        # Snap location
        "$HOME/snap/qbittorrent-arnatious/current/.config/qBittorrent/qBittorrent.conf"
    )
    
    # Method 1: Try to find from config files
    for config_file in "${config_paths[@]}"; do
        if [[ -f "$config_file" ]]; then
            # Look for WebUI\Port setting
            local port=$(grep -E "^WebUI\\\\Port=" "$config_file" 2>/dev/null | cut -d'=' -f2 | tr -d '\r\n' || echo "")
            if [[ -n "$port" && "$port" =~ ^[0-9]+$ ]]; then
                echo "$port"
                return 0
            fi
        fi
    done
    
    # Method 2: Use netstat/ss to find qBittorrent Web UI port
    if command -v ss >/dev/null 2>&1; then
        # Try to find qbittorrent process listening on TCP ports
        local ports=$(ss -tlnp 2>/dev/null | grep -i qbittorrent | grep -oE ':[0-9]+' | cut -d':' -f2 | sort -u)
        for port in $ports; do
            # Test if this port responds to qBittorrent API
            if curl -s -f "http://localhost:$port/api/v2/app/version" >/dev/null 2>&1; then
                echo "$port"
                return 0
            fi
        done
    elif command -v netstat >/dev/null 2>&1; then
        # Fallback to netstat if ss is not available
        local ports=$(netstat -tlnp 2>/dev/null | grep -i qbittorrent | grep -oE ':[0-9]+' | cut -d':' -f2 | sort -u)
        for port in $ports; do
            # Test if this port responds to qBittorrent API
            if curl -s -f "http://localhost:$port/api/v2/app/version" >/dev/null 2>&1; then
                echo "$port"
                return 0
            fi
        done
    fi
    
    # Method 3: If process detection fails, try scanning common ports
    local common_ports=(8080 8090 8081 8888 9090)
    for port in "${common_ports[@]}"; do
        if curl -s -f "http://localhost:$port/api/v2/app/version" >/dev/null 2>&1; then
            echo "$port"
            return 0
        fi
    done
    
    # Default port if not found
    echo "8080"
    return 1
}

echo

# Test qBittorrent connection with port detection
echo "Detecting qBittorrent configuration..."

# First check if qBittorrent is running
if check_qbittorrent_running; then
    echo -e "${GREEN}✓ qBittorrent process is running${NC}"
else
    echo -e "${YELLOW}⚠ qBittorrent process not detected${NC}"
    echo "  Please ensure qBittorrent is running before continuing"
fi

DETECTED_PORT=$(detect_qbittorrent_port)
detection_result=$?

if [[ $detection_result -eq 0 ]]; then
    # Check which method found the port
    config_found=false
    process_found=false
    
    # Check if found via config file
    config_paths=(
        "$HOME/.config/qBittorrent/qBittorrent.conf"
        "/root/.config/qBittorrent/qBittorrent.conf"
        "$HOME/.var/app/org.qbittorrent.qBittorrent/config/qBittorrent/qBittorrent.conf"
        "$HOME/snap/qbittorrent-arnatious/current/.config/qBittorrent/qBittorrent.conf"
        "$HOME/.config/qBittorrent/qBittorrent.conf"
    )
    
    for config_file in "${config_paths[@]}"; do
        if [[ -f "$config_file" ]] && grep -q "WebUI\\\\Port=$DETECTED_PORT" "$config_file" 2>/dev/null; then
            config_found=true
            echo -e "${GREEN}✓ Found qBittorrent config file with Web UI port: $DETECTED_PORT${NC}"
            break
        fi
    done
    
    # Check if found via process detection
    if [[ "$config_found" == "false" ]]; then
        if command -v ss >/dev/null 2>&1; then
            if ss -tlnp 2>/dev/null | grep -i qbittorrent | grep -q ":$DETECTED_PORT "; then
                process_found=true
                echo -e "${GREEN}✓ Detected qBittorrent process running on port: $DETECTED_PORT${NC}"
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tlnp 2>/dev/null | grep -i qbittorrent | grep -q ":$DETECTED_PORT "; then
                process_found=true
                echo -e "${GREEN}✓ Detected qBittorrent process running on port: $DETECTED_PORT${NC}"
            fi
        fi
    fi
    
    if [[ "$config_found" == "false" && "$process_found" == "false" ]]; then
        echo -e "${GREEN}✓ Found qBittorrent Web UI responding on port: $DETECTED_PORT${NC}"
    fi
    
    QB_PORT="$DETECTED_PORT"
else
    echo -e "${YELLOW}⚠ Could not auto-detect qBittorrent Web UI port${NC}"
    echo "  Checked config files, running processes, and common ports"
    QB_PORT="8080"
fi

echo "Testing qBittorrent Web UI..."
read -p "Enter qBittorrent Web UI port [$QB_PORT]: " user_port
if [[ -n "$user_port" ]]; then
    QB_PORT="$user_port"
fi

QB_URL="http://localhost:$QB_PORT"
echo "Using qBittorrent URL: $QB_URL"

if curl -s -f "${QB_URL}/api/v2/app/version" >/dev/null 2>&1; then
    qb_version=$(curl -s "${QB_URL}/api/v2/app/version" 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✓ qBittorrent Web UI is accessible (version: $qb_version)${NC}"
    echo -e "${GREEN}✓ Using qBittorrent port $QB_PORT (will be passed via environment)${NC}"
else
    echo -e "${RED}✗ qBittorrent Web UI is not accessible at $QB_URL${NC}"
    echo
    echo "Please ensure:"
    echo "1. qBittorrent is running"
    echo "2. Web UI is enabled in Tools → Options → Web UI"
    echo "3. Web UI port is $QB_PORT (or try a different port above)"
    echo "4. Authentication is disabled for localhost"
    echo
    read -p "Press Enter to continue anyway, or Ctrl+C to exit and fix qBittorrent setup..."
fi

echo

# Test the main script
echo "Testing the port sync script..."
if WG_INTERFACE="$WG_INTERFACE" QB_PORT="$QB_PORT" QBITTORRENT_PORT="$QB_PORT" "$MAIN_SCRIPT" --check; then
    echo -e "${GREEN}✓ Script test completed successfully${NC}"
else
    echo -e "${YELLOW}⚠ Script test had issues - check the output above${NC}"
fi

echo
if ask_confirm "Install or update the systemd service for continuous syncing?" Y; then
    install_or_update_service || echo -e "${YELLOW}⚠ Service installation encountered issues (see above).${NC}"
else
    echo -e "${YELLOW}Skipping service installation. You can manage it later with:${NC}"
    echo "  $0 --manage"
fi

echo
echo "Installation Complete!"
echo "===================="
echo
echo "Usage:"
echo "  $MAIN_SCRIPT                # Normal sync operation"
echo "  $MAIN_SCRIPT --check        # Check current status"
echo "  $MAIN_SCRIPT --force        # Force update qBittorrent"
echo "  $MAIN_SCRIPT --daemon       # Run as daemon service (~45s intervals)"
echo
echo "Management Commands:"
echo "  $0 --manage        # Launch interactive service manager"
echo "  $0 --update        # Self-update to latest version"
echo "  $0 --help          # Show help"
echo
echo "Service Management Shortcuts:"
echo "  bash $SCRIPT_DIR/service-manager.sh status   # Check service status"
echo "  bash $SCRIPT_DIR/service-manager.sh logs     # View service logs"
echo "  bash $SCRIPT_DIR/service-manager.sh restart  # Restart service"
echo "  bash $SCRIPT_DIR/service-manager.sh uninstall# Remove service"
echo
echo "Log files:"
echo "  $SCRIPT_DIR/port-sync.log    # Activity log"
echo
echo "For more information, see README.md"
echo
echo "You can test the script now by running:"
echo "  $MAIN_SCRIPT --check"