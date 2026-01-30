#Requires -Version 5.1
<#
.SYNOPSIS
    XCP-ng VM Management Agent
.DESCRIPTION
    Agent service that runs on Windows VMs to execute local operations
    Pulls jobs from central management server via HTTPS
.NOTES
    Version: 1.0.3
    Author: Baikes
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\agent-config.json"
)

$script:AgentVersion = "1.0.3"
$script:CheckInInterval = 30
$script:LogPath = "$PSScriptRoot\Logs"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Configuration file not found: $ConfigPath"
    exit 1
}

try {
    $script:Config = Get-Content $ConfigPath | ConvertFrom-Json
}
catch {
    Write-Error "Failed to load configuration: $_"
    exit 1
}

if (-not (Test-Path $script:LogPath)) {
    New-Item -ItemType Directory -Path $script:LogPath -Force | Out-Null
}

function Start-AgentLoop {
    [CmdletBinding()]
    param()
    
    Write-AgentLog -Message "VM Agent v$script:AgentVersion starting" -Level Information
    
    $agentId = Register-Agent
    
    if (-not $agentId) {
        Write-AgentLog -Message "Failed to register with server. Will retry..." -Level Error
    }
    else {
        Write-AgentLog -Message "Registered with server. AgentId: $agentId" -Level Information
    }
    
    while ($true) {
        try {
            if (-not $agentId) {
                $agentId = Register-Agent
                if ($agentId) {
                    Write-AgentLog -Message "Successfully registered. AgentId: $agentId" -Level Information
                }
                else {
                    Start-Sleep -Seconds 60
                    continue
                }
            }
            
            $jobs = Invoke-AgentCheckIn -AgentId $agentId
            
            if ($jobs -and $jobs.Count -gt 0) {
                Write-AgentLog -Message "Received $($jobs.Count) job(s)" -Level Information
                
                foreach ($job in $jobs) {
                    Process-AgentJob -Job $job -AgentId $agentId
                }
            }
            
            Start-Sleep -Seconds $script:CheckInInterval
        }
        catch {
            Write-AgentLog -Message "Agent loop error: $_" -Level Error
            Start-Sleep -Seconds 60
        }
    }
}

function Register-Agent {
    [CmdletBinding()]
    param()
    
    try {
        $computerInfo = Get-ComputerInfo -ErrorAction SilentlyContinue
        if (-not $computerInfo) {
            $computerInfo = @{
                OsVersion = [System.Environment]::OSVersion.VersionString
                OsLastBootUpTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
            }
        }
        
        $vmUuid = Get-VmUuid
        
        if (-not $vmUuid) {
            throw "Unable to determine VM UUID. Ensure XenServer/XCP-ng guest tools are installed."
        }
        
        $registrationData = @{
            VmUuid = $vmUuid
            VmName = $env:COMPUTERNAME
            Hostname = $env:COMPUTERNAME
            OsType = 'Windows'
            OsVersion = $computerInfo.OsVersion
            AgentVersion = $script:AgentVersion
            Tags = @{
                Domain = $env:USERDNSDOMAIN
                LastBootTime = $computerInfo.OsLastBootUpTime
                Architecture = $env:PROCESSOR_ARCHITECTURE
            } | ConvertTo-Json -Compress
        }
        
        $requestParams = @{
            Uri = "$($script:Config.ServerUrl)/api/agent/register"
            Method = 'Post'
            Body = ($registrationData | ConvertTo-Json)
            ContentType = 'application/json'
            TimeoutSec = 30
        }
        
        if ($script:Config.CertificateThumbprint) {
            $cert = Get-ClientCertificate
            if ($cert) {
                $requestParams.Certificate = $cert
            }
        }
        
        $response = Invoke-RestMethod @requestParams
        
        return $response.AgentId
    }
    catch {
        Write-AgentLog -Message "Registration failed: $_" -Level Error
        return $null
    }
}

