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

echo

# Test qBittorrent connection
echo "Checking qBittorrent Web UI..."
QB_URL="http://localhost:8080"

if curl -s -f "${QB_URL}/api/v2/app/version" >/dev/null 2>&1; then
    qb_version=$(curl -s "${QB_URL}/api/v2/app/version" 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✓ qBittorrent Web UI is accessible (version: $qb_version)${NC}"
else
    echo -e "${RED}✗ qBittorrent Web UI is not accessible at $QB_URL${NC}"
    echo
    echo "Please ensure:"
    echo "1. qBittorrent is running"
    echo "2. Web UI is enabled in Tools → Options → Web UI"
    echo "3. Web UI port is 8080 (or update the script)"
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

echo

# Offer to set up cron job
echo "Cron Job Setup"
echo "=============="
echo "The script should run every 5 minutes to monitor port changes."
echo

read -p "Would you like to add a cron job now? (y/N): " setup_cron

if [[ "$setup_cron" =~ ^[Yy]$ ]]; then
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -q "port-sync.sh"; then
        echo "⚠ A cron job for port-sync.sh already exists:"
        crontab -l | grep "port-sync.sh"
        echo
        read -p "Replace existing cron job? (y/N): " replace_cron
        if [[ ! "$replace_cron" =~ ^[Yy]$ ]]; then
            echo "Skipping cron job setup."
            setup_cron=""
        fi
    fi
    
    if [[ "$setup_cron" =~ ^[Yy]$ ]]; then
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
else
    echo "Skipped cron job setup."
    echo
    echo "To add manually later, run:"
    echo "  crontab -e"
    echo "And add this line:"
    echo "  */5 * * * * $MAIN_SCRIPT >/dev/null 2>&1"
fi

echo
echo "Installation Complete!"
echo "===================="
echo
echo "Usage:"
echo "  $MAIN_SCRIPT                # Normal sync operation"
echo "  $MAIN_SCRIPT --check        # Check current status"
echo "  $MAIN_SCRIPT --force        # Force update qBittorrent"
echo
echo "Log files:"
echo "  $SCRIPT_DIR/port-sync.log    # Activity log"
echo
echo "For more information, see README.md"
echo
echo "You can test the script now by running:"
echo "  $MAIN_SCRIPT --check"