#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install XCP-ng VM Management Agent
.DESCRIPTION
    Installs the agent as a Windows service using native SC command
    Checks and optionally installs missing dependencies
.NOTES
    Version: 1.0.3
    Author: Baikes
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ServerUrl,
    
    [string]$InstallPath = "C:\Program Files\XcpVmAgent",
    
    [string]$ServiceAccount,
    
    [string]$ServicePassword,
    
    [string]$CertificateThumbprint,
    
    [switch]$Force,
    
    [switch]$SkipDependencyInstall
)

$script:Version = "1.0.3"

function Install-PowerShellCore {
    <#
    .SYNOPSIS
        Download and install PowerShell Core
    #>
    [CmdletBinding()]
    param()
    
    Write-Host "`nInstalling PowerShell Core..." -ForegroundColor Cyan
    
    try {
        # Detect architecture
        $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
        
        # Get latest release info from GitHub
        Write-Host "  Fetching latest PowerShell release information..." -ForegroundColor Gray
        $releaseUrl = "https://api.github.com/repos/PowerShell/PowerShell/releases/latest"
        $release = Invoke-RestMethod -Uri $releaseUrl -UseBasicParsing
        
        # Find the appropriate MSI installer
        $asset = $release.assets | Where-Object { 
            $_.name -like "PowerShell-*-win-$arch.msi" 
        } | Select-Object -First 1
        
        if (-not $asset) {
            throw "Could not find PowerShell installer for $arch architecture"
        }
        
        Write-Host "  Found: $($asset.name)" -ForegroundColor Gray
        
        # Download installer
        $installerPath = Join-Path $env:TEMP $asset.name
        Write-Host "  Downloading to: $installerPath" -ForegroundColor Gray
        
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath -UseBasicParsing
        $ProgressPreference = 'Continue'
        
        Write-Host "  Download complete" -ForegroundColor Green
        
        # Install
        Write-Host "  Installing PowerShell Core (this may take a few minutes)..." -ForegroundColor Gray
        $installArgs = @(
            '/i'
            "`"$installerPath`""
            '/quiet'
            '/norestart'
            'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1'
            'ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1'
            'ENABLE_PSREMOTING=1'
            'REGISTER_MANIFEST=1'
        )
        
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $installArgs -Wait -PassThru
        
        # Clean up
        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
        
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            Write-Host "  [OK] PowerShell Core installed successfully" -ForegroundColor Green
            
            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            
            return $true
        }
        else {
            Write-Host "  [ERROR] Installation failed with exit code: $($process.ExitCode)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "  [ERROR] Failed to install PowerShell Core: $_" -ForegroundColor Red
        return $false
    }
}

function Install-XenTools {
    <#
    .SYNOPSIS
        Provide instructions for installing XenServer/XCP-ng guest tools
    #>
    [CmdletBinding()]
    param()
    
    Write-Host "`n[INFO] XenServer/XCP-ng Guest Tools Installation" -ForegroundColor Cyan
    Write-Host "Guest tools must be installed manually from the XCP-ng ISO." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Installation steps:" -ForegroundColor Cyan
    Write-Host "  1. In XCP-ng Center or Xen Orchestra, mount the guest tools ISO to this VM" -ForegroundColor Gray
    Write-Host "  2. Open the mounted CD/DVD drive in Windows Explorer" -ForegroundColor Gray
    Write-Host "  3. Run the installer appropriate for your Windows version" -ForegroundColor Gray
    Write-Host "  4. Reboot after installation" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Alternative: Download from https://xcp-ng.org/" -ForegroundColor Gray
    Write-Host ""
    
    $response = Read-Host "Have you installed the XenServer/XCP-ng guest tools? (Y/N)"
    return ($response -eq 'Y' -or $response -eq 'y')
}

function Test-Prerequisites {
    <#
    .SYNOPSIS
        Check for required dependencies and offer to install missing ones
    #>
    [CmdletBinding()]
    param()
    
    Write-Host "`nChecking prerequisites..." -ForegroundColor Cyan
    
    $allMet = $true
    $canAutoInstall = @()
    $manualInstall = @()
    $warnings = @()
    
    # Check PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host "  [ERROR] PowerShell 5.1 or higher required (Current: $($PSVersionTable.PSVersion))" -ForegroundColor Red
        $manualInstall += "PowerShell 5.1 or higher - this Windows version may be too old"
        $allMet = $false
    }
    else {
        Write-Host "  [OK] PowerShell version: $($PSVersionTable.PSVersion)" -ForegroundColor Green
    }
    
    # Check if running as Administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "  [ERROR] Must run as Administrator" -ForegroundColor Red
        $manualInstall += "Administrator privileges - re-run this script as Administrator"
        $allMet = $false
    }
    else {
        Write-Host "  [OK] Running as Administrator" -ForegroundColor Green
    }
    
    # Check for PowerShell Core (pwsh) - optional but recommended
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ($pwshPath) {
        Write-Host "  [OK] PowerShell Core (pwsh) found: $pwshPath" -ForegroundColor Green
    }
    else {
        Write-Host "  [WARNING] PowerShell Core (pwsh) not found" -ForegroundColor Yellow
        $canAutoInstall += @{
            Name = "PowerShell Core"
            Description = "Recommended for better performance and modern features"
            InstallFunction = { Install-PowerShellCore }
        }
    }
    
    # Check Storage module
    if (Get-Module -ListAvailable -Name Storage) {
        Write-Host "  [OK] Storage module available" -ForegroundColor Green
    }
    else {
        Write-Host "  [ERROR] Storage module not available" -ForegroundColor Red
        $manualInstall += "Storage module (built into Windows Server 2012+ and Windows 8+)"
        $manualInstall += "  Your Windows version may be too old for this agent"
        $allMet = $false
    }
    
    # Check required disk management cmdlets
    $requiredCmdlets = @(
        'Get-Disk',
        'Update-Disk',
        'Get-Partition',
        'Resize-Partition',
        'Initialize-Disk',
        'New-Partition',
        'Format-Volume',
        'Get-PartitionSupportedSize'
    )
    
    $missingCmdlets = @()
    foreach ($cmdlet in $requiredCmdlets) {
        if (-not (Get-Command $cmdlet -ErrorAction SilentlyContinue)) {
            $missingCmdlets += $cmdlet
        }
    }
    
    if ($missingCmdlets.Count -gt 0) {
        Write-Host "  [ERROR] Missing required cmdlets: $($missingCmdlets -join ', ')" -ForegroundColor Red
        $manualInstall += "Storage module cmdlets (upgrade to Windows Server 2012+ or Windows 8+)"
        $allMet = $false
    }
    else {
        Write-Host "  [OK] All required disk management cmdlets available" -ForegroundColor Green
    }
    
    # Check network connectivity to server
    try {
        $serverUri = [System.Uri]$ServerUrl
        Write-Host "  Testing connection to $($serverUri.Host):$($serverUri.Port)..." -ForegroundColor Gray
        
        $testConnection = Test-NetConnection -ComputerName $serverUri.Host -Port $serverUri.Port -WarningAction SilentlyContinue -ErrorAction Stop
        if ($testConnection.TcpTestSucceeded) {
            Write-Host "  [OK] Can reach management server" -ForegroundColor Green
        }
        else {
            Write-Host "  [WARNING] Cannot reach management server" -ForegroundColor Yellow
            $warnings += "Cannot reach management server at $ServerUrl"
            $warnings += "  Ensure firewall allows outbound HTTPS and server is accessible"
        }
    }
    catch {
        Write-Host "  [WARNING] Cannot test connection: $_" -ForegroundColor Yellow
        $warnings += "Unable to test connection to management server"
    }
    
    # Check for XenServer/XCP-ng guest tools
    $xenToolsPath = 'HKLM:\SOFTWARE\Citrix\XenTools'
    if (Test-Path $xenToolsPath) {
        try {
            $xenVersion = (Get-ItemProperty -Path $xenToolsPath -ErrorAction SilentlyContinue).MajorVersion
            Write-Host "  [OK] XenServer/XCP-ng guest tools detected (Version: $xenVersion)" -ForegroundColor Green
        }
        catch {
            Write-Host "  [OK] XenServer/XCP-ng guest tools detected" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  [WARNING] XenServer/XCP-ng guest tools not detected" -ForegroundColor Yellow
        $warnings += "XenServer/XCP-ng guest tools not installed"
        $warnings += "  Agent may not be able to determine VM UUID reliably"
        
        # Offer to provide installation instructions
        if (-not $SkipDependencyInstall) {
            $canAutoInstall += @{
                Name = "XenServer/XCP-ng Guest Tools"
                Description = "Required for reliable VM UUID detection"
                InstallFunction = { Install-XenTools }
            }
        }
    }
    
    # Check if service account is valid (if specified)
    if ($ServiceAccount -and $ServiceAccount -ne "NT AUTHORITY\SYSTEM" -and $ServiceAccount -ne "LocalSystem") {
        try {
            $account = New-Object System.Security.Principal.NTAccount($ServiceAccount)
            $sid = $account.Translate([System.Security.Principal.SecurityIdentifier])
            Write-Host "  [OK] Service account '$ServiceAccount' is valid" -ForegroundColor Green
        }
        catch {
            Write-Host "  [ERROR] Invalid service account: $ServiceAccount" -ForegroundColor Red
            $manualInstall += "Valid service account: $ServiceAccount"
            $allMet = $false
        }
    }
    
    # Handle auto-installable dependencies
    if ($canAutoInstall.Count -gt 0 -and -not $SkipDependencyInstall) {
        Write-Host "`n[INFO] Optional components can be installed automatically:" -ForegroundColor Cyan
        
        foreach ($component in $canAutoInstall) {
            Write-Host "`n  Component: $($component.Name)" -ForegroundColor Yellow
            Write-Host "  Description: $($component.Description)" -ForegroundColor Gray
            
            $response = Read-Host "  Install $($component.Name)? (Y/N)"
            
            if ($response -eq 'Y' -or $response -eq 'y') {
                $installResult = & $component.InstallFunction
                
                if (-not $installResult) {
                    Write-Host "  Installation failed or was declined" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "  Skipped" -ForegroundColor Gray
            }
        }
    }
    
    # Display final results
    if ($manualInstall.Count -gt 0) {
        Write-Host "`n[FAILED] Prerequisites check failed - manual intervention required:" -ForegroundColor Red
        foreach ($item in $manualInstall) {
            Write-Host "  - $item" -ForegroundColor Red
        }
        $allMet = $false
    }
    
    if ($warnings.Count -gt 0) {
        Write-Host "`nWarnings:" -ForegroundColor Yellow
        foreach ($warning in $warnings) {
            Write-Host "  - $warning" -ForegroundColor Yellow
        }
        
        if (-not $Force -and $allMet) {
            Write-Host "`nInstallation can continue, but some features may not work correctly." -ForegroundColor Yellow
            $response = Read-Host "Continue with installation? (Y/N)"
            if ($response -ne 'Y' -and $response -ne 'y') {
                Write-Host "Installation cancelled by user." -ForegroundColor Yellow
                return $false
            }
        }
    }
    
    if ($allMet) {
        Write-Host "`n[OK] All required prerequisites met!" -ForegroundColor Green
    }
    
    return $allMet
}

function Install-Agent {
    [CmdletBinding()]
    param()
    
    Write-Host "`n=== XCP-ng VM Agent Installer v$script:Version ===" -ForegroundColor Cyan
    
    # Check prerequisites BEFORE doing anything
    if (-not (Test-Prerequisites)) {
        Write-Host "`nInstallation aborted due to missing prerequisites." -ForegroundColor Red
        Write-Host "Please resolve the issues above and try again." -ForegroundColor Red
        return $false
    }
    
    # Create installation directory
    Write-Host "`nCreating installation directory: $InstallPath" -ForegroundColor Cyan
    if (Test-Path $InstallPath) {
        Write-Host "  Directory already exists, will overwrite files" -ForegroundColor Yellow
    }
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    
    # Copy agent files
    Write-Host "Copying agent files..." -ForegroundColor Cyan
    $sourceFiles = @(
        "$PSScriptRoot\VmAgent.ps1"
    )
    
    $allFilesFound = $true
    foreach ($file in $sourceFiles) {
        if (Test-Path $file) {
            Copy-Item -Path $file -Destination $InstallPath -Force
            Write-Host "  Copied: $(Split-Path $file -Leaf)" -ForegroundColor Gray
        }
        else {
            Write-Host "  [ERROR] Source file not found: $file" -ForegroundColor Red
            $allFilesFound = $false
        }
    }
    
    if (-not $allFilesFound) {
        Write-Host "`nInstallation failed: Required source files not found" -ForegroundColor Red
        return $false
    }
    
    # Copy modules if they exist
    if (Test-Path "$PSScriptRoot\Modules") {
        Copy-Item -Path "$PSScriptRoot\Modules" -Destination $InstallPath -Recurse -Force
        Write-Host "  Copied: Modules directory" -ForegroundColor Gray
    }
    
    # Create config file
    Write-Host "Creating configuration file..." -ForegroundColor Cyan
    $config = @{
        ServerUrl = $ServerUrl
        CheckInInterval = 30
        CertificateThumbprint = $CertificateThumbprint
    }
    
    $configJson = $config | ConvertTo-Json -Depth 3
    $configPath = Join-Path $InstallPath "agent-config.json"
    $configJson | Out-File -FilePath $configPath -Encoding UTF8
    Write-Host "  Configuration saved to: $configPath" -ForegroundColor Gray
    
    # Create logs directory
    $logsPath = Join-Path $InstallPath "Logs"
    New-Item -ItemType Directory -Path $logsPath -Force | Out-Null
    Write-Host "  Created logs directory: $logsPath" -ForegroundColor Gray
    
    # Register Event Log source
    Write-Host "Registering Event Log source..." -ForegroundColor Cyan
    try {
        if (-not ([System.Diagnostics.EventLog]::SourceExists('XcpVmAgent'))) {
            New-EventLog -LogName 'Application' -Source 'XcpVmAgent'
            Write-Host "  Event Log source 'XcpVmAgent' registered" -ForegroundColor Gray
        }
        else {
            Write-Host "  Event Log source 'XcpVmAgent' already exists" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "  [WARNING] Failed to register Event Log source: $_" -ForegroundColor Yellow
    }
    
    # Install Windows Service using SC command
    Write-Host "`nInstalling Windows Service..." -ForegroundColor Cyan
    
    $serviceName = "XcpVmAgent"
    $serviceDisplayName = "XCP-ng VM Agent"
    $serviceDescription = "Agent for XCP-ng VM management operations. Pulls jobs from central management server via HTTPS."
    
    # Stop and delete service if it already exists
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existingService) {
        Write-Host "  Existing service found. Stopping and removing..." -ForegroundColor Yellow
        if ($existingService.Status -eq 'Running') {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        & sc.exe delete $serviceName | Out-Null
        Start-Sleep -Seconds 2
    }
    
    # Determine which PowerShell to use
    $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshPath) {
        $pwshPath = (Get-Command powershell -ErrorAction SilentlyContinue).Source
        Write-Host "  Using Windows PowerShell: $pwshPath" -ForegroundColor Gray
    }
    else {
        Write-Host "  Using PowerShell Core: $pwshPath" -ForegroundColor Gray
    }
    
    $agentScript = Join-Path $InstallPath "VmAgent.ps1"
    $binPath = "`"$pwshPath`" -NoProfile -ExecutionPolicy Bypass -File `"$agentScript`""
    
    # Create service
    Write-Host "  Creating service: $serviceName" -ForegroundColor Gray
    
    if ($ServiceAccount -and $ServicePassword) {
        $result = & sc.exe create $serviceName binPath= $binPath start= auto DisplayName= $serviceDisplayName obj= $ServiceAccount password= $ServicePassword
    }
    elseif ($ServiceAccount) {
        $result = & sc.exe create $serviceName binPath= $binPath start= auto DisplayName= $serviceDisplayName obj= $ServiceAccount
    }
    else {
        $result = & sc.exe create $serviceName binPath= $binPath start= auto DisplayName= $serviceDisplayName
    }
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] Failed to create service (exit code: $LASTEXITCODE)" -ForegroundColor Red
        Write-Host "  Output: $($result -join "`n")" -ForegroundColor Red
        return $false
    }
    
    Write-Host "  Service created successfully" -ForegroundColor Green
    
    # Set service description
    & sc.exe description $serviceName $serviceDescription | Out-Null
    
    # Configure service recovery options
    Write-Host "  Configuring service recovery options..." -ForegroundColor Gray
    & sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
    & sc.exe config $serviceName start= delayed-auto | Out-Null
    
    # Grant service account permissions if specified
    if ($ServiceAccount -and $ServiceAccount -ne "NT AUTHORITY\SYSTEM" -and $ServiceAccount -ne "LocalSystem") {
        Write-Host "  Granting permissions to service account..." -ForegroundColor Gray
        try {
            $acl = Get-Acl $InstallPath
            $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $ServiceAccount,
                "FullControl",
                "ContainerInherit,ObjectInherit",
                "None",
                "Allow"
            )
            $acl.SetAccessRule($accessRule)
            Set-Acl -Path $InstallPath -AclObject $acl
            Write-Host "  Permissions granted successfully" -ForegroundColor Gray
        }
        catch {
            Write-Host "  [WARNING] Failed to set permissions: $_" -ForegroundColor Yellow
        }
    }
    
    # Start service
    Write-Host "`nStarting service..." -ForegroundColor Cyan
    try {
        Start-Service -Name $serviceName -ErrorAction Stop
        Write-Host "  Service start command issued" -ForegroundColor Gray
    }
    catch {
        Write-Host "  [ERROR] Failed to start service: $_" -ForegroundColor Red
        Write-Host "  Check Event Viewer or logs for details" -ForegroundColor Yellow
        return $false
    }
    
    # Verify service is running
    Start-Sleep -Seconds 5
    $service = Get-Service -Name $serviceName
    
    if ($service.Status -eq 'Running') {
        Write-Host "  [OK] Service started successfully" -ForegroundColor Green
    }
    else {
        Write-Host "  [WARNING] Service status: $($service.Status)" -ForegroundColor Yellow
        Write-Host "  The service may still be starting. Check status with: Get-Service $serviceName" -ForegroundColor Yellow
    }
    
    # Display installation summary
    Write-Host "`n=== Installation Complete ===" -ForegroundColor Green
    Write-Host "Service Name:      $serviceName" -ForegroundColor Gray
    Write-Host "Display Name:      $serviceDisplayName" -ForegroundColor Gray
    Write-Host "Install Path:      $InstallPath" -ForegroundColor Gray
    Write-Host "Log Path:          $logsPath" -ForegroundColor Gray
    Write-Host "Config Path:       $configPath" -ForegroundColor Gray
    Write-Host "Server URL:        $ServerUrl" -ForegroundColor Gray
    Write-Host "Service Account:   $(if ($ServiceAccount) { $ServiceAccount } else { 'LocalSystem' })" -ForegroundColor Gray
    Write-Host "Current Status:    $($service.Status)" -ForegroundColor $(if ($service.Status -eq 'Running') { 'Green' } else { 'Yellow' })
    
    Write-Host "`nManagement Commands:" -ForegroundColor Cyan
    Write-Host "  View service:      Get-Service $serviceName" -ForegroundColor Gray
    Write-Host "  Start service:     Start-Service $serviceName" -ForegroundColor Gray
    Write-Host "  Stop service:      Stop-Service $serviceName" -ForegroundColor Gray
    Write-Host "  Restart service:   Restart-Service $serviceName" -ForegroundColor Gray
    Write-Host "  View logs:         Get-Content '$logsPath\VmAgent_*.log' -Tail 50 -Wait" -ForegroundColor Gray
    Write-Host "  View config:       Get-Content '$configPath'" -ForegroundColor Gray
    Write-Host "  Uninstall:         sc.exe stop $serviceName; sc.exe delete $serviceName; Remove-Item '$InstallPath' -Recurse -Force" -ForegroundColor Gray
    
    return $true
}

# Run installation
$success = Install-Agent

if (-not $success) {
    Write-Host "`nInstallation failed. Please check the errors above and resolve before retrying." -ForegroundColor Red
    exit 1
}

Write-Host "`nThe agent is now running and will check in with the management server every 30 seconds." -ForegroundColor Green
Write-Host "Monitor the first few check-ins in the logs to ensure successful connection." -ForegroundColor Cyan

exit 0