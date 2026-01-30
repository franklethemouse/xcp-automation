#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Uninstall XCP-ng VM Management Agent
.DESCRIPTION
    Removes the XCP-ng VM Agent service and files
.NOTES
    Version: 1.0.3
    Author: Baikes
#>

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\Program Files\XcpVmAgent",
    
    [switch]$KeepLogs,
    
    [switch]$Force
)

$script:Version = "1.0.3"
$serviceName = "XcpVmAgent"

Write-Host "`n=== XCP-ng VM Agent Uninstaller v$script:Version ===" -ForegroundColor Cyan

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] Must run as Administrator" -ForegroundColor Red
    exit 1
}

# Confirm uninstallation
if (-not $Force) {
    Write-Host "`nThis will remove the XCP-ng VM Agent from this system." -ForegroundColor Yellow
    $response = Read-Host "Continue with uninstallation? (Y/N)"
    if ($response -ne 'Y' -and $response -ne 'y') {
        Write-Host "Uninstallation cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Stop service
Write-Host "`nStopping service..." -ForegroundColor Cyan
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -eq 'Running') {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Write-Host "  Service stopped" -ForegroundColor Gray
    }
    
    # Delete service
    Write-Host "Removing service..." -ForegroundColor Cyan
    & sc.exe delete $serviceName
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Service removed" -ForegroundColor Green
    }
    else {
        Write-Host "  [WARNING] Failed to remove service" -ForegroundColor Yellow
    }
}
else {
    Write-Host "  Service not found (already removed)" -ForegroundColor Gray
}

# Remove Event Log source
Write-Host "`nRemoving Event Log source..." -ForegroundColor Cyan
try {
    if ([System.Diagnostics.EventLog]::SourceExists('XcpVmAgent')) {
        Remove-EventLog -Source 'XcpVmAgent'
        Write-Host "  Event Log source removed" -ForegroundColor Gray
    }
    else {
        Write-Host "  Event Log source not found" -ForegroundColor Gray
    }
}
catch {
    Write-Host "  [WARNING] Failed to remove Event Log source: $_" -ForegroundColor Yellow
}

# Remove installation directory
if (Test-Path $InstallPath) {
    Write-Host "`nRemoving installation directory..." -ForegroundColor Cyan
    
    if ($KeepLogs) {
        # Move logs to temp location
        $backupLogsPath = "$env:TEMP\XcpVmAgent_Logs_$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $logsPath = Join-Path $InstallPath "Logs"
        
        if (Test-Path $logsPath) {
            Write-Host "  Backing up logs to: $backupLogsPath" -ForegroundColor Gray
            Copy-Item -Path $logsPath -Destination $backupLogsPath -Recurse -Force
        }
    }
    
    try {
        Remove-Item -Path $InstallPath -Recurse -Force -ErrorAction Stop
        Write-Host "  Installation directory removed" -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERROR] Failed to remove directory: $_" -ForegroundColor Red
        Write-Host "  You may need to manually delete: $InstallPath" -ForegroundColor Yellow
    }
}
else {
    Write-Host "`nInstallation directory not found (already removed)" -ForegroundColor Gray
}

# Display summary
Write-Host "`n=== Uninstallation Complete ===" -ForegroundColor Green

if ($KeepLogs -and (Test-Path $backupLogsPath)) {
    Write-Host "`nLogs saved to: $backupLogsPath" -ForegroundColor Cyan
}

Write-Host "`nThe XCP-ng VM Agent has been removed from this system." -ForegroundColor Green

exit 0