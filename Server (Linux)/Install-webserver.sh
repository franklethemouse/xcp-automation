#!/bin/bash
# install-webserver.sh
# XCP-ng VM Management Web Server Installer
# Version: 1.5.1 - Fixed Nginx config and added health checks

set -e

VERSION="1.5.1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== XCP-ng VM Management Web Server Installer v${VERSION} ===${NC}\n"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] This script must be run as root${NC}"
    echo "Please run: sudo $0 $@"
    exit 1
fi

STATE_FILE="/tmp/xcp-webserver-install-state"

# Configuration with defaults
DOMAIN="xcp-automation.thebakkers.com.au"
BASE_DOMAIN="thebakkers.com.au"
WILDCARD_DOMAIN="*.thebakkers.com.au"
EMAIL="admin@thebakkers.com.au"
INSTALL_DIR="/opt/xcp-management"
SERVICE_NAME="xcp-management"
WEB_USER="xcp-web"
DB_NAME="XcpManagement"
DB_USER="xcp_app_user"
MYSQL_INSTALLED=false
CREDENTIALS_FILE="$INSTALL_DIR/CREDENTIALS.txt"

# Parse arguments
AUTO_YES=false
SKIP_CERT=false
CERT_ONLY=false
RESUME=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        --skip-cert)
            SKIP_CERT=true
            shift
            ;;
        --cert-only)
            CERT_ONLY=true
            shift
            ;;
        --resume)
            RESUME=true
            shift
            ;;
        --email)
            EMAIL="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            BASE_DOMAIN=$(echo "$2" | sed 's/^[^.]*\.//')
            WILDCARD_DOMAIN="*.$BASE_DOMAIN"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --domain DOMAIN    Full domain name (default: xcp-automation.thebakkers.com.au)"
    echo "  --email EMAIL      Email for Let's Encrypt (default: admin@thebakkers.com.au)"
    echo "  -y, --yes          Auto-yes to prompts"
    echo "  --skip-cert        Skip SSL certificate setup"
    echo "  --cert-only        Only setup SSL certificate"
    echo "  --resume           Resume from last checkpoint"
    echo "  -h, --help         Show this help"
}

save_state() {
    local step="$1"
    echo "$step" > "$STATE_FILE"
}

is_step_complete() {
    local step="$1"
    if [ -f "$STATE_FILE" ]; then
        local current_step=$(cat "$STATE_FILE")
        local steps=("dependencies" "dotnet" "nginx_base" "nginx_config_file" "mysql_install" "mysql_config" "db_schema" "certbot" "letsencrypt" "cert_renewal" "cert_export" "nginx_site" "app_user" "app_structure" "systemd" "deploy_script" "config" "complete")
        
        local current_index=-1
        local check_index=-1
        
        for i in "${!steps[@]}"; do
            if [ "${steps[$i]}" = "$current_step" ]; then
                current_index=$i
            fi
            if [ "${steps[$i]}" = "$step" ]; then
                check_index=$i
            fi
        done
        
        if [ $current_index -ge $check_index ]; then
            return 0
        fi
    fi
    return 1
}

generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

