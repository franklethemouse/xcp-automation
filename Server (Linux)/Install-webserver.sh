#!/bin/bash
# -----------------------------------------------------------------------------
# install-webserver.sh
# XCP-ng VM Management Web Server Installer (Debian/Ubuntu only)
# Version: 1.9.0  (Fixed MySQL keyring permissions - encryption.cnf now readable by MySQL)
#
# Key behaviors:
#  - GitHub-only deployment path (no manual publish instructions in summary)
#  - Auto-deploys from GitHub at the end when -y is used
#  - Verifies AFTER deployment completes
#  - Creates app user early; configures MySQL keyring & encryption BEFORE schema
#  - Systemd unit is JIT-safe for .NET (no MemoryDenyWriteExecute)
#
# Version History:
#  1.9.0 - Fixed MySQL keyring: Added proper permissions for encryption.cnf
#  1.8.9 - Expanded formatting & comments; functionally same as v1.8.8
# -----------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="1.9.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== XCP-ng VM Management Web Server Installer v${VERSION} ===${NC}\n"

# Require root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Must run as root${NC}"
  echo "Please run: sudo $0 $*"
  exit 1
fi

# -----------------------------------------------------------------------------
# Globals & defaults
# -----------------------------------------------------------------------------
STATE_FILE="/tmp/xcp-webserver-install-state"

# User-supplied
DOMAIN=""
EMAIL=""

# Paths & service
INSTALL_DIR="/opt/xcp-management"
SERVICE_NAME="xcp-management"
WEB_USER="xcp-web"

# Database
DB_NAME="XcpManagement"
DB_USER="xcp_app_user"
MYSQL_INSTALLED=false
CREDENTIALS_FILE="$INSTALL_DIR/CREDENTIALS.txt"

# Source control (GitHub only)
GITHUB_REPO="franklethemouse/xcp-automation"
GITHUB_BRANCH="main"

# Flags
AUTO_YES=false
SKIP_CERT=false
CERT_ONLY=false
RESUME=false
UPDATE_ONLY=false
TAKEOVER_NGINX=false

# TLS issuance
DNS_PROVIDER="http"      # http|cloudflare|manual
WILDCARD=false
CF_API_TOKEN=""
CF_PROPAGATION_SECONDS=60

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --domain DOMAIN             Domain name
  --email EMAIL               Email for Let's Encrypt
  --github-repo REPO          GitHub repo (default: ${GITHUB_REPO})
  --branch BRANCH             Branch (default: ${GITHUB_BRANCH})
  --takeover-nginx            Remove default nginx site and manage nginx
  --dns-provider PROVIDER     http|cloudflare|manual
  --wildcard                  Use wildcard cert (*.base + apex) via DNS-01
  --cf-token TOKEN            Cloudflare API token
  --cf-propagation-seconds N  DNS propagation wait seconds (default 60)
  -y, --yes                   Non-interactive
  --skip-cert                 Skip cert setup
  --cert-only                 Only run cert setup
  --resume                    Resume
  --update                    Update from GitHub only
  -h, --help                  Help
EOF
}

save_state() {
  echo "$1" > "$STATE_FILE"
}

is_step_complete() {
  local step="$1"
  if [ -f "$STATE_FILE" ]; then
    local current_step
    current_step="$(cat "$STATE_FILE")"

    # !!! IMPORTANT: If you change step names/order, update this list
    local steps=(
      dependencies
      dotnet
      nginx_base
      nginx_http
      mysql_install
      app_user
      mysql_keyring
      mysql_config
      db_schema
      certbot
      letsencrypt
      cert_renewal
      nginx_site
      app_structure
      systemd
      deploy_script
      update_script
      config
      complete
    )

    local current_index=-1
    local check_index=-1
    for i in "${!steps[@]}"; do
      [ "${steps[$i]}" = "$current_step" ] && current_index=$i
      [ "${steps[$i]}" = "$step" ] && check_index=$i
    done
    [ $current_index -ge $check_index ] && return 0 || true
  fi
  return 1
}

prompt_user() {
  local message="$1"
  if [ "$AUTO_YES" = true ]; then
    echo -e "${CYAN}${message}${NC} (auto-yes enabled)"
    return 0
  fi
  read -p "$message (Y/N) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]]
}

prompt_config() {
  if [ -z "${DOMAIN}" ]; then
    echo -e "${CYAN}Domain Configuration:${NC}"
    read -p "Enter domain name (e.g., vm.example.com): " DOMAIN
  fi
  if [ -z "${EMAIL}" ]; then
    read -p "Enter email for Let's Encrypt: " EMAIL
  fi
  echo -e "\n${GREEN}Configuration:${NC}"
  echo " Domain: $DOMAIN"
  echo " Email:  $EMAIL"
  echo " Repo:   $GITHUB_REPO"
  echo " Branch: $GITHUB_BRANCH"
  echo " DNS:    provider=$DNS_PROVIDER wildcard=$WILDCARD"
  echo
  if [ "$AUTO_YES" = false ]; then
    if ! prompt_user "Continue with this configuration?"; then
      echo "Installation cancelled."
      exit 0
    fi
  fi
}

# OS detection
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
  OS_VERSION="$VERSION_ID"
  PRETTY_NAME="${PRETTY_NAME:-$NAME $VERSION_ID}"
  case "$OS_ID" in
    ubuntu|debian)
      echo -e "${GREEN}[OK]${NC} Detected: $PRETTY_NAME" ;;
    *)
      echo -e "${RED}[ERROR]${NC} Unsupported OS: $PRETTY_NAME" ; exit 1 ;;
  esac
else
  echo -e "${RED}[ERROR]${NC} Cannot detect OS" ; exit 1
