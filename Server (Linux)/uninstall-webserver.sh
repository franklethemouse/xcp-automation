#!/bin/bash
# uninstall-webserver.sh
# Complete removal of XCP-ng Management Web Server (safer defaults)
# Version: 1.5.0

set -Eeuo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}=== XCP-ng Management Web Server Uninstaller v1.5.0 ===${NC}\n"

DOMAIN=""
PURGE_MYSQL=false
KEEP_MYSQL=false
PURGE_NGINX=false
ALL_CERTS=false
AUTO_YES=false
ALL_MODE=false
DB_NAME="XcpManagement"
DB_USER="xcp_app_user"
WEB_USER="xcp-web"
INSTALL_DIR="/opt/xcp-management"
SERVICE_NAME="xcp-management"

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Must run as root${NC}"
    return 1
  fi
  return 0
}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --domain DOMAIN     Domain to clean certs for (e.g., vm.example.com)
  --purge-mysql       Also purge MySQL packages and data (destructive)
  --keep-mysql        Keep MySQL fully (do not drop DB/user)
  --purge-nginx       Also purge Nginx packages and configs
  --all-certs         Remove all /etc/letsencrypt contents (danger)
  --all               Complete cleanup: purge MySQL, nginx, all certs, remove user home dir
  -y, --yes           Auto-confirm
  -h, --help          Show help

Defaults:
  - Drops database '${DB_NAME}' and user '${DB_USER}', unless --keep-mysql.
  - Removes only LE material for --domain, unless --all-certs.
  - Handles wildcard: if no cert for DOMAIN, will try BASE_DOMAIN.
  - Removes app files, service unit, nginx site files, credentials.
  - Removes service user '${WEB_USER}' (but keeps home directory unless --all).

Note: --all implies --purge-mysql, --purge-nginx, --all-certs and removes user home dir.
EOF
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --domain) DOMAIN="$2"; shift 2;;
      --purge-mysql) PURGE_MYSQL=true; shift;;
      --keep-mysql) KEEP_MYSQL=true; shift;;
      --purge-nginx) PURGE_NGINX=true; shift;;
      --all-certs) ALL_CERTS=true; shift;;
      --all) ALL_MODE=true; PURGE_MYSQL=true; PURGE_NGINX=true; ALL_CERTS=true; shift;;
      -y|--yes) AUTO_YES=true; shift;;
      -h|--help) usage; return 2;;  # Special code: help was shown
      *) 
        echo -e "${RED}[ERROR]${NC} Unknown option: $1"
        usage
        return 1
        ;;
    esac
  done
  return 0
}

confirm_uninstall() {
  echo -e "${YELLOW}This will remove:${NC}"
  echo " - XCP Management service & files"
  echo " - Application credentials file"
  echo " - Nginx site configuration (not package unless --purge-nginx)"
  echo " - SSL certificates for ${DOMAIN:-<domain not specified>} (or ALL if --all-certs)"
  echo " - Database '${DB_NAME}' and user '${DB_USER}' (unless --keep-mysql)"
  echo " - Service user '${WEB_USER}' (home dir removed only with --all)"
  
  if [ "$ALL_MODE" = true ]; then
    echo -e "\n${RED}WARNING: --all mode enabled${NC}"
    echo " - MySQL packages and data will be PURGED"
    echo " - Nginx packages and configs will be PURGED"
    echo " - ALL SSL certificates will be removed"
    echo " - User home directory will be deleted"
  fi
  echo
  
  if [ "$AUTO_YES" = false ]; then
    read -p "Continue? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
      echo "Cancelled by user."
      return 1
    fi
  fi
  return 0
}

stop_services() {
  echo -e "\n${CYAN}Stopping services...${NC}"
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  sleep 1  # Allow service to fully stop
  systemctl stop nginx 2>/dev/null || true
  sleep 1
  systemctl stop mysql 2>/dev/null || true
}

disable_services() {
  echo -e "\n${CYAN}Disabling services...${NC}"
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
}

remove_systemd_service() {
  echo -e "\n${CYAN}Removing systemd service...${NC}"
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
}

