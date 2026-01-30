# XCP-ng VM Management Agent - Linux

Version 1.0.3

## Overview

The XCP-ng VM Management Agent runs as a systemd service on your Linux VMs and executes management tasks by pulling jobs from the central management server via HTTPS.

## Features

- **Pull-based architecture** - No inbound ports required
- **Secure HTTPS communication** - SSL/TLS encrypted
- **Local execution** - Operations run with root permissions
- **Automatic retry** - Self-healing on connection failures
- **systemd integration** - Standard Linux service management
- **Detailed logging** - Both file and journal logging

## System Requirements

- Linux distribution with systemd (Ubuntu 18.04+, RHEL/CentOS 8+, Debian 10+, etc.)
- Python 3.6 or later
- Root access for installation
- Outbound HTTPS (443) access to management server

### Required Packages

- python3
- python3-pip
- python3-requests
- cloud-utils-growpart (or cloud-guest-utils)
- parted
- e2fsprogs
- xfsprogs (for XFS support)
- util-linux

### Optional Packages

- xe-guest-utilities (for reliable VM UUID detection)

## Installation

### Quick Install
```bash
# Run as root
sudo ./install-agent.sh https://management.thebakkers.com.au
```

### Installation Options
```bash
# Auto-yes to all prompts
sudo ./install-agent.sh https://management.thebakkers.com.au -y

# Skip automatic dependency installation
sudo ./install-agent.sh https://management.thebakkers.com.au --skip-deps

# Custom domain
sudo ./install-agent.sh https://custom.domain.com -y
```

### Manual Dependency Installation

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install -y python3 python3-pip cloud-guest-utils parted \
    e2fsprogs xfsprogs util-linux xe-guest-utilities
sudo pip3 install requests
```

**RHEL/CentOS/Rocky/AlmaLinux:**
```bash
sudo yum install -y python3 python3-pip cloud-utils-growpart parted \
    e2fsprogs xfsprogs util-linux
sudo pip3 install requests
```

**SUSE/openSUSE:**
```bash
sudo zypper install -y python3 python3-pip cloud-utils-growpart parted \
    e2fsprogs xfsprogs util-linux
sudo pip3 install requests
```

## Installation Components

The installer will:

1. Check for required dependencies
2. Optionally install missing dependencies
3. Create installation directory: `/opt/xcp-vm-agent`
4. Create configuration directory: `/etc/xcp-vm-agent`
5. Install systemd service: `xcp-vm-agent`
6. Enable and start the service

## Configuration

Configuration file location: `/etc/xcp-vm-agent/config.json`
```json
{
    "server_url": "https://management.thebakkers.com.au",
    "check_in_interval": 30
}
```

### Configuration Options

- **server_url** - Management server URL (required)
- **check_in_interval** - Seconds between check-ins (default: 30)
- **client_cert** - Path to client certificate for mutual TLS (optional)
- **server_cert** - Path to CA certificate for server validation (optional)

### Client Certificate Configuration

For mutual TLS authentication:
```json
{
    "server_url": "https://management.thebakkers.com.au",
    "check_in_interval": 30,
    "client_cert": [
        "/etc/xcp-vm-agent/agent-cert.pem",
        "/etc/xcp-vm-agent/agent-key.pem"
    ],
    "server_cert": "/etc/xcp-vm-agent/ca-cert.pem"
}
```

## Service Management

### View Service Status
```bash
sudo systemctl status xcp-vm-agent
```

### Start/Stop/Restart
```bash
sudo systemctl start xcp-vm-agent
sudo systemctl stop xcp-vm-agent
sudo systemctl restart xcp-vm-agent
```

### Enable/Disable Auto-start
```bash
sudo systemctl enable xcp-vm-agent
sudo systemctl disable xcp-vm-agent
```

### View Logs
```bash
# Journal logs
sudo journalctl -u xcp-vm-agent -f

# File logs
sudo tail -f /var/log/xcp-vm-agent/agent.log