fi

compute_domains() {
  BASE_DOMAIN="$(echo "$DOMAIN" | sed 's/^[^.]*\.//')"
  if [ "$WILDCARD" = true ]; then
    CERT_NAME="$BASE_DOMAIN"
  else
    CERT_NAME="$DOMAIN"
  fi
}

# -----------------------------------------------------------------------------
# Steps
# -----------------------------------------------------------------------------
install_dependencies() {
  if is_step_complete "dependencies"; then
    echo -e "${YELLOW}[SKIP]${NC} System dependencies already installed"
    return 0
  fi

  echo -e "\n${CYAN}Checking system dependencies...${NC}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget git openssl unzip ca-certificates lsb-release
  echo -e "${GREEN}[OK]${NC} Dependencies installed"
  save_state "dependencies"
}

install_dotnet() {
  if is_step_complete "dotnet"; then
    echo -e "${YELLOW}[SKIP]${NC} .NET already installed"
    return 0
  fi

  if command -v dotnet &>/dev/null; then
    DOTNET_VERSION="$(dotnet --version || true)"
    if [[ "$DOTNET_VERSION" == 8.* ]]; then
      echo -e "${GREEN}[OK]${NC} .NET 8 present: $DOTNET_VERSION"
      save_state "dotnet" ; return 0
    fi
  fi

  echo -e "\n${CYAN}Installing .NET 8...${NC}"
  wget -q \
    "https://packages.microsoft.com/config/$OS_ID/$OS_VERSION/packages-microsoft-prod.deb" \
    -O /tmp/packages-microsoft-prod.deb \
    || { echo -e "${RED}[ERROR]${NC} Unable to fetch Microsoft repo for $OS_ID/$OS_VERSION"; exit 1; }
  dpkg -i /tmp/packages-microsoft-prod.deb
  rm -f /tmp/packages-microsoft-prod.deb
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y dotnet-sdk-8.0 aspnetcore-runtime-8.0
  command -v dotnet &>/dev/null || { echo -e "${RED}[ERROR]${NC} .NET installation failed"; exit 1; }
  echo -e "${GREEN}[OK]${NC} .NET installed: $(dotnet --version)"
  save_state "dotnet"
}

install_nginx_base() {
  if is_step_complete "nginx_base"; then
    echo -e "${YELLOW}[SKIP]${NC} Nginx base already installed"
    return 0
  fi
  echo -e "\n${CYAN}Installing Nginx...${NC}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx-full
  mkdir -p /etc/nginx/{sites-available,sites-enabled,modules-enabled,conf.d}
  mkdir -p /var/www/html /var/www/certbot
  if [ "$TAKEOVER_NGINX" = true ]; then
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default || true
  fi
  echo -e "${GREEN}[OK]${NC} Nginx installed"
  systemctl enable nginx || true
  systemctl start nginx || true
  save_state "nginx_base"
}

create_nginx_http() {
  if is_step_complete "nginx_http"; then
    echo -e "${YELLOW}[SKIP]${NC} Nginx HTTP (ACME) already configured"
    return 0
  fi

  echo -e "\n${CYAN}Creating nginx HTTP site for ACME...${NC}"
  cat > /etc/nginx/sites-available/xcp-management <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};
  location /.well-known/acme-challenge/ {
    root /var/www/certbot;
  }
  location / {
    return 200 "temporary ACME endpoint";
    add_header Content-Type text/plain;
  }
}
EOF
  ln -sf /etc/nginx/sites-available/xcp-management /etc/nginx/sites-enabled/xcp-management
  nginx -t && systemctl reload nginx
  echo -e "${GREEN}[OK]${NC} HTTP site ready for certificate issuance"
  save_state "nginx_http"
}

install_mysql_server() {
  if is_step_complete "mysql_install"; then
    echo -e "${YELLOW}[SKIP]${NC} MySQL already installed"
    MYSQL_INSTALLED=true
    return 0
  fi

  if systemctl is-active --quiet mysql; then
    echo -e "${GREEN}[OK]${NC} MySQL already running"
    MYSQL_INSTALLED=true
    save_state "mysql_install"
    return 0
  fi

  echo -e "\n${CYAN}Installing MySQL Server...${NC}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server >/dev/null
  systemctl enable mysql || true
  systemctl start mysql || true
  sleep 4
  if systemctl is-active --quiet mysql; then
    echo -e "${GREEN}[OK]${NC} MySQL installed"
    MYSQL_INSTALLED=true
    save_state "mysql_install"
  else
    echo -e "${RED}[ERROR]${NC} MySQL failed to start"
    exit 1
  fi
}

create_app_user() {
  if is_step_complete "app_user"; then
    echo -e "${YELLOW}[SKIP]${NC} App user exists"
    return 0
  fi

  echo -e "\n${CYAN}Creating app user...${NC}"
  if ! id "$WEB_USER" &>/dev/null; then
    useradd --system --create-home --shell /usr/sbin/nologin "$WEB_USER"
  fi
  mkdir -p /home/$WEB_USER
  chown $WEB_USER:$WEB_USER /home/$WEB_USER
  chmod 755 /home/$WEB_USER
  echo -e "${GREEN}[OK]${NC} User created"
  save_state "app_user"
}