remove_application_files() {
  echo -e "\n${CYAN}Removing application files...${NC}"
  rm -rf "${INSTALL_DIR}"
}

remove_nginx_site() {
  echo -e "\n${CYAN}Removing nginx site...${NC}"
  rm -f /etc/nginx/sites-enabled/xcp-management /etc/nginx/sites-available/xcp-management
  nginx -t && systemctl reload nginx 2>/dev/null || true
}

purge_nginx() {
  if [ "$PURGE_NGINX" = true ]; then
    echo -e "\n${CYAN}Purging Nginx...${NC}"
    apt-get purge -y nginx nginx-full nginx-common libnginx-mod-* 2>/dev/null || true
    rm -rf /var/www/certbot
  fi
}

remove_ssl_certificates() {
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
}

cleanup_database() {
  echo -e "\n${CYAN}Database cleanup...${NC}"
  
  if [ "$KEEP_MYSQL" = true ]; then
    echo -e "${YELLOW}Skipping MySQL cleanup (--keep-mysql)${NC}"
    return 0
  fi
  
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
}

remove_service_user() {
  echo -e "\n${CYAN}Removing service user...${NC}"
  if [ "$ALL_MODE" = true ]; then
    userdel -r "${WEB_USER}" 2>/dev/null || true
    echo "Removed user and home directory"
  else
    userdel "${WEB_USER}" 2>/dev/null || true
    echo "Removed user (home directory preserved)"
  fi
}

cleanup_state_files() {
  echo -e "\n${CYAN}Removing state file...${NC}"
  rm -f /tmp/xcp-webserver-install-state
}

cleanup_apt_cache() {
  echo -e "\n${CYAN}Cleaning apt cache...${NC}"
  apt-get clean
}

verify_removal() {
  echo -e "\n${CYAN}Verifying removal...${NC}"
  local issues=0
  
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo -e "${YELLOW}! Service still running${NC}"
    issues=$((issues + 1))
  fi
  
  if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}! Installation directory still exists${NC}"
    issues=$((issues + 1))
  fi
  
  if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
    echo -e "${YELLOW}! Systemd unit file still exists${NC}"
    issues=$((issues + 1))
  fi
  
  if [ -f "/etc/nginx/sites-enabled/xcp-management" ] || [ -f "/etc/nginx/sites-available/xcp-management" ]; then
    echo -e "${YELLOW}! Nginx site configuration still exists${NC}"
    issues=$((issues + 1))
  fi
  
  if [ $issues -eq 0 ]; then
    echo -e "${GREEN}✓ Removal verified${NC}"
  else
    echo -e "${YELLOW}Found $issues potential issues - please review${NC}"
  fi
}

display_completion() {
  echo -e "\n${GREEN}=== Uninstallation Complete ===${NC}\n"
  echo "The server is now clean for redeployment."
  echo -e "${YELLOW}Note: .NET 8 SDK/runtime not removed (may be used by other apps).${NC}"
  echo "To remove .NET 8: sudo apt-get purge dotnet-sdk-8.0 aspnetcore-runtime-8.0"
}

main() {
  check_root || return 1
  
  parse_arguments "$@"
  local parse_result=$?
  if [ $parse_result -eq 2 ]; then
    return 0  # Help was shown, exit cleanly
  elif [ $parse_result -ne 0 ]; then
    return 1  # Parse error
  fi
  
  confirm_uninstall || return 0  # User cancelled
  
  stop_services
  disable_services
  remove_systemd_service
  remove_application_files
  remove_nginx_site
  purge_nginx
  remove_ssl_certificates
  cleanup_database
  remove_service_user
  cleanup_state_files
  cleanup_apt_cache
  verify_removal
  display_completion
  
  return 0
}

main "$@"
SCRIPT_RESULT=$?
if [ $SCRIPT_RESULT -ne 0 ]; then
  echo -e "\n${RED}Uninstallation encountered errors (code $SCRIPT_RESULT)${NC}"
fi

# Exit with the result from main
exit $SCRIPT_RESULT