function Invoke-AgentCheckIn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AgentId
    )
    
    try {
        $checkInData = @{
            AgentId = $AgentId
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
        
        $requestParams = @{
            Uri = "$($script:Config.ServerUrl)/api/agent/checkin"
            Method = 'Post'
            Body = ($checkInData | ConvertTo-Json)
            ContentType = 'application/json'
            TimeoutSec = 30
        }
        
        if ($script:Config.CertificateThumbprint) {
            $cert = Get-ClientCertificate
            if ($cert) {
                $requestParams.Certificate = $cert
            }
        }
        
        $response = Invoke-RestMethod @requestParams
        
        return $response.Jobs
    }
    catch {
        Write-AgentLog -Message "Check-in failed: $_" -Level Error
        return $null
    }
}

function Process-AgentJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job,
        
        [Parameter(Mandatory)]
        [string]$AgentId
    )
    
    try {
        Update-JobStatus -JobId $Job.JobId -AgentId $AgentId -Status 'Running'
        
        Write-AgentLog -Message "Processing job $($Job.JobId): $($Job.JobType)" -Level Information
        
        $result = switch ($Job.JobType) {
            'ExtendPartition' {
                Invoke-ExtendPartition -Parameters ($Job.Parameters | ConvertFrom-Json)
            }
            'InitializeDisk' {
                Invoke-InitializeDisk -Parameters ($Job.Parameters | ConvertFrom-Json)
            }
            'RunScript' {
                Invoke-CustomScript -Parameters ($Job.Parameters | ConvertFrom-Json)
            }
            'InstallSoftware' {
                Invoke-SoftwareInstallation -Parameters ($Job.Parameters | ConvertFrom-Json)
            }
            default {
                @{
                    Success = $false
                    Error = "Unknown job type: $($Job.JobType)"
                }
            }
        }
        
        Submit-JobResult -JobId $Job.JobId -AgentId $AgentId -Result $result
        
        Write-AgentLog -Message "Job $($Job.JobId) completed: Success=$($result.Success)" -Level Information
    }
    catch {
        $errorResult = @{
            Success = $false
            Error = $_.Exception.Message
            StackTrace = $_.ScriptStackTrace
        }
        
        Submit-JobResult -JobId $Job.JobId -AgentId $AgentId -Result $errorResult
        Write-AgentLog -Message "Job $($Job.JobId) failed: $_" -Level Error
    }
}