setup_mysql_keyring() {
  if is_step_complete "mysql_keyring"; then
    echo -e "${YELLOW}[SKIP]${NC} MySQL keyring already configured"
    return 0
  fi

  echo -e "\n${CYAN}Configuring MySQL keyring for encryption...${NC}"

  # Configure keyring_file and default table encryption
  mkdir -p /etc/mysql/mysql.conf.d
  cat > /etc/mysql/mysql.conf.d/encryption.cnf <<'EOF'
[mysqld]
early-plugin-load=keyring_file.so
keyring_file_data=/var/lib/mysql-keyring/keyring
innodb_file_per_table=ON
default_table_encryption=ON
EOF

  # Set proper permissions for MySQL to read the config file
  chown root:root /etc/mysql/mysql.conf.d/encryption.cnf
  chmod 644 /etc/mysql/mysql.conf.d/encryption.cnf

  mkdir -p /var/lib/mysql-keyring
  chown mysql:mysql /var/lib/mysql-keyring
  chmod 750 /var/lib/mysql-keyring

  systemctl restart mysql
  sleep 3

  # Verify the plugin is ACTIVE
  if ! mysql -NBe "SELECT PLUGIN_STATUS FROM INFORMATION_SCHEMA.PLUGINS WHERE PLUGIN_NAME='keyring_file'" | grep -q ACTIVE; then
    echo -e "${RED}[ERROR]${NC} keyring_file not active after restart"
    echo -e "${YELLOW}Checking MySQL error log...${NC}"
    journalctl -u mysql -n 50 --no-pager || true
    exit 1
  fi

  echo -e "${GREEN}[OK]${NC} MySQL keyring configured"
  save_state "mysql_keyring"
}

configure_mysql_database() {
  if is_step_complete "mysql_config"; then
    echo -e "${YELLOW}[SKIP]${NC} MySQL already configured"
    if [ -f "$INSTALL_DIR/config/db-password.env" ]; then
      # shellcheck disable=SC1091
      source "$INSTALL_DIR/config/db-password.env" || true
      [ -n "${DB_PASSWORD:-}" ] && export DB_APP_PASSWORD="$DB_PASSWORD" || true
    fi
    if [ -z "${DB_APP_PASSWORD:-}" ]; then
      echo -e "${YELLOW}[INFO]${NC} App DB password file missing; generating a new one and updating MySQL user"
      APP_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
      mysql <<EOF
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${APP_PASSWORD}';
FLUSH PRIVILEGES;
EOF
      mkdir -p "$INSTALL_DIR/config"
      echo "DB_PASSWORD=${APP_PASSWORD}" > "$INSTALL_DIR/config/db-password.env"
      chown $WEB_USER:$WEB_USER "$INSTALL_DIR/config/db-password.env"
      chmod 600 "$INSTALL_DIR/config/db-password.env"
      export DB_APP_PASSWORD="${APP_PASSWORD}"
    fi
    return 0
  fi

  echo -e "\n${CYAN}Configuring MySQL database...${NC}"
  if mysql -e "USE ${DB_NAME};" 2>/dev/null; then
    echo -e "${YELLOW}[SKIP]${NC} Database already exists"
    if [ -f "$INSTALL_DIR/config/db-password.env" ]; then
      source "$INSTALL_DIR/config/db-password.env" || true
      [ -n "${DB_PASSWORD:-}" ] && export DB_APP_PASSWORD="$DB_PASSWORD" || true
    fi
    if [ -z "${DB_APP_PASSWORD:-}" ]; then
      APP_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
      mysql <<EOF
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${APP_PASSWORD}';
FLUSH PRIVILEGES;
EOF
      mkdir -p "$INSTALL_DIR/config"
      echo "DB_PASSWORD=${APP_PASSWORD}" > "$INSTALL_DIR/config/db-password.env"
      chown $WEB_USER:$WEB_USER "$INSTALL_DIR/config/db-password.env"
      chmod 600 "$INSTALL_DIR/config/db-password.env"
      export DB_APP_PASSWORD="${APP_PASSWORD}"
    fi
    save_state "mysql_config"
    return 0
  fi

  ROOT_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
  APP_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"

  mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASSWORD}';" 2>/dev/null || true
  mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASSWORD}';"

  cat > /root/.my.cnf <<EOF
[client]
user=root
password=${ROOT_PASSWORD}
EOF
  chmod 600 /root/.my.cnf

  mysql <<EOF
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci ENCRYPTION='Y';
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${APP_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

  mkdir -p "$(dirname "$CREDENTIALS_FILE")"
  cat > "$CREDENTIALS_FILE" <<EOF
=== XCP-ng Management Server Credentials ===
Generated: $(date)
MySQL Server:
  Server: localhost
  Root Password: ${ROOT_PASSWORD}
  Database: ${DB_NAME} (InnoDB Encrypted)
  App User: ${DB_USER}
  App Password: ${APP_PASSWORD}
Configuration:
  Root credentials: /root/.my.cnf
  App password: $INSTALL_DIR/config/db-password.env
EOF
  chmod 600 "$CREDENTIALS_FILE"
  chown root:root "$CREDENTIALS_FILE"

  export DB_APP_PASSWORD="${APP_PASSWORD}"
  echo -e "${GREEN}[OK]${NC} Database configured"
  save_state "mysql_config"
}

