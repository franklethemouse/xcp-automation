#!/bin/bash
# uninstall-webserver.sh
# Complete removal of XCP-ng Management Web Server
# Version: 1.0.0

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== XCP-ng Management Web Server Uninstaller ===${NC}\n"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Must run as root${NC}"
    exit 1
fi

# Confirm
echo -e "${YELLOW}This will remove:${NC}"
echo "  - XCP Management service"
echo "  - MySQL database and server"
echo "  - Nginx configuration"
echo "  - SSL certificates"
echo "  - All configuration files"
echo "  - /opt/xcp-management directory"
echo ""
read -p "Continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

echo -e "\n${CYAN}Stopping services...${NC}"
systemctl stop xcp-management 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop mysql 2>/dev/null || true

echo -e "\n${CYAN}Disabling services...${NC}"
systemctl disable xcp-management 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true
systemctl disable mysql 2>/dev/null || true

echo -e "\n${CYAN}Removing systemd service...${NC}"
rm -f /etc/systemd/system/xcp-management.service
systemctl daemon-reload

echo -e "\n${CYAN}Removing MySQL...${NC}"
apt-get purge -y mysql-server mysql-client mysql-common 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
rm -rf /var/lib/mysql
rm -rf /var/lib/mysql-keyring
rm -rf /etc/mysql
rm -f /root/.my.cnf

echo -e "\n${CYAN}Removing Nginx...${NC}"
apt-get purge -y nginx 2>/dev/null || true
rm -rf /etc/nginx
rm -rf /var/www/xcp-management
rm -rf /var/www/certbot

echo -e "\n${CYAN}Removing SSL certificates...${NC}"
rm -rf /etc/letsencrypt
rm -rf /root/.secrets

echo -e "\n${CYAN}Removing application files...${NC}"
rm -rf /opt/xcp-management

echo -e "\n${CYAN}Removing user...${NC}"
userdel xcp-web 2>/dev/null || true

echo -e "\n${CYAN}Removing state file...${NC}"
rm -f /tmp/xcp-webserver-install-state

echo -e "\n${CYAN}Cleaning apt cache...${NC}"
apt-get clean

echo -e "\n${GREEN}=== Uninstallation Complete ===${NC}"
echo ""
echo "The server is now clean. You can run the installer again."
echo ""
echo -e "${YELLOW}Note: .NET 8 SDK was not removed (may be used by other apps)${NC}"
echo "To remove .NET 8: sudo apt-get purge dotnet-sdk-8.0 aspnetcore-runtime-8.0"

exit 0