function Invoke-ExtendPartition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Parameters
    )
    
    try {
        $diskNumber = $Parameters.DiskNumber
        $partitionNumber = $Parameters.PartitionNumber
        
        $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
        
        Write-AgentLog -Message "Extending partition on Disk $diskNumber, Partition $partitionNumber" -Level Information
        
        Update-Disk -Number $diskNumber
        
        $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -ErrorAction Stop
        
        $supportedSize = Get-PartitionSupportedSize -DiskNumber $diskNumber -PartitionNumber $partitionNumber
        $maxSize = $supportedSize.SizeMax
        
        if ($partition.Size -ge $maxSize) {
            return @{
                Success = $true
                Message = "Partition is already at maximum size"
                CurrentSize = [math]::Round($partition.Size / 1GB, 2)
                DriveLetter = $partition.DriveLetter
            }
        }
        
        Resize-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber -Size $maxSize
        
        $updatedPartition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partitionNumber
        
        return @{
            Success = $true
            Message = "Partition extended successfully"
            PreviousSize = [math]::Round($partition.Size / 1GB, 2)
            NewSize = [math]::Round($updatedPartition.Size / 1GB, 2)
            DriveLetter = $partition.DriveLetter
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Invoke-InitializeDisk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Parameters
    )
    
    try {
        $diskNumber = $Parameters.DiskNumber
        $driveLetter = $Parameters.DriveLetter
        $fileSystem = if ($Parameters.FileSystem) { $Parameters.FileSystem } else { 'NTFS' }
        $allocationUnitSize = if ($Parameters.AllocationUnitSize) { $Parameters.AllocationUnitSize } else { 4096 }
        $volumeLabel = if ($Parameters.VolumeLabel) { $Parameters.VolumeLabel } else { "Data" }
        
        Write-AgentLog -Message "Initializing Disk $diskNumber with drive letter $driveLetter" -Level Information
        
        $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
        
        if ($disk.PartitionStyle -ne 'RAW') {
            throw "Disk $diskNumber is already initialized with partition style: $($disk.PartitionStyle)"
        }
        
        Initialize-Disk -Number $diskNumber -PartitionStyle GPT -ErrorAction Stop
        
        $partition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -DriveLetter $driveLetter -ErrorAction Stop
        
        $formatParams = @{
            DriveLetter = $driveLetter
            FileSystem = $fileSystem
            AllocationUnitSize = $allocationUnitSize
            NewFileSystemLabel = $volumeLabel
            Confirm = $false
        }
        
        $volume = Format-Volume @formatParams -ErrorAction Stop
        
        return @{
            Success = $true
            Message = "Disk initialized and formatted successfully"
            DiskNumber = $diskNumber
            DriveLetter = $driveLetter
            FileSystem = $fileSystem
            Size = [math]::Round($volume.Size / 1GB, 2)
            VolumeLabel = $volumeLabel
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Invoke-CustomScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Parameters
    )
    
    try {
        $scriptContent = $Parameters.ScriptContent
        $scriptType = if ($Parameters.ScriptType) { $Parameters.ScriptType } else { 'PowerShell' }
        
        Write-AgentLog -Message "Executing custom $scriptType script" -Level Information
        
        $result = switch ($scriptType) {
            'PowerShell' {
                $scriptBlock = [ScriptBlock]::Create($scriptContent)
                $output = & $scriptBlock
                @{
                    Success = $true
                    Output = $output | Out-String
                }
            }
            'Batch' {
                $tempBatch = [System.IO.Path]::GetTempFileName() + '.bat'
                $scriptContent | Out-File -FilePath $tempBatch -Encoding ASCII
                $output = & cmd.exe /c $tempBatch 2>&1
                Remove-Item $tempBatch -Force
                @{
                    Success = $true
                    Output = $output | Out-String
                }
            }
            default {
                @{
                    Success = $false
                    Error = "Unsupported script type: $scriptType"
                }
            }
        }
        
        return $result
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
            StackTrace = $_.ScriptStackTrace
        }
    }
}

