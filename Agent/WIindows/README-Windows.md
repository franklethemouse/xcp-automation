# XCP-ng VM Management Agent - Windows

Version 1.0.3

## Overview

The XCP-ng VM Management Agent runs as a Windows service on your VMs and executes management tasks by pulling jobs from the central management server via HTTPS.

## Features

- **Pull-based architecture** - No inbound ports required
- **Secure HTTPS communication** - SSL/TLS encrypted
- **Local execution** - Operations run with service account permissions
- **Automatic retry** - Self-healing on connection failures
- **Windows Event Log integration** - Centralized logging
- **File logging** - Detailed operation logs

## System Requirements

- Windows Server 2012 R2 or later / Windows 8.1 or later
- PowerShell 5.1 or later (PowerShell Core recommended)
- .NET Framework 4.7.2 or later
- Administrator privileges for installation
- Outbound HTTPS (443) access to management server

## Installation

### Quick Install
```powershell
# Run as Administrator
.\Install-VmAgent.ps1 -ServerUrl "https://management.thebakkers.com.au"
```

### Custom Installation
```powershell
# With custom service account
.\Install-VmAgent.ps1 -ServerUrl "https://management.thebakkers.com.au" `
    -ServiceAccount "DOMAIN\ServiceAccount" `
    -ServicePassword "P@ssw0rd"

# With client certificate
.\Install-VmAgent.ps1 -ServerUrl "https://management.thebakkers.com.au" `
    -CertificateThumbprint "ABC123..."

# Skip optional dependencies
.\Install-VmAgent.ps1 -ServerUrl "https://management.thebakkers.com.au" `
    -SkipDependencyInstall

# Force installation (skip warnings)
.\Install-VmAgent.ps1 -ServerUrl "https://management.thebakkers.com.au" -Force
```

## Installation Components

The installer will:

1. Check for required dependencies (PowerShell, Storage module, etc.)
2. Optionally install PowerShell Core (recommended)
3. Create installation directory: `C:\Program Files\XcpVmAgent`
4. Install the agent service as `XcpVmAgent`
5. Configure automatic startup and recovery
6. Register Event Log source

## Configuration

Configuration file location: `C:\Program Files\XcpVmAgent\agent-config.json`
```json
{
    "ServerUrl": "https://management.thebakkers.com.au",
    "CheckInInterval": 30,
    "CertificateThumbprint": null
}
```

### Configuration Options

- **ServerUrl** - Management server URL (required)
- **CheckInInterval** - Seconds between check-ins (default: 30)
- **CertificateThumbprint** - Client certificate for mutual TLS (optional)

## Service Management

### View Service Status
```powershell
Get-Service XcpVmAgent
```

### Start/Stop/Restart
```powershell
Start-Service XcpVmAgent
Stop-Service XcpVmAgent
Restart-Service XcpVmAgent
```

### View Logs
```powershell
# File logs
Get-Content "C:\Program Files\XcpVmAgent\Logs\VmAgent_*.log" -Tail 50 -Wait

# Event logs
Get-EventLog -LogName Application -Source XcpVmAgent -Newest 20
```

## Supported Operations

The agent can perform the following operations:

- **ExtendPartition** - Extend existing disk partitions
- **InitializeDisk** - Initialize and format new disks
- **RunScript** - Execute PowerShell or batch scripts
- **InstallSoftware** - Install MSI, EXE, or MSU packages

## Security

### Service Account

By default, the service runs as `LocalSystem`. For enhanced security, use a dedicated service account:
```powershell
.\Install-VmAgent.ps1 -ServerUrl "https://..." `
    -ServiceAccount "DOMAIN\XcpAgent" `
    -ServicePassword "SecurePassword"
```

Required permissions for service account:
- Local Administrator (for disk operations)
- Log on as a service
- Read/write to installation directory

### Client Certificates

For mutual TLS authentication:

1. Import the certificate to `LocalMachine\My`
2. Note the certificate thumbprint
3. Install with certificate:
```powershell
.\Install-VmAgent.ps1 -ServerUrl "https://..." `
    -CertificateThumbprint "ABCDEF0123456789..."
```

## Troubleshooting

### Service Won't Start

Check Event Viewer:
```powershell
Get-EventLog -LogName Application -Source XcpVmAgent -Newest 10
```

Common issues:
- Configuration file missing or invalid JSON
- Cannot reach management server
- Missing XenTools (VM UUID detection fails)

### Agent Not Registering

1. Verify network connectivity:
```powershell
Test-NetConnection -ComputerName management.thebakkers.com.au -Port 443
```

2. Check if XenTools are installed:
```powershell
Test-Path "HKLM:\SOFTWARE\Citrix\XenTools"
```

3. Review agent logs for errors

### Jobs Not Processing

- Verify service is running
- Check logs for errors
- Ensure service account has necessary permissions
- Verify clock sync with server

## Uninstallation
```powershell
# Standard uninstall
.\Uninstall-VmAgent.ps1

# Keep logs
.\Uninstall-VmAgent.ps1 -KeepLogs

# Force uninstall (no prompts)
.\Uninstall-VmAgent.ps1 -Force
```

## File Locations

- **Installation**: `C:\Program Files\XcpVmAgent`
- **Configuration**: `C:\Program Files\XcpVmAgent\agent-config.json`
- **Logs**: `C:\Program Files\XcpVmAgent\Logs`
- **Event Log**: Application log, source "XcpVmAgent"

## Support

For issues or questions:
- Check logs for error messages
- Review Event Log entries
- Ensure all prerequisites are met
- Verify network connectivity to management server

## Version History

### 1.0.3 (2026-01-26)
- Automatic dependency installation
- Enhanced error handling
- Improved logging
- PowerShell Core support

### 1.0.2
- Native service installation (sc.exe)
- Dependency validation
- Installation improvements

### 1.0.1
- Initial release