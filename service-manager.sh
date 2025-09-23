#!/bin/bash

# qBittorrent WireGuard Port Sync - Service Installer
# Installs and configures the systemd service for continuous monitoring

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
SERVICE_FILE="qbittorrent-wireguard-sync.service"
SERVICE_PATH="/etc/systemd/system/$SERVICE_FILE"

echo -e "${BLUE}qBittorrent WireGuard Port Sync - Service Installer${NC}"
echo "=================================================="
echo

# Argument parsing for non-interactive usage
ACTION=""
NONINTERACTIVE=0
START_AFTER=0
WG_ARG="${WG_INTERFACE:-}"
QB_ARG="${QB_PORT:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        install|--install)
            ACTION="install"; shift ;;
        uninstall|--uninstall)
            ACTION="uninstall"; shift ;;
        status|--status)
            ACTION="status"; shift ;;
        logs|--logs)
            ACTION="logs"; shift ;;
        -y|--yes|--non-interactive)
            NONINTERACTIVE=1; shift ;;
        --start)
            START_AFTER=1; shift ;;
        --no-start)
            START_AFTER=0; shift ;;
        --wg-interface|--wg|-w)
            WG_ARG="$2"; shift 2 ;;
        --qb-port|--port|-p)
            QB_ARG="$2"; shift 2 ;;
        *)
            break ;;
    esac
done

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Check if service file exists
if [[ ! -f "$SCRIPT_DIR/$SERVICE_FILE" ]]; then
    echo -e "${RED}Error: Service file not found: $SCRIPT_DIR/$SERVICE_FILE${NC}"
    exit 1
fi

# Check if main script exists
if [[ ! -f "$SCRIPT_DIR/port-sync.sh" ]]; then
    echo -e "${RED}Error: Main script not found: $SCRIPT_DIR/port-sync.sh${NC}"
    exit 1
fi

do_install() {
    echo -e "${CYAN}Installing systemd service...${NC}"

    # Copy and customize service file
    cp "$SCRIPT_DIR/$SERVICE_FILE" "$SERVICE_PATH"

    # Replace placeholder paths with actual paths
    sed -i "s|%h/qbittorrent-wireguard-pmp|$SCRIPT_DIR|g" "$SERVICE_PATH"

    # Detect current configuration
    WG_DET="wg0"
    QB_DET="8080"
    if grep -q 'WG_INTERFACE=' "$SCRIPT_DIR/port-sync.sh"; then
        WG_DET=$(grep 'WG_INTERFACE=' "$SCRIPT_DIR/port-sync.sh" | head -1 | cut -d'"' -f2)
    fi
    if grep -q 'QBITTORRENT_PORT=' "$SCRIPT_DIR/port-sync.sh"; then
        QB_DET=$(grep 'QBITTORRENT_PORT=' "$SCRIPT_DIR/port-sync.sh" | head -1 | cut -d'"' -f2)
    fi

    # Apply CLI/env overrides
    WG_VAL="${WG_ARG:-$WG_DET}"
    QB_VAL="${QB_ARG:-$QB_DET}"

    if [[ $NONINTERACTIVE -eq 0 ]]; then
        echo "Detected configuration:"
        echo "  WireGuard interface: $WG_VAL"
        echo "  qBittorrent port: $QB_VAL"
        echo
        read -p "WireGuard interface [$WG_VAL]: " user_wg
        if [[ -n "$user_wg" ]]; then WG_VAL="$user_wg"; fi
        read -p "qBittorrent port [$QB_VAL]: " user_port
        if [[ -n "$user_port" ]]; then QB_VAL="$user_port"; fi
    fi

    # Update service file with configuration
    sed -i "s/Environment=WG_INTERFACE=wg0/Environment=WG_INTERFACE=$WG_VAL/" "$SERVICE_PATH"
    sed -i "s/Environment=QB_PORT=8080/Environment=QB_PORT=$QB_VAL/" "$SERVICE_PATH"

    # If a wg-quick unit for this interface exists, add ordering/wants
    if systemctl list-unit-files | grep -q "wg-quick@${WG_VAL}\.service"; then
        sed -i "/^After=/ s/$/ wg-quick@${WG_VAL}.service/" "$SERVICE_PATH"
        sed -i "/^Wants=/ s/$/ wg-quick@${WG_VAL}.service/" "$SERVICE_PATH"
    fi

    # Make script executable
    chmod +x "$SCRIPT_DIR/port-sync.sh"

    # Reload systemd and optionally enable service
    systemctl daemon-reload
    if [[ $NONINTERACTIVE -eq 1 ]]; then
        systemctl enable "$SERVICE_FILE"
        echo -e "${GREEN}✓ Service installed and enabled${NC}"
    else
        read -p "Enable service at boot? (Y/n): " enable_ans
        if [[ -z "$enable_ans" || "$enable_ans" =~ ^[Yy]$ ]]; then
            systemctl enable "$SERVICE_FILE"
            echo -e "${GREEN}✓ Service installed and enabled${NC}"
        else
            echo -e "${YELLOW}Service installed but not enabled at boot${NC}"
        fi
    fi
    echo

    if [[ $NONINTERACTIVE -eq 1 ]]; then
        if [[ $START_AFTER -eq 1 ]]; then
            systemctl start "$SERVICE_FILE"
            echo -e "${GREEN}✓ Service started${NC}"
        fi
        exit 0
    fi

    read -p "Start the service now? (Y/n): " start_service
    if [[ -z "$start_service" || "$start_service" =~ ^[Yy]$ ]]; then
        systemctl start "$SERVICE_FILE"
        echo -e "${GREEN}✓ Service started${NC}"
        sleep 2
        echo
        echo "Service status:"
        systemctl status "$SERVICE_FILE" --no-pager -l
    else
        echo "Service installed but not started."
        echo "To start manually: sudo systemctl start $SERVICE_FILE"
    fi

    echo
    echo -e "${YELLOW}Useful commands:${NC}"
    echo "  sudo systemctl status $SERVICE_FILE     # Check status"
    echo "  sudo systemctl stop $SERVICE_FILE       # Stop service"
    echo "  sudo systemctl restart $SERVICE_FILE    # Restart service"
    echo "  sudo journalctl -u $SERVICE_FILE -f     # Follow logs"
}