create_database_schema() {
  if is_step_complete "db_schema"; then
    echo -e "${YELLOW}[SKIP]${NC} Database schema already created"
    return 0
  fi

  echo -e "\n${CYAN}Creating database schema...${NC}"
  mysql "${DB_NAME}" <<'SCHEMA_EOF'
CREATE TABLE IF NOT EXISTS RegisteredAgents (
  AgentId VARCHAR(36) PRIMARY KEY,
  VmUuid VARCHAR(255) UNIQUE NOT NULL,
  VmName VARCHAR(255),
  Hostname VARCHAR(255),
  OsType VARCHAR(50),
  OsVersion VARCHAR(255),
  AgentVersion VARCHAR(50),
  Tags TEXT,
  LastCheckIn DATETIME,
  Status VARCHAR(20) DEFAULT 'Active',
  CreatedAt DATETIME DEFAULT CURRENT_TIMESTAMP,
  UpdatedAt DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_status (Status),
  INDEX idx_last_checkin (LastCheckIn),
  INDEX idx_os_type (OsType)
) ENGINE=InnoDB ENCRYPTION='Y';

CREATE TABLE IF NOT EXISTS AgentJobs (
  JobId VARCHAR(36) PRIMARY KEY,
  AgentId VARCHAR(36) NOT NULL,
  JobType VARCHAR(50) NOT NULL,
  Parameters TEXT,
  Status VARCHAR(20) DEFAULT 'Pending',
  Priority INT DEFAULT 0,
  CreatedAt DATETIME DEFAULT CURRENT_TIMESTAMP,
  UpdatedAt DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  StartedAt DATETIME,
  CompletedAt DATETIME,
  Result TEXT,
  ErrorMessage TEXT,
  FOREIGN KEY (AgentId) REFERENCES RegisteredAgents(AgentId) ON DELETE CASCADE,
  INDEX idx_agent_status (AgentId, Status),
  INDEX idx_status_priority (Status, Priority DESC),
  INDEX idx_created (CreatedAt)
) ENGINE=InnoDB ENCRYPTION='Y';

CREATE TABLE IF NOT EXISTS HypervisorJobs (
  JobId VARCHAR(36) PRIMARY KEY,
  JobType VARCHAR(50) NOT NULL,
  VmUuid VARCHAR(255),
  HostId VARCHAR(36),
  Parameters TEXT,
  Status VARCHAR(20) DEFAULT 'Pending',
  LinkedAgentJobId VARCHAR(36),
  CreatedAt DATETIME DEFAULT CURRENT_TIMESTAMP,
  UpdatedAt DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CompletedAt DATETIME,
  Result TEXT,
  ErrorMessage TEXT,
  FOREIGN KEY (LinkedAgentJobId) REFERENCES AgentJobs(JobId) ON DELETE SET NULL,
  INDEX idx_status (Status),
  INDEX idx_vm_uuid (VmUuid),
  INDEX idx_created (CreatedAt)
) ENGINE=InnoDB ENCRYPTION='Y';

CREATE TABLE IF NOT EXISTS XcpHosts (
  HostId VARCHAR(36) PRIMARY KEY,
  HostName VARCHAR(255) NOT NULL,
  HostUrl VARCHAR(255) NOT NULL,
  Username VARCHAR(255) NOT NULL,
  PasswordHash VARCHAR(255) NOT NULL,
  Active BOOLEAN DEFAULT TRUE,
  CreatedAt DATETIME DEFAULT CURRENT_TIMESTAMP,
  UpdatedAt DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  LastConnected DATETIME,
  INDEX idx_active (Active)
) ENGINE=InnoDB ENCRYPTION='Y';

CREATE TABLE IF NOT EXISTS JobSchedules (
  ScheduleId VARCHAR(36) PRIMARY KEY,
  JobType VARCHAR(50) NOT NULL,
  TargetType VARCHAR(20) NOT NULL,
  TargetId VARCHAR(255) NOT NULL,
  Parameters TEXT,
  ScheduleType VARCHAR(20) NOT NULL,
  ScheduleExpression VARCHAR(255),
  NextRunTime DATETIME,
  LastRunTime DATETIME,
  Active BOOLEAN DEFAULT TRUE,
  CreatedAt DATETIME DEFAULT CURRENT_TIMESTAMP,
  UpdatedAt DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_next_run (Active, NextRunTime),
  INDEX idx_target (TargetType, TargetId)
) ENGINE=InnoDB ENCRYPTION='Y';

CREATE TABLE IF NOT EXISTS AuditLog (
  LogId BIGINT AUTO_INCREMENT PRIMARY KEY,
  Timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
  UserId VARCHAR(255),
  Action VARCHAR(100) NOT NULL,
  EntityType VARCHAR(50),
  EntityId VARCHAR(255),
  Details TEXT,
  IpAddress VARCHAR(45),
  INDEX idx_timestamp (Timestamp),
  INDEX idx_user (UserId),
  INDEX idx_entity (EntityType, EntityId)
) ENGINE=InnoDB ENCRYPTION='Y';

CREATE TABLE IF NOT EXISTS Users (
  UserId VARCHAR(36) PRIMARY KEY,
  Username VARCHAR(255) UNIQUE NOT NULL,
  Email VARCHAR(255) UNIQUE NOT NULL,
  PasswordHash VARCHAR(255) NOT NULL,
  Role VARCHAR(50) DEFAULT 'User',
  Active BOOLEAN DEFAULT TRUE,
  CreatedAt DATETIME DEFAULT CURRENT_TIMESTAMP,
  UpdatedAt DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  LastLogin DATETIME,
  INDEX idx_username (Username),
  INDEX idx_email (Email)
) ENGINE=InnoDB ENCRYPTION='Y';
SCHEMA_EOF

  echo -e "${GREEN}[OK]${NC} Database schema created"
  save_state "db_schema"
}