# Recent errors
sudo journalctl -u xcp-vm-agent -p err -n 50
```

## Supported Operations

The agent can perform the following operations:

- **ExtendPartition** - Extend existing partitions (ext2/3/4, xfs)
- **InitializeDisk** - Initialize, partition, format, and mount new disks
- **RunScript** - Execute custom bash scripts

### Operation Examples

#### Extend Partition
Automatically extends a partition after the underlying VDI has been extended:
- Uses `growpart` to extend the partition
- Uses `resize2fs` (ext) or `xfs_growfs` (xfs) to expand filesystem

#### Initialize Disk
Complete disk initialization workflow:
1. Creates GPT partition table
2. Creates primary partition using full disk
3. Formats with specified filesystem (ext4 or xfs)
4. Creates mount point
5. Adds entry to `/etc/fstab`
6. Mounts the filesystem

## Security

### Permissions

The agent runs as root to perform disk operations. The service is configured with systemd security hardening:

- `PrivateTmp=true` - Isolated /tmp
- `ProtectSystem=strict` - Read-only system directories
- `ProtectHome=true` - Inaccessible home directories
- `NoNewPrivileges=false` - Required for disk operations
- `ReadWritePaths` - Limited to necessary directories

### Client Certificates

For mutual TLS authentication:

1. Copy certificate files to `/etc/xcp-vm-agent/`:
```bash
sudo cp agent-cert.pem /etc/xcp-vm-agent/
sudo cp agent-key.pem /etc/xcp-vm-agent/
sudo cp ca-cert.pem /etc/xcp-vm-agent/
sudo chmod 600 /etc/xcp-vm-agent/agent-key.pem
```

2. Update configuration (see Configuration section above)

3. Restart service:
```bash
sudo systemctl restart xcp-vm-agent
```

## Troubleshooting

### Service Won't Start

Check service status:
```bash
sudo systemctl status xcp-vm-agent
```

Check recent logs:
```bash
sudo journalctl -u xcp-vm-agent -n 50
```

Common issues:
- Configuration file missing or invalid JSON
- Python dependencies not installed
- Cannot reach management server
- Missing xe-guest-utilities (VM UUID detection fails)

### Agent Not Registering

1. Verify network connectivity:
```bash
curl -I https://management.thebakkers.com.au
```

2. Check if xe-guest-utilities are installed:
```bash
which xenstore-read
```

If not installed, UUID will fall back to DMI:
```bash
sudo cat /sys/class/dmi/id/product_uuid
```

3. Review agent logs:
```bash
sudo journalctl -u xcp-vm-agent -f
```

### Jobs Not Processing

- Verify service is running: `sudo systemctl is-active xcp-vm-agent`
- Check for errors in logs
- Verify time synchronization with server
- Ensure required tools are installed (growpart, parted, etc.)

### Disk Operations Failing

Verify required tools are installed:
```bash
which growpart parted mkfs.ext4 resize2fs
```

Check permissions:
```bash
sudo journalctl -u xcp-vm-agent | grep -i permission
```

## Uninstallation
```bash
# Standard uninstall
sudo ./uninstall-agent.sh

# Keep logs
sudo ./uninstall-agent.sh --keep-logs

# Force uninstall (no prompts)
sudo ./uninstall-agent.sh --force
```

Manual uninstallation:
```bash
sudo systemctl stop xcp-vm-agent
sudo systemctl disable xcp-vm-agent
sudo rm /etc/systemd/system/xcp-vm-agent.service
sudo systemctl daemon-reload
sudo rm -rf /opt/xcp-vm-agent
sudo rm -rf /etc/xcp-vm-agent
sudo rm -rf /var/log/xcp-vm-agent
```

## File Locations

- **Installation**: `/opt/xcp-vm-agent/`
- **Configuration**: `/etc/xcp-vm-agent/config.json`
- **Logs**: `/var/log/xcp-vm-agent/agent.log`
- **Systemd service**: `/etc/systemd/system/xcp-vm-agent.service`

## Supported Distributions

Tested on:
- Ubuntu 20.04, 22.04, 24.04
- Debian 10, 11, 12
- RHEL/CentOS/Rocky/AlmaLinux 8, 9
- Fedora 38+
- openSUSE Leap 15+

## Filesystem Support

- **ext2/ext3/ext4** - Full support (extend, create)
- **XFS** - Full support (extend, create)
- **Other filesystems** - Not currently supported

## XenServer/XCP-ng Guest Tools

For reliable VM UUID detection, install xe-guest-utilities:

**Ubuntu/Debian:**
```bash
# From XCP-ng ISO or repository
sudo apt-get install xe-guest-utilities
```

**Manual installation:**
1. Mount guest tools ISO in XCP-ng/Xen Orchestra
2. Mount the ISO in the guest
3. Run the installer script

## Support

For issues or questions:
- Check logs: `sudo journalctl -u xcp-vm-agent -n 100`
- Review configuration: `sudo cat /etc/xcp-vm-agent/config.json`
- Verify dependencies are installed
- Check network connectivity to management server

## Version History

### 1.0.3 (2026-01-26)
- Automatic dependency installation
- Enhanced error handling
- Improved logging
- Better UUID detection

### 1.0.2
- Dependency validation
- Installation improvements
- systemd hardening

### 1.0.1
- Initial release