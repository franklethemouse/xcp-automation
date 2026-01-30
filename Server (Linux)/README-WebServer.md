# XCP-ng VM Management Web Server

Version 1.0.0

## Overview

The XCP-ng VM Management Web Server is the central control point for managing VMs across your XCP-ng infrastructure. It provides a REST API for VM operations and coordinates with agents running on individual VMs.

## Features

- **Centralized VM Management** - Single API to manage all VMs
- **Agent Coordination** - Pull-based agent architecture
- **Wildcard SSL Certificates** - Let's Encrypt integration for domain
- **Job Queue System** - Asynchronous operation processing
- **SQL Server Database** - Persistent storage for jobs and agent registry
- **Nginx Reverse Proxy** - Production-ready web server
- **Easy Updates** - Simple deployment and update workflow

## System Requirements

- Linux server (Ubuntu 20.04+, RHEL 8+, Debian 11+)
- .NET 8 SDK and Runtime
- 2+ GB RAM
- 20+ GB disk space
- Public IP or domain for Let's Encrypt
- Root access for installation

### Required Software

- .NET 8 SDK and Runtime
- Nginx
- Certbot (for Let's Encrypt)
- SQL Server or SQLite (for development)

## Installation

### Quick Install
```bash
# Full installation with Let's Encrypt
sudo ./install-webserver.sh -y
```

### Installation Options
```bash
# Skip SSL certificate setup (configure later)
sudo ./install-webserver.sh --skip-cert

# Custom domain and email
sudo ./install-webserver.sh --domain example.com --email admin@example.com

# Certificate-only setup
sudo ./install-webserver.sh --cert-only
```

### What Gets Installed

The installer will:

1. Install .NET 8 SDK and Runtime
2. Install Nginx web server
3. Install and configure Certbot for Let's Encrypt
4. Set up wildcard SSL certificate for `*.thebakkers.com.au`
5. Create application user (`xcp-web`)
6. Create directory structure in `/opt/xcp-management`
7. Configure Nginx as reverse proxy
8. Create systemd service (`xcp-management`)
9. Export certificates for agents
10. Optionally install SQL Server

## Directory Structure
```
/opt/xcp-management/
├── bin/                    # Application binaries
├── config/                 # Configuration files
│   └── appsettings.Production.json
├── logs/                   # Application logs
├── data/                   # Application data
├── certificates/           # Agent certificates
│   ├── agent-cert.pem     # Linux agent certificate
│   ├── agent-key.pem      # Linux agent key
│   ├── agent-cert.pfx     # Windows agent certificate
│   └── server-cert.pem    # CA certificate
├── backups/               # Deployment backups
└── deploy.sh              # Deployment script
```

## Configuration

Main configuration file: `/opt/xcp-management/config/appsettings.Production.json`
```json
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
    "DefaultConnection": "Server=localhost;Database=XcpManagement;User Id=xcp_user;Password=CHANGE_ME;TrustServerCertificate=true;"
  },
  "Security": {
    "JwtSecret": "auto-generated",
    "JwtIssuer": "https://thebakkers.com.au",
    "JwtAudience": "https://thebakkers.com.au",
    "ApiKey": "auto-generated"
  },
  "Certificates": {
    "AgentCertificatePath": "/opt/xcp-management/certificates/agent-cert.pem",
    "AgentKeyPath": "/opt/xcp-management/certificates/agent-key.pem",
    "CACertificatePath": "/opt/xcp-management/certificates/server-cert.pem"
  },
  "XcpConfig": {
    "DefaultHosts": []
  }
}
```

### Important Configuration Items

1. **Database Connection String** - Update with your SQL Server credentials
2. **XCP-ng Hosts** - Add your XCP-ng host details
3. **Security Settings** - Auto-generated, keep secure

## SSL Certificates

### Let's Encrypt Wildcard Certificate

The installer sets up a wildcard certificate for `*.thebakkers.com.au` that covers:
- `management.thebakkers.com.au` (API endpoint)
- Any subdomain you want to use

### DNS Providers Supported

- Cloudflare (recommended)
- AWS Route53
- Manual DNS (you add TXT records)

### Certificate Auto-Renewal

Certificates automatically renew via certbot. Test renewal:
```bash
sudo certbot renew --dry-run
```

### Agent Certificates

Certificates for agents are automatically exported to `/opt/xcp-management/certificates/`:

- **Windows agents**: `agent-cert.pfx` (PKCS12 format)
- **Linux agents**: `agent-cert.pem` + `agent-key.pem`
- **CA certificate**: `server-cert.pem` (for validation)

## Deployment

### Initial Deployment

1. Build your ASP.NET Core application:
```bash
cd /path/to/your/project
dotnet publish -c Release -o ./publish
```

2. Deploy to server:
```bash
sudo /opt/xcp-management/deploy.sh --source ./publish
```

### Update Deployment

Same process - the deploy script handles:
- Automatic backup of current version
- Service stop
- File replacement
- Configuration preservation
- Service restart
- Status verification
```bash
# Standard deployment
sudo /opt/xcp-management/deploy.sh --source ./publish

# Skip backup
sudo /opt/xcp-management/deploy.sh --source ./publish --skip-backup

# Deploy without restart (manual restart later)
sudo /opt/xcp-management/deploy.sh --source ./publish --no-restart
```

### Rollback

If a deployment fails, restore from backup:
```bash
# List backups
ls -lh /opt/xcp-management/backups/

# Rollback to specific backup
sudo systemctl stop xcp-management
sudo tar -xzf /opt/xcp-management/backups/backup-YYYYMMDD-HHMMSS.tar.gz -C /opt/xcp-management
sudo systemctl start xcp-management
```

## Service Management

### View Service Status
```bash
sudo systemctl status xcp-management
```

### Start/Stop/Restart
```bash
sudo systemctl start xcp-management
sudo systemctl stop xcp-management
sudo systemctl restart xcp-management
```

### View Logs
```bash
# Systemd journal
sudo journalctl -u xcp-management -f

# Application logs
sudo tail -f /opt/xcp-management/logs/*.log

# Recent errors
sudo journalctl -u xcp-management -p err -n 50
```

## Nginx Configuration

Nginx acts as a reverse proxy and handles:
- SSL termination
- Rate limiting (10 req/s with burst)
- Security headers
- Static file serving
- Health check endpoints

Configuration: `/etc/nginx/sites-available/xcp-management`

### Reload Nginx

After configuration changes:
```bash
sudo nginx -t                    # Test configuration
sudo systemctl reload nginx      # Reload if test passes
```

## Database

### SQL Server (Recommended for Production)

During installation, you can choose to:
1. Install SQL Server locally
2. Use existing SQL Server
3. Use SQLite (testing only)

### Create Database

If using external SQL Server:
```sql
CREATE DATABASE XcpManagement;
CREATE LOGIN xcp_user WITH PASSWORD = 'SecurePassword123!';
USE XcpManagement;
CREATE USER xcp_user FOR LOGIN xcp_user;
ALTER ROLE db_owner ADD MEMBER xcp_user;
```

Update connection string in `appsettings.Production.json`.

## Distributing Agent Certificates

After installation, distribute certificates to VMs:

### Windows VMs
```powershell
# Copy PFX certificate
scp /opt/xcp-management/certificates/agent-cert.pfx administrator@windowsvm:/temp/

# On Windows VM, import certificate
$cert = Import-PfxCertificate -FilePath "C:\temp\agent-cert.pfx" `
    -CertStoreLocation Cert:\LocalMachine\My
```

### Linux VMs
```bash
# Copy certificate and key
scp /opt/xcp-management/certificates/agent-cert.pem root@linuxvm:/etc/xcp-vm-agent/
scp /opt/xcp-management/certificates/agent-key.pem root@linuxvm:/etc/xcp-vm-agent/

# Set permissions
ssh root@linuxvm "chmod 600 /etc/xcp-vm-agent/agent-key.pem"
```

## API Endpoints

Base URL: `https://management.thebakkers.com.au/api/`

### Agent Endpoints
- `POST /api/agent/register` - Agent registration
- `POST /api/agent/checkin` - Agent check-in (get jobs)
- `POST /api/agent/job-status` - Update job status
- `POST /api/agent/job-result` - Submit job result

### Management Endpoints
- `POST /api/vm-operations/extend-partition` - Extend VM partition
- `POST /api/vm-operations/initialize-disk` - Initialize new disk
- `GET /api/vm-operations/agents` - List registered agents
- `GET /health` - Health check

## Security

### Firewall Rules

Open these ports:
- **443** - HTTPS (inbound)
- **80** - HTTP redirect (inbound)
- **5000** - Application (localhost only)
```bash
# UFW example
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

### API Authentication

Configure API keys or JWT tokens in `appsettings.Production.json`.

### Rate Limiting

Nginx is configured with:
- 10 requests/second per IP
- Burst of 20 requests
- Rate limit zone: 10MB

## Monitoring

### Health Checks
```bash
curl https://management.thebakkers.com.au/health
```

### Log Monitoring
```bash
# Watch for errors
sudo journalctl -u xcp-management -f | grep -i error

# Count requests
sudo tail -f /var/log/nginx/xcp-management-access.log | grep POST
```

### Service Status
```bash
# Check all services
sudo systemctl status xcp-management nginx
```

## Backup

### Application Backup
```bash
# Backup script creates automatic backups on each deployment
ls -lh /opt/xcp-management/backups/

# Manual backup
sudo tar -czf ~/xcp-backup-$(date +%Y%m%d).tar.gz \
    /opt/xcp-management/config \
    /opt/xcp-management/data \
    /opt/xcp-management/certificates
```

### Database Backup
```bash
# SQL Server backup
sudo /opt/mssql-tools/bin/sqlcmd -S localhost -U sa \
    -Q "BACKUP DATABASE XcpManagement TO DISK='/var/opt/mssql/backup/XcpManagement.bak'"
```

## Troubleshooting

### Service Won't Start
```bash
# Check logs
sudo journalctl -u xcp-management -n 100

# Common issues:
# - Database connection
# - Port 5000 already in use
# - Configuration file errors
# - Missing dependencies
```

### Nginx Errors
```bash
# Test configuration
sudo nginx -t

# Check error log
sudo tail -f /var/log/nginx/xcp-management-error.log
```

### Certificate Issues
```bash
# Check certificate status
sudo certbot certificates

# Renew certificates manually
sudo certbot renew

# Test renewal
sudo certbot renew --dry-run
```

### Database Connection
```bash
# Test SQL Server connection
/opt/mssql-tools/bin/sqlcmd -S localhost -U xcp_user -P password -Q "SELECT 1"
```

## Maintenance

### Update .NET Runtime
```bash
sudo apt-get update
sudo apt-get install --only-upgrade aspnetcore-runtime-8.0
sudo systemctl restart xcp-management
```

### Certificate Renewal

Automatic via cron, but can manually renew:
```bash
sudo certbot renew
sudo systemctl reload nginx
sudo systemctl reload xcp-management
```

### Clean Old Backups
```bash
# Keep only last 10 backups
cd /opt/xcp-management/backups
ls -t backup-*.tar.gz | tail -n +11 | xargs rm
```

## Support

For issues:
1. Check logs: `sudo journalctl -u xcp-management -n 100`
2. Verify configuration: `sudo cat /opt/xcp-management/config/appsettings.Production.json`
3. Test database connection
4. Check Nginx configuration: `sudo nginx -t`
5. Verify SSL certificates: `sudo certbot certificates`

## Version History

### 1.0.0 (2026-01-26)
- Initial release
- Let's Encrypt wildcard SSL support
- Agent coordination system
- Job queue implementation
- Easy deployment workflow