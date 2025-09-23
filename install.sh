#!/bin/bash

# Quick installation script for qBittorrent WireGuard Port Sync
# This script helps set up the port sync script and cron job

# Check if we're running with bash, not sh
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash, not sh"
    echo "Please run with: bash $0 or chmod +x $0 && ./$0"
    exit 1
fi

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="${SCRIPT_DIR}/port-sync.sh"

echo -e "${BLUE}qBittorrent WireGuard Port Sync - Installation Script${NC}"
echo "===================================================="
echo

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
        # macOS location
        "$HOME/.config/qBittorrent/qBittorrent.conf"
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
        ;;
    *)
        echo "Invalid choice, skipping automation setup."
        ;;
esac

# Set up cron job if requested
if [[ "$setup_cron" == "true" ]]; then
    echo
    echo "Setting up cron job..."
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "port-sync.sh"; then
        echo "⚠ A cron job for port-sync.sh already exists:"
        crontab -l | grep "port-sync.sh"
        echo
        read -p "Replace existing cron job? (y/N): " replace_cron
        if [[ ! "$replace_cron" =~ ^[Yy]$ ]]; then
            echo "Skipping cron job setup."
            setup_cron=false
        fi
    fi
    
    if [[ "$setup_cron" == "true" ]]; then
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
fi

# Set up systemd service if requested
if [[ "$setup_service" == "true" ]]; then
    echo
    echo "Setting up systemd service..."
    
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