prompt_user() {
    local message="$1"
    
    if [ "$AUTO_YES" = true ]; then
        echo -e "${CYAN}$message${NC} (auto-yes enabled)"
        return 0
    fi
    
    read -p "$message (Y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

prompt_config() {
    if [ -z "$DOMAIN" ]; then
        echo -e "${CYAN}Domain Configuration:${NC}"
        read -p "Enter domain name (default: xcp-automation.thebakkers.com.au): " DOMAIN
        DOMAIN=${DOMAIN:-xcp-automation.thebakkers.com.au}
        BASE_DOMAIN=$(echo "$DOMAIN" | sed 's/^[^.]*\.//')
        WILDCARD_DOMAIN="*.$BASE_DOMAIN"
    fi
    
    if [ -z "$EMAIL" ]; then
        read -p "Enter email for Let's Encrypt (default: admin@thebakkers.com.au): " EMAIL
        EMAIL=${EMAIL:-admin@thebakkers.com.au}
    fi
    
    echo -e "\n${GREEN}Configuration:${NC}"
    echo "  Domain: $DOMAIN"
    echo "  Base Domain: $BASE_DOMAIN"
    echo "  Wildcard: $WILDCARD_DOMAIN"
    echo "  Email: $EMAIL"
    echo ""
    
    if [ "$AUTO_YES" = false ]; then
        if ! prompt_user "Continue with this configuration?"; then
            echo "Installation cancelled."
            exit 0
        fi
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        echo -e "${GREEN}[OK]${NC} Detected: $PRETTY_NAME"
    else
        echo -e "${RED}[ERROR]${NC} Cannot detect OS version"
        exit 1
    fi
}

install_dependencies() {
    if is_step_complete "dependencies"; then
        echo -e "${YELLOW}[SKIP]${NC} System dependencies already installed"
        return 0
    fi
    
    echo -e "\n${CYAN}Checking system dependencies...${NC}"
    
    case "$OS_ID" in
        ubuntu|debian)
            local to_install=()
            for pkg in curl wget git openssl; do
                if ! dpkg -l | grep -q "^ii  $pkg "; then
                    to_install+=("$pkg")
                fi
            done
            
            if [ ${#to_install[@]} -gt 0 ]; then
                echo -e "${CYAN}Installing: ${to_install[*]}${NC}"
                apt-get update -qq
                apt-get install -y "${to_install[@]}"
            fi
            echo -e "${GREEN}[OK]${NC} Dependencies installed"
            ;;
        
        rhel|centos|fedora|rocky|almalinux)
            if command -v dnf &> /dev/null; then
                dnf install -y curl wget git openssl
            else
                yum install -y curl wget git openssl
            fi
            ;;
    esac
    
    save_state "dependencies"
}

install_dotnet() {
    if is_step_complete "dotnet"; then
        echo -e "${YELLOW}[SKIP]${NC} .NET already installed"
        return 0
    fi
    
    if command -v dotnet &> /dev/null; then
        DOTNET_VERSION=$(dotnet --version)
        if [[ "$DOTNET_VERSION" == 8.* ]]; then
            echo -e "${GREEN}[OK]${NC} .NET 8 already installed: $DOTNET_VERSION"
            save_state "dotnet"
            return 0
        fi
    fi
    
    echo -e "\n${CYAN}Installing .NET 8...${NC}"
    
    case "$OS_ID" in
        ubuntu|debian)
            if [ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]; then
                wget -q https://packages.microsoft.com/config/$OS_ID/$OS_VERSION/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb
                dpkg -i /tmp/packages-microsoft-prod.deb
                rm /tmp/packages-microsoft-prod.deb
                apt-get update -qq
            fi
            
            apt-get install -y dotnet-sdk-8.0 aspnetcore-runtime-8.0
            ;;
    esac
    
    if command -v dotnet &> /dev/null; then
        DOTNET_VERSION=$(dotnet --version)
        echo -e "${GREEN}[OK]${NC} .NET installed: $DOTNET_VERSION"
        save_state "dotnet"
    else
        echo -e "${RED}[ERROR]${NC} .NET installation failed"
        exit 1
    fi
}

install_nginx_base() {
    if is_step_complete "nginx_base"; then
        echo -e "${YELLOW}[SKIP]${NC} Nginx base already installed"
        return 0
    fi
    
    echo -e "\n${CYAN}Installing Nginx...${NC}"
    
    case "$OS_ID" in
        ubuntu|debian)
            # Purge any broken installation
            apt-get purge -y nginx nginx-common nginx-core 2>/dev/null || true
            rm -rf /etc/nginx
            
            # Install fresh
            apt-get install -y nginx
            ;;
    esac
    
    echo -e "${GREEN}[OK]${NC} Nginx installed"
    save_state "nginx_base"
}

create_nginx_config() {
    if is_step_complete "nginx_config_file"; then
        echo -e "${YELLOW}[SKIP]${NC} Nginx config already created"
        return 0
    fi
    
    echo -e "\n${CYAN}Creating nginx.conf...${NC}"
    
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
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    
    access_log /var/log/nginx/access.log;
    
    gzip on;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # Test config
    nginx -t
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[OK]${NC} Nginx config created"
        systemctl enable nginx
        systemctl start nginx
        save_state "nginx_config_file"
    else
        echo -e "${RED}[ERROR]${NC} Nginx config test failed"
        exit 1
    fi
}

