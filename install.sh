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

# Deployment flags safe defaults
setup_cron=false
setup_service=false

# Help function
show_help() {
    echo "qBittorrent WireGuard Port Sync Installer v$SCRIPT_VERSION"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --update, -u     Self-update the installer and scripts"
    echo "  --manage, -m     Manage existing deployments (switch between cron/service)"
    echo "  --help, -h       Show this help message"
    echo
    echo "Default behavior (no options): Run the full installation/setup wizard"
}

# Self-update function
self_update() {
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
                read -p "Update to latest version? (y/N): " do_update
                
                if [[ "$do_update" =~ ^[Yy]$ ]]; then
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
        # Not a git repo, try downloading directly
        echo "Not a git repository. Attempting direct download update..."
        
        # Download latest install.sh
        if curl -s -o "install.sh.new" "$GITHUB_RAW_URL/install.sh"; then
            # Check if it's different
            if ! diff -q install.sh install.sh.new >/dev/null 2>&1; then
                echo -e "${YELLOW}Updates available!${NC}"
                read -p "Update installer? (y/N): " do_update
                
                if [[ "$do_update" =~ ^[Yy]$ ]]; then
                    mv install.sh.new install.sh
                    chmod +x install.sh
                    echo -e "${GREEN}✓ Installer updated${NC}"
                    echo "Please re-run the installer for the latest version."
                    return 0
                else
                    rm -f install.sh.new
                    return 0
                fi
            else
                rm -f install.sh.new
                echo -e "${GREEN}✓ Already up to date${NC}"
                return 0
            fi
        else
            echo -e "${RED}✗ Failed to check for updates${NC}"
            return 1
        fi
    fi
}

# Check existing deployments
check_existing_deployments() {
    local has_cron=false
    local has_service=false
    
    # Check for existing cron job
    if crontab -l 2>/dev/null | grep -q "port-sync.sh"; then
        has_cron=true
    fi
    
    # Check for existing systemd service
    if systemctl is-enabled qbittorrent-wireguard-sync >/dev/null 2>&1; then
        has_service=true
    fi
    
    echo "$has_cron,$has_service"
}

# Manage existing deployments
manage_deployments() {
    echo -e "${BLUE}Deployment Management${NC}"
    echo "===================="
    
    local deployment_status
    deployment_status=$(check_existing_deployments)
    IFS=',' read -r has_cron has_service <<< "$deployment_status"
    
    echo "Current deployment status:"
    if [[ "$has_cron" == "true" ]]; then
        echo -e "${GREEN}✓ Cron job active${NC}"
        crontab -l | grep "port-sync.sh"
    else
        echo -e "${YELLOW}○ No cron job found${NC}"
    fi
    
    if [[ "$has_service" == "true" ]]; then
        echo -e "${GREEN}✓ Systemd service installed${NC}"
        if systemctl is-active qbittorrent-wireguard-sync >/dev/null 2>&1; then
            echo "  Status: Running"
        else
            echo "  Status: Stopped"
        fi
    else
        echo -e "${YELLOW}○ No systemd service found${NC}"
    fi
    
    echo
    echo "Available actions:"
    
    if [[ "$has_cron" == "true" && "$has_service" == "false" ]]; then
        echo "1. Add systemd service (keep cron)"
        echo "2. Switch to systemd service only (remove cron)"
        echo "3. Remove cron job"
        echo "4. Update scripts"
        echo "5. Exit"
    elif [[ "$has_cron" == "false" && "$has_service" == "true" ]]; then
        echo "1. Add cron job (keep service)"
        echo "2. Switch to cron job only (remove service)"
        echo "3. Remove systemd service"
        echo "4. Update scripts"
        echo "5. Exit"
    elif [[ "$has_cron" == "true" && "$has_service" == "true" ]]; then
        echo "1. Switch to cron job only (remove service)"
        echo "2. Switch to systemd service only (remove cron)"
        echo "3. Remove both"
        echo "4. Update scripts"
        echo "5. Exit"
    else
        echo "1. Set up cron job"
        echo "2. Set up systemd service"
        echo "3. Set up both"
        echo "4. Update scripts"
        echo "5. Exit"
    fi
    
    echo
    read -p "Choose action [1-5]: " action
    
    case $action in
        1)
            if [[ "$has_cron" == "true" && "$has_service" == "false" ]]; then
                setup_service=true
                setup_cron=false
                echo "Adding systemd service..."
            elif [[ "$has_cron" == "false" && "$has_service" == "true" ]]; then
                setup_cron=true
                setup_service=false
                echo "Adding cron job..."
            elif [[ "$has_cron" == "true" && "$has_service" == "true" ]]; then
                remove_service
                echo "Switched to cron job only."
                return 0
            else
                setup_cron=true
                setup_service=false
                echo "Setting up cron job..."
            fi
            ;;
        2)
            if [[ "$has_cron" == "true" && "$has_service" == "false" ]]; then
                remove_cron
                setup_service=true
                setup_cron=false
                echo "Switching to systemd service..."
            elif [[ "$has_cron" == "false" && "$has_service" == "true" ]]; then
                remove_service
                setup_cron=true
                setup_service=false
                echo "Switching to cron job..."
            elif [[ "$has_cron" == "true" && "$has_service" == "true" ]]; then
                remove_cron
                echo "Switched to systemd service only."
                return 0
            else
                setup_service=true
                setup_cron=false
                echo "Setting up systemd service..."
            fi
            ;;
        3)
            if [[ "$has_cron" == "true" && "$has_service" == "true" ]]; then
                remove_cron
                remove_service
                echo "Removed both deployments."
                return 0
            elif [[ "$has_cron" == "true" ]]; then
                remove_cron
                echo "Removed cron job."
                return 0
            elif [[ "$has_service" == "true" ]]; then
                remove_service
                echo "Removed systemd service."
                return 0
            else
                setup_cron=true
                setup_service=true
                echo "Setting up both options..."
            fi
            ;;
        4)
            echo "Updating scripts..."
            self_update
            return $?
            ;;
        5)
            echo "Exiting."
            return 0
            ;;
        *)
            echo "Invalid choice."
            return 1
            ;;
    esac
    
    # Execute the deployment setup
    run_deployment_setup
}