install_certbot() {
  if is_step_complete "certbot"; then
    echo -e "${YELLOW}[SKIP]${NC} Certbot already installed"
    return 0
  fi

  echo -e "\n${CYAN}Installing Certbot...${NC}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot
  if [ "$DNS_PROVIDER" = "cloudflare" ] || [ "$WILDCARD" = true ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-dns-cloudflare
  fi
  echo -e "${GREEN}[OK]${NC} Certbot installed"
  save_state "certbot"
}

setup_cloudflare_dns() {
  echo -e "\n${CYAN}=== Cloudflare DNS Setup ===${NC}"
  : "${CF_API_TOKEN:=${CF_API_TOKEN:-}}"
  if [ -z "$CF_API_TOKEN" ]; then
    read -p "Enter Cloudflare API Token: " CF_API_TOKEN
  fi
  [ -n "$CF_API_TOKEN" ] || { echo -e "${RED}[ERROR]${NC} Token required"; exit 1; }

  mkdir -p /root/.secrets/certbot
  umask 077
  cat > /root/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
  chmod 600 /root/.secrets/certbot/cloudflare.ini

  local DOM_ARGS=()
  if [ "$WILDCARD" = true ]; then
    DOM_ARGS=(-d "*.${BASE_DOMAIN}" -d "${BASE_DOMAIN}")
  else
    DOM_ARGS=(-d "${DOMAIN}")
  fi

  echo -e "\n${CYAN}Requesting certificate via Cloudflare DNS-01...${NC}"
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
    --dns-cloudflare-propagation-seconds "${CF_PROPAGATION_SECONDS}" \
    "${DOM_ARGS[@]}" \
    --email "${EMAIL}" --agree-tos --no-eff-email --non-interactive
}

setup_letsencrypt() {
  if is_step_complete "letsencrypt"; then
    echo -e "${YELLOW}[SKIP]${NC} Certificate already obtained"
    return 0
  fi

  compute_domains

  if [ -d "/etc/letsencrypt/live/${CERT_NAME}" ]; then
    echo -e "${GREEN}[OK]${NC} Certificate exists"
    save_state "letsencrypt"
    return 0
  fi

  echo -e "\n${CYAN}Setting up Let's Encrypt certificate...${NC}"
  case "$DNS_PROVIDER" in
    cloudflare)
      setup_cloudflare_dns || { echo -e "${RED}[ERROR]${NC} Certificate failed"; exit 1; }
      ;;
    http|*)
      mkdir -p /var/www/certbot
      certbot certonly --webroot -w /var/www/certbot \
        -d "${DOMAIN}" \
        --email "${EMAIL}" --agree-tos --no-eff-email --non-interactive \
        || { echo -e "${RED}[ERROR]${NC} Certificate failed"; exit 1; }
      ;;
  esac

  echo -e "${GREEN}[OK]${NC} Certificate obtained"
  save_state "letsencrypt"
}

setup_cert_renewal() {
  if is_step_complete "cert_renewal"; then
    echo -e "${YELLOW}[SKIP]${NC} Renewal configured"
    return 0
  fi

  echo -e "\n${CYAN}Setting up auto-renewal hooks...${NC}"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload.sh <<'EOF'
#!/bin/bash
systemctl reload nginx || true
systemctl reload xcp-management 2>/dev/null || true
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload.sh
  echo -e "${GREEN}[OK]${NC} Renewal configured"
  save_state "cert_renewal"
}

configure_nginx_site() {
  if is_step_complete "nginx_site"; then
    echo -e "${YELLOW}[SKIP]${NC} Nginx site configured"
    return 0
  fi

  echo -e "\n${CYAN}Configuring Nginx HTTPS site...${NC}"

  cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
  worker_connections 768;
}