install_mysql_server() {
    if is_step_complete "mysql_install"; then
        echo -e "${YELLOW}[SKIP]${NC} MySQL already installed"
        MYSQL_INSTALLED=true
        return 0
    fi
    
    if systemctl is-active --quiet mysql || systemctl is-active --quiet mysqld; then
        echo -e "${GREEN}[OK]${NC} MySQL already running"
        MYSQL_INSTALLED=true
        save_state "mysql_install"
        return 0
    fi
    
    echo -e "\n${CYAN}Installing MySQL Server 8.0...${NC}"
    
    case "$OS_ID" in
        ubuntu|debian)
            if ! dpkg -l | grep -q "^ii  mysql-server "; then
                echo -e "${YELLOW}[INFO]${NC} This may take a few minutes..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server > /dev/null
            fi
            ;;
    esac
    
    systemctl enable mysql 2>/dev/null || true
    systemctl start mysql 2>/dev/null || true
    
    sleep 5
    
    if systemctl is-active --quiet mysql; then
        echo -e "${GREEN}[OK]${NC} MySQL installed"
        MYSQL_INSTALLED=true
        save_state "mysql_install"
    else
        echo -e "${RED}[ERROR]${NC} MySQL failed to start"
        exit 1
    fi
}

configure_mysql_database() {
    if is_step_complete "mysql_config"; then
        echo -e "${YELLOW}[SKIP]${NC} MySQL already configured"
        if [ -f "$INSTALL_DIR/config/db-password.env" ]; then
            source "$INSTALL_DIR/config/db-password.env"
            export DB_APP_PASSWORD="$DB_PASSWORD"
        fi
        return 0
    fi
    
    echo -e "\n${CYAN}Configuring MySQL database...${NC}"
    
    if mysql -e "USE $DB_NAME;" 2>/dev/null; then
        echo -e "${YELLOW}[SKIP]${NC} Database already exists"
        save_state "mysql_config"
        return 0
    fi
    
    ROOT_PASSWORD=$(generate_password)
    APP_PASSWORD=$(generate_password)
    
    echo -e "${CYAN}[INFO]${NC} Securing MySQL..."
    
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_PASSWORD';" 2>/dev/null || \
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$ROOT_PASSWORD';"
    
    cat > /root/.my.cnf <<EOF
[client]
user=root
password=$ROOT_PASSWORD
EOF
    chmod 600 /root/.my.cnf
    
    echo -e "${CYAN}[INFO]${NC} Configuring encryption..."
    
    mysql -e "INSTALL PLUGIN keyring_file SONAME 'keyring_file.so';" 2>/dev/null || true
    
    mkdir -p /etc/mysql/mysql.conf.d
    cat > /etc/mysql/mysql.conf.d/encryption.cnf <<EOF
[mysqld]
early-plugin-load=keyring_file.so
keyring_file_data=/var/lib/mysql-keyring/keyring
innodb_file_per_table=ON
default_table_encryption=ON
EOF
    
    mkdir -p /var/lib/mysql-keyring
    chown mysql:mysql /var/lib/mysql-keyring
    chmod 750 /var/lib/mysql-keyring
    
    echo -e "${CYAN}[INFO]${NC} Restarting MySQL..."
    systemctl restart mysql
    sleep 5
    
    echo -e "${CYAN}[INFO]${NC} Creating database and user..."
    
    mysql <<EOF
CREATE DATABASE $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci ENCRYPTION='Y';
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$APP_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    echo -e "${GREEN}[OK]${NC} Database configured"
    
    mkdir -p "$INSTALL_DIR/config"
    cat > "$CREDENTIALS_FILE" <<EOF
=== XCP-ng Management Server Credentials ===
Generated: $(date)

MySQL Server:
  Server: localhost
  Root Password: $ROOT_PASSWORD
  Database: $DB_NAME (InnoDB Encrypted)
  App User: $DB_USER
  App Password: $APP_PASSWORD

Configuration:
  Root credentials: /root/.my.cnf
  App password: $INSTALL_DIR/config/db-password.env

Access:
  mysql (uses /root/.my.cnf)
EOF
    
    chmod 600 "$CREDENTIALS_FILE"
    chown root:root "$CREDENTIALS_FILE"
    
    export DB_APP_PASSWORD="$APP_PASSWORD"
    save_state "mysql_config"
}

