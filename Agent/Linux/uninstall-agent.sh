#!/bin/bash
# uninstall-agent.sh
# XCP-ng VM Agent Uninstaller
# Version: 1.0.3

set -e

VERSION="1.0.3"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== XCP-ng VM Agent Uninstaller v${VERSION} ===${NC}\n"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] This script must be run as root${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Parse arguments
KEEP_LOGS=false
FORCE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-logs)
            KEEP_LOGS=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Confirm uninstallation
if [ "$FORCE" = false ]; then
    echo -e "${YELLOW}This will remove the XCP-ng VM Agent from this system.${NC}"
    read -p "Continue with uninstallation? (Y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Uninstallation cancelled."
        exit 0
    fi
fi

# Stop service
echo -e "\n${CYAN}Stopping service...${NC}"
if systemctl is-active --quiet xcp-vm-agent; then
    systemctl stop xcp-vm-agent
    echo -e "${GREEN}[OK]${NC} Service stopped"
else
    echo "  Service not running"
fi

# Disable service
echo -e "\n${CYAN}Disabling service...${NC}"
if systemctl is-enabled --quiet xcp-vm-agent 2>/dev/null; then
    systemctl disable xcp-vm-agent
    echo -e "${GREEN}[OK]${NC} Service disabled"
else
    echo "  Service not enabled"
fi

# Remove systemd service file
echo -e "\n${CYAN}Removing systemd service...${NC}"
if [ -f /etc/systemd/system/xcp-vm-agent.service ]; then
    rm /etc/systemd/system/xcp-vm-agent.service
    systemctl daemon-reload
    echo -e "${GREEN}[OK]${NC} Service file removed"
else
    echo "  Service file not found"
fi

# Backup logs if requested
if [ "$KEEP_LOGS" = true ] && [ -d /var/log/xcp-vm-agent ]; then
    BACKUP_DIR="/tmp/xcp-vm-agent-logs-$(date +%Y%m%d-%H%M%S)"
    echo -e "\n${CYAN}Backing up logs...${NC}"
    cp -r /var/log/xcp-vm-agent "$BACKUP_DIR"
    echo -e "${GREEN}[OK]${NC} Logs saved to: $BACKUP_DIR"
fi

# Remove directories
echo -e "\n${CYAN}Removing installation files...${NC}"

if [ -d /opt/xcp-vm-agent ]; then
    rm -rf /opt/xcp-vm-agent
    echo "  Removed: /opt/xcp-vm-agent"
fi

if [ -d /etc/xcp-vm-agent ]; then
    rm -rf /etc/xcp-vm-agent
    echo "  Removed: /etc/xcp-vm-agent"
fi

if [ -d /var/log/xcp-vm-agent ]; then
    rm -rf /var/log/xcp-vm-agent
    echo "  Removed: /var/log/xcp-vm-agent"
fi

echo -e "${GREEN}[OK]${NC} Installation files removed"

# Display summary
echo -e "\n${GREEN}=== Uninstallation Complete ===${NC}"

if [ "$KEEP_LOGS" = true ] && [ -d "$BACKUP_DIR" ]; then
    echo -e "\nLogs saved to: ${CYAN}$BACKUP_DIR${NC}"
fi

echo -e "\nThe XCP-ng VM Agent has been removed from this system."

exit 0