# Remove cron job
remove_cron() {
    echo "Removing cron job..."
    temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "port-sync.sh" > "$temp_cron" || true
    if crontab "$temp_cron"; then
        echo -e "${GREEN}✓ Cron job removed${NC}"
    else
        echo -e "${RED}✗ Failed to remove cron job${NC}"
    fi
    rm -f "$temp_cron"
}

# Remove systemd service
remove_service() {
    echo "Removing systemd service..."
    if [[ -f "$SCRIPT_DIR/service-manager.sh" ]]; then
        if bash "$SCRIPT_DIR/service-manager.sh" uninstall; then
            echo -e "${GREEN}✓ Systemd service removed${NC}"
        else
            echo -e "${RED}✗ Failed to remove systemd service${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ service-manager.sh not found${NC}"
    fi
}

# Run deployment setup (shared logic)
run_deployment_setup() {
    # Set up cron job if requested
    if [[ "$setup_cron" == "true" ]]; then
        echo
        echo "Setting up cron job..."
        
        # Create temporary cron file
        temp_cron=$(mktemp)
        
        # Get existing crontab (excluding old port-sync entries)
        crontab -l 2>/dev/null | grep -v "port-sync.sh" > "$temp_cron" || true
        
        # Add new cron job
        echo "*/5 * * * * $MAIN_SCRIPT >/dev/null 2>&1" >> "$temp_cron"
        
        # Install new crontab
        if crontab "$temp_cron"; then
            echo "✓ Cron job added successfully"
            echo "The script will now run every 5 minutes automatically."
        else
            echo "✗ Failed to install cron job"
        fi
        
        # Clean up
        rm -f "$temp_cron"
    fi

    # Set up systemd service if requested
    if [[ "$setup_service" == "true" ]]; then
        echo
        echo "Setting up systemd service..."
        
        # Ensure required service files exist; auto-download if missing
        # Ensure main script exists; auto-download if missing
        if [[ ! -f "$MAIN_SCRIPT" ]]; then
            echo "port-sync.sh not found. Attempting to download..."
            if command -v curl >/dev/null 2>&1; then
                if curl -fsSL -o "$MAIN_SCRIPT" "$GITHUB_RAW_URL/port-sync.sh"; then
                    chmod +x "$MAIN_SCRIPT" || true
                    echo "✓ Downloaded port-sync.sh"
                else
                    echo -e "${RED}✗ Failed to download port-sync.sh${NC}"
                fi
            fi
        fi

        if [[ ! -f "$SCRIPT_DIR/service-manager.sh" ]]; then
            echo "service-manager.sh not found. Attempting to download..."
            if command -v curl >/dev/null 2>&1; then
                if curl -fsSL -o "$SCRIPT_DIR/service-manager.sh" "$GITHUB_RAW_URL/service-manager.sh"; then
                    chmod +x "$SCRIPT_DIR/service-manager.sh" || true
                    echo "✓ Downloaded service-manager.sh"
                else
                    echo -e "${YELLOW}⚠ Failed to download service-manager.sh${NC}"
                fi
            fi
        fi
        if [[ ! -f "$SCRIPT_DIR/qbittorrent-wireguard-sync.service" ]]; then
            echo "qbittorrent-wireguard-sync.service not found. Attempting to download..."
            if command -v curl >/dev/null 2>&1; then
                if curl -fsSL -o "$SCRIPT_DIR/qbittorrent-wireguard-sync.service" "$GITHUB_RAW_URL/qbittorrent-wireguard-sync.service"; then
                    echo "✓ Downloaded qbittorrent-wireguard-sync.service"
                else
                    echo -e "${YELLOW}⚠ Failed to download qbittorrent-wireguard-sync.service${NC}"
                fi
            fi
        fi

        if [[ -f "$SCRIPT_DIR/service-manager.sh" ]]; then
            echo -e "${CYAN}Running service installer...${NC}"
            echo "Note: This will require root privileges for systemd operations"
            
            if bash "$SCRIPT_DIR/service-manager.sh" install; then
                echo "✓ Systemd service set up successfully"
                echo "  Use 'bash $SCRIPT_DIR/service-manager.sh status' to check status"
                echo "  Use 'bash $SCRIPT_DIR/service-manager.sh logs' to view logs"
                echo "  Use 'bash $SCRIPT_DIR/service-manager.sh stop' to stop the service"
            else
                echo "✗ Failed to set up systemd service"
                if [[ "$setup_cron" != "true" ]]; then
                    echo "Would you like to fall back to cron job setup instead?"
                    read -p "Set up cron job? (y/N): " fallback_cron
                    if [[ "$fallback_cron" =~ ^[Yy]$ ]]; then
                        setup_cron=true
                        # Run the cron setup section
                        echo
                        echo "Setting up cron job as fallback..."
                        temp_cron=$(mktemp)
                        crontab -l 2>/dev/null | grep -v "port-sync.sh" > "$temp_cron" || true
                        echo "*/5 * * * * $MAIN_SCRIPT >/dev/null 2>&1" >> "$temp_cron"
                        if crontab "$temp_cron"; then
                            echo "✓ Cron job added successfully as fallback"
                        fi
                        rm -f "$temp_cron"
                    fi
                fi
            fi
        else
            echo -e "${RED}Error: service-manager.sh not found${NC}"
            if [[ "$setup_cron" != "true" ]]; then
                echo "Falling back to cron job setup..."
                setup_cron=true
                # Run the cron setup section as fallback
                echo
                echo "Setting up cron job as fallback..."
                temp_cron=$(mktemp)
                crontab -l 2>/dev/null | grep -v "port-sync.sh" > "$temp_cron" || true
                echo "*/5 * * * * $MAIN_SCRIPT >/dev/null 2>&1" >> "$temp_cron"
                if crontab "$temp_cron"; then
                    echo "✓ Cron job added successfully as fallback"
                fi
                rm -f "$temp_cron"
            fi
        fi
    fi
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
# This script helps set up the port sync script and cron job

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
if [[ -d .git ]]; then
    if git fetch origin main >/dev/null 2>&1; then
        if ! git diff --quiet HEAD origin/main; then
            echo -e "${YELLOW}⚠ Updates available!${NC}"
            echo "Run '$0 --update' to get the latest version, or continue with current version."
            read -p "Continue with current version? (Y/n): " continue_install
            if [[ "$continue_install" =~ ^[Nn]$ ]]; then
                echo "Run '$0 --update' to update first."
                exit 0
            fi
        else
            echo -e "${GREEN}✓ Already up to date${NC}"
        fi
    fi
fi

# Check if this is a re-run (existing deployments)
deployment_status=$(check_existing_deployments)
IFS=',' read -r has_existing_cron has_existing_service <<< "$deployment_status"

if [[ "$has_existing_cron" == "true" || "$has_existing_service" == "true" ]]; then
    echo -e "${YELLOW}Existing deployment detected!${NC}"
    echo "Current status:"
    if [[ "$has_existing_cron" == "true" ]]; then
        echo -e "${GREEN}✓ Cron job active${NC}"
    fi
    if [[ "$has_existing_service" == "true" ]]; then
        echo -e "${GREEN}✓ Systemd service installed${NC}"
    fi
    echo
    echo "Options:"
    echo "1. Continue with full setup (may reconfigure)"
    echo "2. Manage existing deployments (recommended)"
    echo "3. Exit"
    read -p "Choose option [1-3]: " existing_choice
    
    case $existing_choice in
        1)
            echo "Continuing with full setup..."
            ;;
        2)
            manage_deployments
            exit $?
            ;;
        3)
            echo "Exiting. Use '$0 --manage' to manage deployments later."
            exit 0
            ;;
        *)
            echo "Invalid choice, continuing with full setup..."
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
    wg show interfaces 2>/dev/null || echo "  None found"
    echo
    read -p "Enter your WireGuard interface name (or press Enter to continue with '$WG_INTERFACE'): " user_interface
    if [[ -n "$user_interface" ]]; then
        WG_INTERFACE="$user_interface"
        echo -e "${BLUE}Will use interface: $WG_INTERFACE${NC}"
        # Update the script with the correct interface
        sed -i.bak "s/WG_INTERFACE=\"wg0\"/WG_INTERFACE=\"$WG_INTERFACE\"/" "$MAIN_SCRIPT"
        echo -e "${GREEN}✓ Updated script with interface: $WG_INTERFACE${NC}"
    fi
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
    
    # Update the script with the correct port if it's not 8080
    if [[ "$QB_PORT" != "8080" ]]; then
        echo -e "${BLUE}Updating script with qBittorrent port: $QB_PORT${NC}"
        sed -i.bak "s/QBITTORRENT_PORT=\"8080\"/QBITTORRENT_PORT=\"$QB_PORT\"/" "$MAIN_SCRIPT"
        echo -e "${GREEN}✓ Updated script with qBittorrent port: $QB_PORT${NC}"
    fi
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
if "$MAIN_SCRIPT" --check; then
    echo -e "${GREEN}✓ Script test completed successfully${NC}"