create_database_schema() {
    if is_step_complete "db_schema"; then
        echo -e "${YELLOW}[SKIP]${NC} Database schema already created"
        return 0
    fi
    
    echo -e "\n${CYAN}Creating database schema...${NC}"
    
    mysql $DB_NAME <<'SCHEMA_EOF'
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

INSERT INTO Users (UserId, Username, Email, PasswordHash, Role) 
VALUES (
    UUID(),
    'admin',
    'admin@thebakkers.com.au',
    '$2a$11$fRzffGV9WSsHjyAsjkpLTukc4vyGsiQlKHCSPfL95d4DrT4Mb2dxm',
    'Admin'
) ON DUPLICATE KEY UPDATE UserId=UserId;
SCHEMA_EOF
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[OK]${NC} Database schema created"
        echo -e "${CYAN}[INFO]${NC} Default admin user: admin / Admin123!"
    else
        echo -e "${RED}[ERROR]${NC} Failed to create schema"
        exit 1
    fi
    
    save_state "db_schema"
}

install_certbot() {
    if is_step_complete "certbot"; then
        echo -e "${YELLOW}[SKIP]${NC} Certbot already installed"
        return 0
    fi
    
    if command -v certbot &> /dev/null; then
        echo -e "${GREEN}[OK]${NC} Certbot already installed"
        save_state "certbot"
        return 0
    fi
    
    echo -e "\n${CYAN}Installing Certbot...${NC}"
    
    apt-get install -y certbot python3-certbot-dns-cloudflare
    
    echo -e "${GREEN}[OK]${NC} Certbot installed"
    save_state "certbot"
}

setup_letsencrypt() {
    if is_step_complete "letsencrypt"; then
        echo -e "${YELLOW}[SKIP]${NC} Certificate already obtained"
        return 0
    fi
    
    if [ -d "/etc/letsencrypt/live/$BASE_DOMAIN" ]; then
        echo -e "${GREEN}[OK]${NC} Certificate exists"
        save_state "letsencrypt"
        return 0
    fi
    
    echo -e "\n${CYAN}Setting up Let's Encrypt certificate...${NC}"
    echo -e "${YELLOW}[INFO]${NC} Wildcard certificates require DNS validation"
    echo ""
    echo "Supported DNS providers:"
    echo "  1. Cloudflare"
    echo "  2. Manual DNS"
    echo ""
    
    if [ "$AUTO_YES" = false ]; then
        read -p "Select DNS provider (1/2): " -n 1 -r
        echo ""
    else
        REPLY="2"
    fi
    
    case $REPLY in
        1) setup_cloudflare_dns ;;
        2) setup_manual_dns ;;
        *) echo -e "${RED}[ERROR]${NC} Invalid option"; exit 1 ;;
    esac
    
    save_state "letsencrypt"
}

setup_cloudflare_dns() {
    echo -e "\n${CYAN}=== Cloudflare DNS Setup ===${NC}"
    echo ""
    echo -e "${YELLOW}You need a Cloudflare API Token${NC}"
    echo "Create at: https://dash.cloudflare.com/profile/api-tokens"
    echo ""
    
    read -p "Enter Cloudflare API Token: " CF_API_TOKEN
    
    if [ -z "$CF_API_TOKEN" ]; then
        echo -e "${RED}[ERROR]${NC} Token required"
        exit 1
    fi
    
    mkdir -p /root/.secrets/certbot
    cat > /root/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
    chmod 600 /root/.secrets/certbot/cloudflare.ini
    
    echo -e "\n${CYAN}Requesting wildcard certificate...${NC}"
    
    certbot certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 60 \
        -d "$WILDCARD_DOMAIN" \
        --email "$EMAIL" \
        --agree-tos \
        --non-interactive
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[OK]${NC} Certificate obtained"
    else
        echo -e "${RED}[ERROR]${NC} Certificate failed"
        exit 1
    fi
}

setup_manual_dns() {
    echo -e "\n${CYAN}=== Manual DNS Setup ===${NC}"
    
    certbot certonly \
        --manual \
        --preferred-challenges dns \
        -d "$WILDCARD_DOMAIN" \
        --email "$EMAIL" \
        --agree-tos
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERROR]${NC} Certificate failed"
        exit 1
    fi
}

setup_cert_renewal() {
    if is_step_complete "cert_renewal"; then
        echo -e "${YELLOW}[SKIP]${NC} Renewal configured"
        return 0
    fi
    
    echo -e "\n${CYAN}Setting up auto-renewal...${NC}"
    
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
systemctl reload xcp-management 2>/dev/null || true
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload.sh
    
    echo -e "${GREEN}[OK]${NC} Renewal configured"
    save_state "cert_renewal"
}