if [[ -n "$ACTION" ]]; then
    case "$ACTION" in
        install) do_install ;;
        uninstall)
            echo -e "${CYAN}Uninstalling systemd service...${NC}"
            if [[ -f "$SERVICE_PATH" ]]; then
                systemctl stop "$SERVICE_FILE" 2>/dev/null || true
                systemctl disable "$SERVICE_FILE" 2>/dev/null || true
                rm -f "$SERVICE_PATH"
                systemctl daemon-reload
                systemctl reset-failed 2>/dev/null || true
                echo -e "${GREEN}✓ Service uninstalled${NC}"
            else
                echo -e "${YELLOW}Service is not installed${NC}"
            fi
            ;;
        status)
            echo -e "${CYAN}Service status:${NC}"
            if [[ -f "$SERVICE_PATH" ]]; then
                systemctl status "$SERVICE_FILE" --no-pager -l
            else
                echo -e "${YELLOW}Service is not installed${NC}"
            fi
            ;;
        logs)
            echo -e "${CYAN}Service logs (last 50 lines):${NC}"
            if [[ -f "$SERVICE_PATH" ]]; then
                journalctl -u "$SERVICE_FILE" -n 50 --no-pager
                echo
                echo "To follow logs in real-time: sudo journalctl -u $SERVICE_FILE -f"
            else
                echo -e "${YELLOW}Service is not installed${NC}"
            fi
            ;;
    esac
    exit 0
fi

echo -e "${YELLOW}Service Installation Options:${NC}"
echo "1. Install systemd service (continuous monitoring)"
echo "2. Uninstall systemd service"
echo "3. Show service status"
echo "4. View service logs"
echo "5. Exit"
echo

read -p "Choose an option [1-5]: " choice

case $choice in
    1)
        do_install
        ;;
        
    2)
        echo -e "${CYAN}Uninstalling systemd service...${NC}"
        
        if [[ -f "$SERVICE_PATH" ]]; then
            # Stop and disable service
            systemctl stop "$SERVICE_FILE" 2>/dev/null || true
            systemctl disable "$SERVICE_FILE" 2>/dev/null || true
            
            # Remove service file
            rm -f "$SERVICE_PATH"
            
            # Reload systemd
            systemctl daemon-reload
            systemctl reset-failed 2>/dev/null || true
            
            echo -e "${GREEN}✓ Service uninstalled${NC}"
        else
            echo -e "${YELLOW}Service is not installed${NC}"
        fi
        ;;
        
    3)
        echo -e "${CYAN}Service status:${NC}"
        if [[ -f "$SERVICE_PATH" ]]; then
            systemctl status "$SERVICE_FILE" --no-pager -l
        else
            echo -e "${YELLOW}Service is not installed${NC}"
        fi
        ;;
        
    4)
        echo -e "${CYAN}Service logs (last 50 lines):${NC}"
        if [[ -f "$SERVICE_PATH" ]]; then
            journalctl -u "$SERVICE_FILE" -n 50 --no-pager
            echo
            echo "To follow logs in real-time: sudo journalctl -u $SERVICE_FILE -f"
        else
            echo -e "${YELLOW}Service is not installed${NC}"
        fi
        ;;
        
    5)
        echo "Exiting..."
        exit 0
        ;;
        
    *)
        echo -e "${RED}Invalid option${NC}"
        exit 1
        ;;
esac