http {
  sendfile on;
  tcp_nopush on;
  types_hash_max_size 2048;
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  access_log /var/log/nginx/access.log;

  gzip on;

  limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;

  include /etc/nginx/conf.d/*.conf;
  include /etc/nginx/sites-enabled/*;
}
EOF

  cat > /etc/nginx/sites-available/xcp-management <<EOF
upstream xcp_backend {
  server 127.0.0.1:5000;
  keepalive 32;
}

server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};

  location /.well-known/acme-challenge/ {
    root /var/www/certbot;
  }
  location / {
    return 301 https://\$host\$request_uri;
  }
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${DOMAIN};

  ssl_certificate /etc/letsencrypt/live/${CERT_NAME}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${CERT_NAME}/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;

  add_header Strict-Transport-Security "max-age=31536000" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-Frame-Options "DENY" always;
  add_header Referrer-Policy "no-referrer" always;

  location / {
    limit_req zone=api_limit burst=20 nodelay;
    proxy_pass http://xcp_backend;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF

  ln -sf /etc/nginx/sites-available/xcp-management /etc/nginx/sites-enabled/xcp-management
  nginx -t && systemctl reload nginx
  echo -e "${GREEN}[OK]${NC} Nginx site configured"
  save_state "nginx_site"
}

create_app_structure() {
  if is_step_complete "app_structure"; then
    echo -e "${YELLOW}[SKIP]${NC} Structure exists"
    return 0
  fi

  echo -e "\n${CYAN}Creating structure...${NC}"
  mkdir -p "$INSTALL_DIR"/{bin,config,logs,data,certificates,backups}
  chown -R $WEB_USER:$WEB_USER "$INSTALL_DIR"
  chmod 750 "$INSTALL_DIR"
  chmod 700 "$INSTALL_DIR/config" "$INSTALL_DIR/certificates"

  compute_domains
  # Copy public chain as a CA file (if available)
  cp "/etc/letsencrypt/live/${CERT_NAME}/fullchain.pem" "$INSTALL_DIR/certificates/server-cert.pem" 2>/dev/null || true
  chown $WEB_USER:$WEB_USER "$INSTALL_DIR/certificates/server-cert.pem" 2>/dev/null || true
  chmod 644 "$INSTALL_DIR/certificates/server-cert.pem" 2>/dev/null || true

  echo -e "${GREEN}[OK]${NC} Structure created"
  save_state "app_structure"
}

create_systemd_service() {
  if is_step_complete "systemd"; then
    echo -e "${YELLOW}[SKIP]${NC} Service exists"
    return 0
  fi

  echo -e "\n${CYAN}Creating service...${NC}"
  cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=XCP-ng VM Management Web Server
After=network.target mysql.service
Wants=network-online.target

[Service]
Type=simple
User=${WEB_USER}
WorkingDirectory=${INSTALL_DIR}/bin
ExecStart=/usr/bin/dotnet ${INSTALL_DIR}/bin/XcpManagement.dll
Restart=always
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=${SERVICE_NAME}
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
Environment=DOTNET_CLI_HOME=${INSTALL_DIR}
Environment=DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1
Environment=HOME=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/config/db-password.env

# Hardening (safe for .NET JIT)
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectProc=invisible
ReadWritePaths=${INSTALL_DIR}
LockPersonality=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" || true
  echo -e "${GREEN}[OK]${NC} Service created"
  save_state "systemd"
}

create_deploy_script() {
  if is_step_complete "deploy_script"; then
    echo -e "${YELLOW}[SKIP]${NC} Deploy script exists"
    return 0
  fi

  echo -e "\n${CYAN}Creating deploy script...${NC}"
  cat > "${INSTALL_DIR}/deploy.sh" <<'DEPLOY_EOF'
#!/bin/bash
set -Eeuo pipefail
INSTALL_DIR="/opt/xcp-management"
SERVICE_NAME="xcp-management"

if [ "$EUID" -ne 0 ]; then echo "ERROR: Must run as root"; exit 1; fi

SOURCE_DIR=""
SKIP_BACKUP=false
NO_RESTART=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --source) SOURCE_DIR="$2"; shift 2;;
    --skip-backup) SKIP_BACKUP=true; shift;;
    --no-restart) NO_RESTART=true; shift;;
    *) echo "Unknown: $1"; exit 1;;
  esac
done

[ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ] || { echo "ERROR: Invalid source directory"; exit 1; }

mkdir -p "${INSTALL_DIR}/backups"
if [ "$SKIP_BACKUP" = false ]; then
  echo "Backing up..."
  tar -czf "${INSTALL_DIR}/backups/backup-$(date +%Y%m%d-%H%M%S).tar.gz" -C "${INSTALL_DIR}" bin config 2>/dev/null || true
fi

echo "Stopping service..."
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

echo "Deploying..."
mkdir -p "${INSTALL_DIR}/bin"
rm -rf "${INSTALL_DIR}/bin"/*
cp -r "${SOURCE_DIR}/"* "${INSTALL_DIR}/bin/"

# Preserve configuration files if present
for f in appsettings.json appsettings.Production.json; do
  if [ -f "${INSTALL_DIR}/config/$f" ]; then
    cp "${INSTALL_DIR}/config/$f" "${INSTALL_DIR}/bin/$f"
  fi
done

chown -R xcp-web:xcp-web "${INSTALL_DIR}/bin"
chmod 750 "${INSTALL_DIR}/bin"

if [ "$NO_RESTART" = false ]; then
  echo "Starting service..."
  systemctl start "$SERVICE_NAME"
  sleep 3
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    echo "SUCCESS: Service running"
  else
    echo "ERROR: Service failed"
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager
    exit 1
  fi
else
  echo "Skipped service restart (--no-restart)"
fi
DEPLOY_EOF

  chmod +x "${INSTALL_DIR}/deploy.sh"
  echo -e "${GREEN}[OK]${NC} Deploy script created"
  save_state "deploy_script"
}

create_update_script() {
  if is_step_complete "update_script"; then
    echo -e "${YELLOW}[SKIP]${NC} Update script exists"
    return 0
  fi

  echo -e "\n${CYAN}Creating update script...${NC}"
  cat > "${INSTALL_DIR}/update.sh" <<'UPDATE_EOF'
#!/bin/bash
# XCP-ng Management Server Update Script (GitHub-only)
set -Eeuo pipefail

INSTALL_DIR="/opt/xcp-management"
GITHUB_REPO="franklethemouse/xcp-automation"
GITHUB_BRANCH="main"
WORK_DIR="/tmp/xcp-update-$$"
PROJECT_PATH="Server (Linux)/XcpManagement"
PROJECT_FILE="XcpManagement.csproj"
HEALTH_URL="http://localhost:5000/health"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then echo -e "${RED}ERROR: Must run as root${NC}"; exit 1; fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)         GITHUB_REPO="$2"; shift 2;;
    --branch)       GITHUB_BRANCH="$2"; shift 2;;
    --project-path) PROJECT_PATH="$2"; shift 2;;
    --project-file) PROJECT_FILE="$2"; shift 2;;
    --health-url)   HEALTH_URL="$2"; shift 2;;
    *) echo "Unknown: $1"; exit 1;;
  esac
done

cleanup(){ rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo -e "${CYAN}=== XCP-ng Management Update ===${NC}\n"

# 1) Download
echo -e "${CYAN}[1/5]${NC} Downloading from GitHub..."
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
for BRANCH_TRY in "$GITHUB_BRANCH" "main" "master"; do
  ARCHIVE_URL="https://github.com/${GITHUB_REPO}/archive/refs/heads/${BRANCH_TRY}.zip"
  echo "Trying: $ARCHIVE_URL"
  wget --timeout=30 --tries=2 -q "$ARCHIVE_URL" -O source.zip 2>/dev/null && [ -s source.zip ] && { echo -e "${GREEN}Downloaded from: $BRANCH_TRY${NC}"; break; }
  rm -f source.zip
done
[ -f source.zip ] && [ -s source.zip ] || { echo -e "${RED}ERROR: Failed to download from GitHub${NC}"; exit 1; }

# 2) Extract
echo -e "${CYAN}[2/5]${NC} Extracting source..."
unzip -q source.zip
REPO_NAME=$(basename "$GITHUB_REPO")
SOURCE_DIR=$(find . -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n 1)
[ -n "$SOURCE_DIR" ] || { echo -e "${RED}ERROR: Could not find source directory${NC}"; exit 1; }

PROJECT_DIR="${SOURCE_DIR}/${PROJECT_PATH}"
[ -f "${PROJECT_DIR}/${PROJECT_FILE}" ] || { echo -e "${RED}ERROR: Project file not found${NC}"; exit 1; }

# 3) Build
echo -e "${CYAN}[3/5]${NC} Building application..."
cd "$PROJECT_DIR"
dotnet publish -c Release -r linux-x64 --self-contained false -o "$WORK_DIR/publish" || { echo -e "${RED}ERROR: Build failed${NC}"; exit 1; }

# 4) Deploy
echo -e "${CYAN}[4/5]${NC} Deploying..."
"${INSTALL_DIR}/deploy.sh" --source "$WORK_DIR/publish"

# 5) Verify
echo -e "${CYAN}[5/5]${NC} Verifying..."
sleep 2
if systemctl is-active --quiet xcp-management; then
  echo -e "${GREEN}✓ Service running${NC}"
else
  echo -e "${RED}✗ Service failed${NC}"; exit 1
fi
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" || echo 000)
[ "$HTTP_CODE" = "200" ] && echo -e "${GREEN}✓ Health check passed${NC}" || { echo -e "${YELLOW}! Health check returned ${HTTP_CODE}${NC}"; }

echo -e "\n${GREEN}=== Update Complete ===${NC}"
echo "Access: https://$(hostname -f)/"
UPDATE_EOF

  chmod +x "${INSTALL_DIR}/update.sh"
  echo -e "${GREEN}[OK]${NC} Update script created"
  save_state "update_script"
}

create_initial_config() {
  if is_step_complete "config"; then
    echo -e "${YELLOW}[SKIP]${NC} Config exists"
    return 0
  fi

  echo -e "\n${CYAN}Creating config...${NC}"

  # Defensive: ensure DB_APP_PASSWORD exists (in-memory and file)
  if [ -z "${DB_APP_PASSWORD:-}" ]; then
    APP_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-25)"
    mysql <<EOF
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${APP_PASSWORD}';
FLUSH PRIVILEGES;
EOF
    mkdir -p "${INSTALL_DIR}/config"
    echo "DB_PASSWORD=${APP_PASSWORD}" > "${INSTALL_DIR}/config/db-password.env"
    chown $WEB_USER:$WEB_USER "${INSTALL_DIR}/config/db-password.env"
    chmod 600 "${INSTALL_DIR}/config/db-password.env"
    export DB_APP_PASSWORD="${APP_PASSWORD}"
  fi

  JWT_SECRET="$(openssl rand -base64 32)"
  API_KEY="$(openssl rand -hex 32)"
  mkdir -p "${INSTALL_DIR}/config"

  cat > "${INSTALL_DIR}/config/appsettings.json" <<EOF
{
  "Logging": { "LogLevel": { "Default": "Information", "Microsoft.AspNetCore": "Warning" } },
  "AllowedHosts": "*",
  "Kestrel": { "Endpoints": { "Http": { "Url": "http://127.0.0.1:5000" } } },
  "ConnectionStrings": { "DefaultConnection": "Server=localhost;Database=${DB_NAME};User=${DB_USER};SslMode=Preferred;" },
  "Security": {
    "JwtSecret": "${JWT_SECRET}",
    "JwtIssuer": "https://${DOMAIN}",
    "JwtAudience": "https://${DOMAIN}",
    "ApiKey": "${API_KEY}"
  },
  "Certificates": {
    "CACertificatePath": "${INSTALL_DIR}/certificates/server-cert.pem"
  },
  "XcpConfig": { "DefaultHosts": [] }
}
EOF

  cp "${INSTALL_DIR}/config/appsettings.json" "${INSTALL_DIR}/config/appsettings.Production.json"

  chown $WEB_USER:$WEB_USER "${INSTALL_DIR}/config/appsettings.json" "${INSTALL_DIR}/config/appsettings.Production.json"
  chmod 600 "${INSTALL_DIR}/config/appsettings.json" "${INSTALL_DIR}/config/appsettings.Production.json"

  # Ensure DB password file mirrors memory
  cat > "${INSTALL_DIR}/config/db-password.env" <<EOF
DB_PASSWORD=${DB_APP_PASSWORD}
EOF
  chown $WEB_USER:$WEB_USER "${INSTALL_DIR}/config/db-password.env"
  chmod 600 "${INSTALL_DIR}/config/db-password.env"

  echo -e "${GREEN}[OK]${NC} Config created"
  save_state "config"
}

predeploy_verify_stack() {
  echo -e "\n${CYAN}=== Verifying Base Stack ===${NC}\n"
  systemctl is-active --quiet mysql   && echo -e "${GREEN}✓${NC} MySQL is running" || echo -e "${YELLOW}!${NC} MySQL not running"
  systemctl is-active --quiet nginx   && echo -e "${GREEN}✓${NC} Nginx is running" || echo -e "${YELLOW}!${NC} Nginx not running"
  compute_domains
  [ -d "/etc/letsencrypt/live/${CERT_NAME}" ] && echo -e "${GREEN}✓${NC} SSL certificate exists" || echo -e "${YELLOW}!${NC} SSL certificate not found"
  [ -d "$INSTALL_DIR" ] && echo -e "${GREEN}✓${NC} Installation directory exists" || echo -e "${YELLOW}!${NC} Installation directory missing"
}

postdeploy_verify() {
  echo -e "\n${CYAN}=== Final Verification ===${NC}\n"
  systemctl is-active --quiet xcp-management && echo -e "${GREEN}✓${NC} Service running" || { echo -e "${RED}✗${NC} Service not running"; return 1; }
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:5000/health" || echo 000)
  [ "$code" = "200" ] && echo -e "${GREEN}✓${NC} Health check passed" || echo -e "${YELLOW}!${NC} Health check returned ${code}"
}

display_summary() {
  compute_domains
  echo -e "\n${GREEN}=== Installation Complete ===${NC}\n"
  echo "Domain:       ${DOMAIN}"
  if [ "$WILDCARD" = true ]; then
    echo "Certificate:  *.${BASE_DOMAIN} (+ ${BASE_DOMAIN}) via ${DNS_PROVIDER}"
  else
    echo "Certificate:  ${DOMAIN} via ${DNS_PROVIDER}"
  fi
  echo "Database:     ${DB_NAME} (encrypted)"
  echo "Install Dir:  ${INSTALL_DIR}"
  echo "Credentials:  ${CREDENTIALS_FILE}"
  echo "Certificates: ${INSTALL_DIR}/certificates/server-cert.pem (public chain only)"
  echo
  echo -e "${CYAN}Next Steps:${NC}"
  echo " 1) Deploy from GitHub:"
  echo "    sudo ${INSTALL_DIR}/update.sh"
  echo
  echo " 2) Access:"
  echo "    https://${DOMAIN}/"
}

deploy_from_github() {
  echo -e "\n${CYAN}=== Deploying from GitHub ===${NC}\n"
  [ -f "${INSTALL_DIR}/update.sh" ] || { echo -e "${RED}[ERROR]${NC} Update script not found"; exit 1; }
  "${INSTALL_DIR}/update.sh" --repo "${GITHUB_REPO}" --branch "${GITHUB_BRANCH}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  # Parse args
  while [[ $# -gt 0 ]]; do
    case $1 in
      -y|--yes) AUTO_YES=true; shift ;;
      --skip-cert) SKIP_CERT=true; shift ;;
      --cert-only) CERT_ONLY=true; shift ;;
      --resume) RESUME=true; shift ;;
      --update) UPDATE_ONLY=true; shift ;;
      --takeover-nginx) TAKEOVER_NGINX=true; shift ;;
      --email) EMAIL="$2"; shift 2 ;;
      --domain) DOMAIN="$2"; shift 2 ;;
      --github-repo) GITHUB_REPO="$2"; shift 2 ;;
      --branch) GITHUB_BRANCH="$2"; shift 2 ;;
      --dns-provider) DNS_PROVIDER="$2"; shift 2 ;;
      --wildcard) WILDCARD=true; shift ;;
      --cf-token) CF_API_TOKEN="$2"; shift 2 ;;
      --cf-propagation-seconds) CF_PROPAGATION_SECONDS="$2"; shift 2 ;;
      -h|--help) show_help; exit 0 ;;
      *) echo -e "${RED}[ERROR]${NC} Unknown option: $1"; echo "Use --help for usage."; exit 1 ;;
    esac
  done

  # Fail fast in non-interactive mode if required values are missing
  if [ "$AUTO_YES" = true ]; then
    if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
      echo -e "${RED}[ERROR]${NC} --domain and --email are required when running with -y (non-interactive)."
      exit 1
    fi
  fi

  if [ "$UPDATE_ONLY" = true ]; then
    echo -e "${CYAN}Update mode — deploying from GitHub...${NC}\n"
    [ -f "${INSTALL_DIR}/update.sh" ] || { echo -e "${RED}[ERROR]${NC} System not installed. Run installer first."; exit 1; }
    "${INSTALL_DIR}/update.sh" --repo "${GITHUB_REPO}" --branch "${GITHUB_BRANCH}"
    exit 0
  fi

  if [ "$CERT_ONLY" = true ]; then
    prompt_config
    install_dependencies
    install_nginx_base
    create_nginx_http
    install_certbot
    setup_letsencrypt
    setup_cert_renewal
    echo -e "\n${GREEN}Certificate complete!${NC}"
    exit 0
  fi

  prompt_config

  echo -e "\n${CYAN}Starting installation...${NC}"

  # Infra & runtime
  install_dependencies
  install_dotnet
  install_nginx_base
  create_nginx_http

  # Database & security
  install_mysql_server
  create_app_user
  setup_mysql_keyring
  configure_mysql_database
  create_database_schema

  # TLS & web
  if [ "$SKIP_CERT" = false ]; then
    install_certbot
    setup_letsencrypt
    setup_cert_renewal
    configure_nginx_site
  else
    echo -e "${YELLOW}[SKIP]${NC} Certificate setup skipped"
  fi

  # Application
  create_app_structure
  create_systemd_service
  create_deploy_script
  create_update_script
  create_initial_config

  save_state "complete"
  rm -f "$STATE_FILE"

  # Light pre-deploy stack check
  predeploy_verify_stack || true

  # Deploy now in auto mode, otherwise prompt
  if [ "$AUTO_YES" = true ]; then
    echo -e "\n${CYAN}Auto-yes is enabled — deploying from GitHub now...${NC}"
    deploy_from_github || true
    postdeploy_verify || true
    display_summary
  else
    display_summary
    echo -e "\n${CYAN}Deploy application now from GitHub? (recommended)${NC}"
    if prompt_user "Deploy from GitHub"; then
      deploy_from_github
      postdeploy_verify || true
    else
      echo -e "${YELLOW}[SKIP]${NC} You can deploy later with: sudo ${INSTALL_DIR}/update.sh"
    fi
  fi
}

main "$@"