else
    echo -e "${YELLOW}⚠ Script test had issues - check the output above${NC}"
fi

# Offer to set up cron job or systemd service
echo -e "${BLUE}Automation Setup${NC}"
echo "================"
echo "Choose how you want to run the port sync:"
echo "1. Cron job (every 5 minutes) - Simple and reliable"
echo "2. Systemd service (continuous monitoring every 30 seconds) - More responsive"
echo "3. Both options available - install tools for flexible switching"
echo "4. Manual setup later"
echo

read -p "Choose option [1-4]: " automation_choice

setup_cron=false
setup_service=false

case $automation_choice in
    1)
        echo "Setting up cron job only..."
        setup_cron=true
        ;;
    2)
        echo "Setting up systemd service only..."
        setup_service=true
        ;;
    3)
        echo "Setting up both options for maximum flexibility..."
        setup_cron=true
        setup_service=true
        ;;
    4)
        echo "Skipping automation setup."
        echo
        echo -e "${YELLOW}Manual setup options:${NC}"
        echo "  Cron: crontab -e, then add: */5 * * * * $MAIN_SCRIPT"
        echo "  Service: bash $SCRIPT_DIR/service-manager.sh install"
        echo "  Manage later: bash $0 --manage"
        ;;
    *)
        echo "Invalid choice, skipping automation setup."
        ;;