function Invoke-SoftwareInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Parameters
    )
    
    try {
        $installerPath = $Parameters.InstallerPath
        $installerArgs = $Parameters.InstallerArguments
        $installerType = $Parameters.InstallerType
        
        Write-AgentLog -Message "Installing software from: $installerPath" -Level Information
        
        if (-not (Test-Path $installerPath)) {
            throw "Installer not found: $installerPath"
        }
        
        $process = switch ($installerType) {
            'MSI' {
                Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$installerPath`" $installerArgs" -Wait -PassThru
            }
            'EXE' {
                Start-Process -FilePath $installerPath -ArgumentList $installerArgs -Wait -PassThru
            }
            'MSU' {
                Start-Process -FilePath 'wusa.exe' -ArgumentList "`"$installerPath`" $installerArgs" -Wait -PassThru
            }
            default {
                throw "Unsupported installer type: $installerType"
            }
        }
        
        return @{
            Success = ($process.ExitCode -eq 0)
            ExitCode = $process.ExitCode
            Message = if ($process.ExitCode -eq 0) { "Installation completed successfully" } else { "Installation failed with exit code $($process.ExitCode)" }
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-VmUuid {
    [CmdletBinding()]
    param()
    
    try {
        $regPath = 'HKLM:\SOFTWARE\Citrix\XenTools'
        if (Test-Path $regPath) {
            $uuid = (Get-ItemProperty -Path $regPath -Name 'VmUuid' -ErrorAction SilentlyContinue).VmUuid
            if ($uuid) {
                Write-Verbose "Retrieved VM UUID from XenTools registry: $uuid"
                return $uuid
            }
        }
        
        $uuid = (Get-CimInstance -ClassName Win32_ComputerSystemProduct).UUID
        if ($uuid) {
            Write-Verbose "Retrieved VM UUID from WMI: $uuid"
            return $uuid
        }
        
        return $null
    }
    catch {
        Write-AgentLog -Message "Failed to get VM UUID: $_" -Level Error
        return $null
    }
}

function Get-ClientCertificate {
    [CmdletBinding()]
    param()
    
    if ($script:Config.CertificateThumbprint) {
        try {
            $cert = Get-Item "Cert:\LocalMachine\My\$($script:Config.CertificateThumbprint)" -ErrorAction Stop
            return $cert
        }
        catch {
            Write-AgentLog -Message "Failed to load certificate: $_" -Level Warning
            return $null
        }
    }
    return $null
}

function Update-JobStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobId,
        
        [Parameter(Mandatory)]
        [string]$AgentId,
        
        [Parameter(Mandatory)]
        [string]$Status
    )
    
    try {
        $statusData = @{
            JobId = $JobId
            AgentId = $AgentId
            Status = $Status
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
        
        $requestParams = @{
            Uri = "$($script:Config.ServerUrl)/api/agent/job-status"
            Method = 'Post'
            Body = ($statusData | ConvertTo-Json)
            ContentType = 'application/json'
            TimeoutSec = 30
        }
        
        if ($script:Config.CertificateThumbprint) {
            $cert = Get-ClientCertificate
            if ($cert) {
                $requestParams.Certificate = $cert
            }
        }
        
        Invoke-RestMethod @requestParams | Out-Null
    }
    catch {
        Write-AgentLog -Message "Failed to update job status: $_" -Level Warning
    }
}

function Submit-JobResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$JobId,
        
        [Parameter(Mandatory)]
        [string]$AgentId,
        
        [Parameter(Mandatory)]
        [hashtable]$Result
    )
    
    try {
        $resultData = @{
            JobId = $JobId
            AgentId = $AgentId
            Success = $Result.Success
            Result = ($Result | ConvertTo-Json -Depth 5 -Compress)
            Timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
        
        $requestParams = @{
            Uri = "$($script:Config.ServerUrl)/api/agent/job-result"
            Method = 'Post'
            Body = ($resultData | ConvertTo-Json)
            ContentType = 'application/json'
            TimeoutSec = 30
        }
        
        if ($script:Config.CertificateThumbprint) {
            $cert = Get-ClientCertificate
            if ($cert) {
                $requestParams.Certificate = $cert
            }
        }
        
        Invoke-RestMethod @requestParams | Out-Null
    }
    catch {
        Write-AgentLog -Message "Failed to submit job result: $_" -Level Error
    }
}

function Write-AgentLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level = 'Information'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    switch ($Level) {
        'Error' { Write-Host $logMessage -ForegroundColor Red }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        default { Write-Host $logMessage }
    }
    
    try {
        $logFile = Join-Path $script:LogPath "VmAgent_$(Get-Date -Format 'yyyyMMdd').log"
        Add-Content -Path $logFile -Value $logMessage -ErrorAction SilentlyContinue
    }
    catch {
    }
    
    try {
        $eventId = switch ($Level) {
            'Information' { 1000 }
            'Warning' { 2000 }
            'Error' { 3000 }
        }
        
        Write-EventLog -LogName 'Application' `
            -Source 'XcpVmAgent' `
            -EntryType $Level `
            -EventId $eventId `
            -Message $Message `
            -ErrorAction SilentlyContinue
    }
    catch {
    }
}

Start-AgentLoop