export_agent_certificate() {
    if is_step_complete "cert_export"; then
        echo -e "${YELLOW}[SKIP]${NC} Certificates exported"
        return 0
    fi
    
    echo -e "\n${CYAN}Exporting certificates...${NC}"
    
    CERT_DIR="$INSTALL_DIR/certificates"
    mkdir -p "$CERT_DIR"
    
    cp /etc/letsencrypt/live/$BASE_DOMAIN/fullchain.pem "$CERT_DIR/agent-cert.pem"
    cp /etc/letsencrypt/live/$BASE_DOMAIN/privkey.pem "$CERT_DIR/agent-key.pem"
    cp /etc/letsencrypt/live/$BASE_DOMAIN/cert.pem "$CERT_DIR/server-cert.pem"
    
    openssl pkcs12 -export \
        -out "$CERT_DIR/agent-cert.pfx" \
        -inkey /etc/letsencrypt/live/$BASE_DOMAIN/privkey.pem \
        -in /etc/letsencrypt/live/$BASE_DOMAIN/cert.pem \
        -certfile /etc/letsencrypt/live/$BASE_DOMAIN/chain.pem \
        -password pass:
    
    chmod 644 "$CERT_DIR"/*
    
    echo -e "${GREEN}[OK]${NC} Certificates exported"
    save_state "cert_export"
}

configure_nginx_site() {
    if is_step_complete "nginx_site"; then
        echo -e "${YELLOW}[SKIP]${NC} Nginx site configured"
        return 0
    fi
    
    echo -e "\n${CYAN}Configuring Nginx site...${NC}"
    
    # Create directories
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    mkdir -p /var/www/xcp-management
    mkdir -p /var/www/certbot
    
    cat > /etc/nginx/sites-available/xcp-management <<EOF
limit_req_zone \$binary_remote_addr zone=api_limit:10m rate=10r/s;

upstream xcp_backend {
    server 127.0.0.1:5000;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    
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
    server_name $DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$BASE_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$BASE_DOMAIN/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    
    add_header Strict-Transport-Security "max-age=31536000" always;
    
    location / {
        proxy_pass http://xcp_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    
    ln -sf /etc/nginx/sites-available/xcp-management /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    nginx -t && systemctl reload nginx
    
    echo -e "${GREEN}[OK]${NC} Nginx site configured"
    save_state "nginx_site"
}

create_app_user() {
    if is_step_complete "app_user"; then
        echo -e "${YELLOW}[SKIP]${NC} User exists"
        return 0
    fi
    
    echo -e "\n${CYAN}Creating app user...${NC}"
    
    if ! id "$WEB_USER" &>/dev/null; then
        useradd --system --create-home --shell /bin/false $WEB_USER
    fi
    
    mkdir -p /home/$WEB_USER
    chown $WEB_USER:$WEB_USER /home/$WEB_USER
    chmod 755 /home/$WEB_USER
    
    echo -e "${GREEN}[OK]${NC} User created"
    save_state "app_user"
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
    chmod 700 "$INSTALL_DIR/config"
    chmod 700 "$INSTALL_DIR/certificates"
    
    chown root:root "$CREDENTIALS_FILE" 2>/dev/null || true
    
    echo -e "${GREEN}[OK]${NC} Structure created"
    save_state "app_structure"
}

create_systemd_service() {
    if is_step_complete "systemd"; then
        echo -e "${YELLOW}[SKIP]${NC} Service exists"
        return 0
    fi
    
    echo -e "\n${CYAN}Creating service...${NC}"
    
    cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=XCP-ng VM Management Web Server
After=network.target mysql.service
Wants=network-online.target

[Service]
Type=simple
User=$WEB_USER
WorkingDirectory=$INSTALL_DIR/bin
ExecStart=/usr/bin/dotnet $INSTALL_DIR/bin/XcpManagement.dll
Restart=always
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=xcp-management
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
Environment=DOTNET_CLI_HOME=/opt/xcp-management
Environment=DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1
Environment=HOME=/opt/xcp-management
EnvironmentFile=$INSTALL_DIR/config/db-password.env

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=false
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    
    echo -e "${GREEN}[OK]${NC} Service created"
    save_state "systemd"
}

create_deploy_script() {
    if is_step_complete "deploy_script"; then
        echo -e "${YELLOW}[SKIP]${NC} Deploy script exists"
        return 0
    fi
    
    echo -e "\n${CYAN}Creating deploy script...${NC}"
    
    cat > "$INSTALL_DIR/deploy.sh" <<'EOF'
#!/bin/bash
set -e

INSTALL_DIR="/opt/xcp-management"
SERVICE_NAME="xcp-management"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

SOURCE_DIR=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --source) SOURCE_DIR="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -z "$SOURCE_DIR" ] || [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Invalid source directory"
    exit 1
fi

echo "Backing up..."
mkdir -p "$INSTALL_DIR/backups"
tar -czf "$INSTALL_DIR/backups/backup-$(date +%Y%m%d-%H%M%S).tar.gz" \
    -C "$INSTALL_DIR" bin config 2>/dev/null || true

echo "Stopping service..."
systemctl stop $SERVICE_NAME 2>/dev/null || true

echo "Deploying..."
mkdir -p "$INSTALL_DIR/bin"
rm -rf "$INSTALL_DIR/bin"/*
cp -r "$SOURCE_DIR"/* "$INSTALL_DIR/bin/"

chown -R xcp-web:xcp-web "$INSTALL_DIR/bin"
chmod 750 "$INSTALL_DIR/bin"

if [ -f "$INSTALL_DIR/config/appsettings.Production.json" ]; then
    cp "$INSTALL_DIR/config/appsettings.Production.json" \
       "$INSTALL_DIR/bin/appsettings.Production.json"
fi

echo "Starting service..."
systemctl start $SERVICE_NAME

sleep 3
if systemctl is-active --quiet $SERVICE_NAME; then
    echo "SUCCESS: Service running"
else
    echo "ERROR: Service failed"
    journalctl -u $SERVICE_NAME -n 20
    exit 1
fi
EOF
    
    chmod +x "$INSTALL_DIR/deploy.sh"
    
    echo -e "${GREEN}[OK]${NC} Deploy script created"
    save_state "deploy_script"
}

create_initial_config() {
    if is_step_complete "config"; then
        echo -e "${YELLOW}[SKIP]${NC} Config exists"
        return 0
    fi
    
    echo -e "\n${CYAN}Creating config...${NC}"
    
    JWT_SECRET=$(openssl rand -base64 32)
    API_KEY=$(openssl rand -hex 32)
    
    cat > "$INSTALL_DIR/config/appsettings.Production.json" <<EOF
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "AllowedHosts": "*",
  "Kestrel": {
    "Endpoints": {
      "Http": {
        "Url": "http://127.0.0.1:5000"
      }
    }
  },
  "ConnectionStrings": {
    "DefaultConnection": "Server=localhost;Database=$DB_NAME;User=$DB_USER;SslMode=Preferred;"
  },
  "Security": {
    "JwtSecret": "$JWT_SECRET",
    "JwtIssuer": "https://$DOMAIN",
    "JwtAudience": "https://$DOMAIN",
    "ApiKey": "$API_KEY"
  },
  "Certificates": {
    "AgentCertificatePath": "$INSTALL_DIR/certificates/agent-cert.pem",
    "AgentKeyPath": "$INSTALL_DIR/certificates/agent-key.pem",
    "CACertificatePath": "$INSTALL_DIR/certificates/server-cert.pem"
  },
  "XcpConfig": {
    "DefaultHosts": []
  }
}
EOF
    
    chown $WEB_USER:$WEB_USER "$INSTALL_DIR/config/appsettings.Production.json"
    chmod 600 "$INSTALL_DIR/config/appsettings.Production.json"
    
    mkdir -p "$INSTALL_DIR/config"
    cat > "$INSTALL_DIR/config/db-password.env" <<EOF
DB_PASSWORD=$DB_APP_PASSWORD
EOF
    chown $WEB_USER:$WEB_USER "$INSTALL_DIR/config/db-password.env"
    chmod 600 "$INSTALL_DIR/config/db-password.env"
    
    echo -e "${GREEN}[OK]${NC} Config created"
    save_state "config"
}

verify_installation() {
    echo -e "\n${CYAN}=== Verifying Installation ===${NC}\n"
    
    local all_ok=true
    
    # Check MySQL
    if systemctl is-active --quiet mysql; then
        echo -e "${GREEN}✓${NC} MySQL is running"
    else
        echo -e "${RED}✗${NC} MySQL is NOT running"
        all_ok=false
    fi
    
    # Check Nginx
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}✓${NC} Nginx is running"
    else
        echo -e "${RED}✗${NC} Nginx is NOT running"
        all_ok=false
    fi
    
    # Check certificate
    if [ -d "/etc/letsencrypt/live/$BASE_DOMAIN" ]; then
        echo -e "${GREEN}✓${NC} SSL certificate exists"
    else
        echo -e "${YELLOW}!${NC} SSL certificate not found (skipped or failed)"
    fi
    
    # Check database
    if mysql -e "USE $DB_NAME;" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Database exists"
    else
        echo -e "${RED}✗${NC} Database NOT found"
        all_ok=false
    fi
    
    # Check structure
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${GREEN}✓${NC} Installation directory exists"
    else
        echo -e "${RED}✗${NC} Installation directory NOT found"
        all_ok=false
    fi
    
    if [ "$all_ok" = true ]; then
        echo -e "\n${GREEN}All infrastructure checks passed!${NC}"
        return 0
    else
        echo -e "\n${RED}Some infrastructure checks failed!${NC}"
        return 1
    fi
}

display_summary() {
    echo -e "\n${GREEN}=== Installation Complete ===${NC}\n"
    
    echo "Domain:           $DOMAIN"
    echo "Certificate:      $BASE_DOMAIN (wildcard)"
    echo "Database:         $DB_NAME (Encrypted)"
    echo "Install Dir:      $INSTALL_DIR"
    echo "Credentials:      $CREDENTIALS_FILE"
    echo "Certificates:     $INSTALL_DIR/certificates/"
    
    echo -e "\n${CYAN}Database Tables Created:${NC}"
    echo "  ✓ RegisteredAgents"
    echo "  ✓ AgentJobs"
    echo "  ✓ HypervisorJobs"
    echo "  ✓ XcpHosts"
    echo "  ✓ JobSchedules"
    echo "  ✓ AuditLog"
    echo "  ✓ Users"
    
    echo -e "\n${CYAN}Next Steps:${NC}"
    echo "1. Build application:"
    echo "   dotnet publish -c Release -r linux-x64 --self-contained false -o ./publish"
    echo ""
    echo "2. Deploy:"
    echo "   $INSTALL_DIR/deploy.sh --source /path/to/publish"
    echo ""
    echo "3. Access:"
    echo "   https://$DOMAIN/"
    echo ""
    echo "4. Default Login:"
    echo "   Username: admin"
    echo "   Password: Admin123!"
    echo "   (Change immediately after first login!)"
    
    echo -e "\n${CYAN}Useful Commands:${NC}"
    echo "  View logs:      journalctl -u $SERVICE_NAME -f"
    echo "  Service status: systemctl status $SERVICE_NAME"
    echo "  Nginx status:   systemctl status nginx"
    echo "  MySQL access:   mysql (uses /root/.my.cnf)"
}

main() {
    detect_os
    
    if [ "$RESUME" = true ]; then
        if [ ! -f "$STATE_FILE" ]; then
            echo -e "${YELLOW}[INFO]${NC} No state found, starting fresh"
            RESUME=false
        else
            echo -e "${GREEN}[RESUME]${NC} From: $(cat $STATE_FILE)"
        fi
    fi
    
    if [ "$CERT_ONLY" = true ]; then
        prompt_config
        install_certbot
        setup_letsencrypt
        echo -e "\n${GREEN}Certificate complete!${NC}"
        exit 0
    fi
    
    prompt_config
    
    echo -e "\n${CYAN}Starting installation...${NC}"
    
    install_dependencies
    install_dotnet
    install_nginx_base
    create_nginx_config
    install_mysql_server
    configure_mysql_database
    create_database_schema
    
    if [ "$SKIP_CERT" = false ]; then
        install_certbot
        setup_letsencrypt
        setup_cert_renewal
        export_agent_certificate
        configure_nginx_site
    fi
    
    create_app_user
    create_app_structure
    create_systemd_service
    create_deploy_script
    create_initial_config
    
    verify_installation
    
    save_state "complete"
    rm -f "$STATE_FILE"
    
    display_summary
}

main