esac

# Use the shared deployment setup logic
run_deployment_setup

echo
echo "Installation Complete!"
echo "===================="
echo
echo "Usage:"
echo "  $MAIN_SCRIPT                # Normal sync operation"
echo "  $MAIN_SCRIPT --check        # Check current status"
echo "  $MAIN_SCRIPT --force        # Force update qBittorrent"
echo "  $MAIN_SCRIPT --daemon       # Run as daemon service (30s intervals)"
echo
echo "Management Commands:"
echo "  $0 --manage        # Manage deployments (switch between cron/service)"
echo "  $0 --update        # Self-update to latest version"
echo "  $0 --help          # Show help"
echo
if [[ "$setup_service" == "true" ]]; then
    echo "Service Management:"
    echo "  bash $SCRIPT_DIR/service-manager.sh status   # Check service status"
    echo "  bash $SCRIPT_DIR/service-manager.sh logs     # View service logs"
    echo "  bash $SCRIPT_DIR/service-manager.sh stop     # Stop service"
    echo "  bash $SCRIPT_DIR/service-manager.sh start    # Start service"
    echo
fi
if [[ "$setup_cron" == "true" ]]; then
    echo "Cron Job Management:"
    echo "  crontab -l                  # View current cron jobs"
    echo "  crontab -e                  # Edit cron jobs"
    echo
fi
echo "Log files:"
echo "  $SCRIPT_DIR/port-sync.log    # Activity log"
echo
echo "For more information, see README.md"
echo
echo "You can test the script now by running:"
echo "  $MAIN_SCRIPT --check"