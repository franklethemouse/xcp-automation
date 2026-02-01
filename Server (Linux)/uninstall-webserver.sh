#!/bin/bash
# uninstall-webserver.sh
# Complete removal of XCP-ng Management Web Server (safer defaults)
# Version: 1.2.0

set -Eeuo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}=== XCP-ng Management Web Server Uninstaller ===${NC}\n"
if [ "$EUID" -ne 0 ]; then echo -e "${RED}[ERROR] Must run as root${NC}"; exit 1; fi

DOMAIN=""
PURGE_MYSQL=false
KEEP_MYSQL=false
PURGE_NGINX=false
ALL_CERTS=false
AUTO_YES=false
DB_NAME="XcpManagement"
DB_USER="xcp_app_user"
INSTALL_DIR="/opt/xcp-management"
SERVICE_NAME="xcp-management"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --domain DOMAIN     Domain to clean certs for (e.g., vm.example.com)
  --purge-mysql       Also purge MySQL packages and data (destructive)
  --keep-mysql        Keep MySQL fully (do not drop DB/user)
  --purge-nginx       Also purge Nginx packages and configs
  --all-certs         Remove all /etc/letsencrypt contents (danger)
  -y, --yes           Auto-confirm
  -h, --help          Show help

Defaults:
  - Drops database '${DB_NAME}' and user '${DB_USER}', unless --keep-mysql.
  - Removes only LE material for --domain, unless --all-certs.
  - Handles wildcard: if no cert for DOMAIN, will try BASE_DOMAIN.
  - Removes app files, service unit, nginx site files.
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) DOMAIN="$2"; shift 2;;
    --purge-mysql) PURGE_MYSQL=true; shift;;
    --keep-mysql) KEEP_MYSQL=true; shift;;
    --purge-nginx) PURGE_NGINX=true; shift;;
    --all-certs) ALL_CERTS=true; shift;;
    -y|--yes) AUTO_YES=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

echo -e "${YELLOW}This will remove:${NC}"
echo " - XCP Management service & files"
echo " - Nginx site configuration (not package unless --purge-nginx)"
echo " - SSL certificates for ${DOMAIN:-<domain not specified>} (or ALL if --all-certs)"
echo " - Database '${DB_NAME}' and user '${DB_USER}' (unless --keep-mysql)"
echo
if [ "$AUTO_YES" = false ]; then
  read -p "Continue? (yes/no): " CONFIRM
  [ "$CONFIRM" = "yes" ] || { echo "Cancelled."; exit 0; }
fi

echo -e "\n${CYAN}Stopping services...${NC}"
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop mysql 2>/dev/null || true

echo -e "\n${CYAN}Disabling services...${NC}"
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

echo -e "\n${CYAN}Removing systemd service...${NC}"
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload

echo -e "\n${CYAN}Removing application files...${NC}"
rm -rf "${INSTALL_DIR}"

echo -e "\n${CYAN}Removing nginx site...${NC}"
rm -f /etc/nginx/sites-enabled/xcp-management /etc/nginx/sites-available/xcp-management
nginx -t && systemctl reload nginx 2>/dev/null || true

if [ "$PURGE_NGINX" = true ]; then
  echo -e "\n${CYAN}Purging Nginx...${NC}"
  apt-get purge -y nginx nginx-full 2>/dev/null || true
  rm -rf /etc/nginx /var/www/certbot
fi

echo -e "\n${CYAN}Removing SSL certificates...${NC}"
if [ "$ALL_CERTS" = true ]; then
  rm -rf /etc/letsencrypt
else
  if [ -n "$DOMAIN" ]; then
    BASE_DOMAIN="$(echo "$DOMAIN" | sed 's/^[^.]*\.//')"
    if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
      rm -rf "/etc/letsencrypt/live/${DOMAIN}" \
             "/etc/letsencrypt/archive/${DOMAIN}" \
             "/etc/letsencrypt/renewal/${DOMAIN}.conf" 2>/dev/null || true
    elif [ -d "/etc/letsencrypt/live/${BASE_DOMAIN}" ]; then
      echo "Found wildcard cert; removing ${BASE_DOMAIN}"
      rm -rf "/etc/letsencrypt/live/${BASE_DOMAIN}" \
             "/etc/letsencrypt/archive/${BASE_DOMAIN}" \
             "/etc/letsencrypt/renewal/${BASE_DOMAIN}.conf" 2>/dev/null || true
    else
      echo -e "${YELLOW}No certificate directories found for ${DOMAIN} or ${BASE_DOMAIN}${NC}"
    fi
  else
    echo -e "${YELLOW}No --domain provided; skipping targeted certificate cleanup${NC}"
  fi
fi
rm -rf /root/.secrets 2>/dev/null || true

echo -e "\n${CYAN}Database cleanup...${NC}"
if [ "$KEEP_MYSQL" = true ]; then
  echo -e "${YELLOW}Skipping MySQL cleanup (--keep-mysql)${NC}"
else
  if command -v mysql &>/dev/null; then
    mysql -e "DROP DATABASE IF EXISTS ${DB_NAME};" 2>/dev/null || true
    mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null || true
  fi
  if [ "$PURGE_MYSQL" = true ]; then
    echo -e "${CYAN}Purging MySQL packages and data...${NC}"
    apt-get purge -y mysql-server mysql-client mysql-common 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    rm -rf /var/lib/mysql /var/lib/mysql-keyring /etc/mysql
    rm -f /root/.my.cnf
  fi
fi

echo -e "\n${CYAN}Removing service user...${NC}"
userdel xcp-web 2>/dev/null || true

echo -e "\n${CYAN}Removing state file...${NC}"
rm -f /tmp/xcp-webserver-install-state

echo -e "\n${CYAN}Cleaning apt cache...${NC}"
apt-get clean

echo -e "\n${GREEN}=== Uninstallation Complete ===${NC}\n"
echo "The server is now clean for redeployment."
echo -e "${YELLOW}Note: .NET 8 SDK/runtime not removed (may be used by other apps).${NC}"
echo "To remove .NET 8: sudo apt-get purge dotnet-sdk-8.0 aspnetcore-runtime-8.0"
exit 0
