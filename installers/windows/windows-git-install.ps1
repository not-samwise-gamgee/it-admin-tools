# Silent install Git for Windows (ARM64)
# Designed for JumpCloud MDM deployment on Surface Pro with Snapdragon ARM processor
# Runs as SYSTEM context - no user interaction required

#Requires -RunAsAdministrator

# GitVersion is a declared part of the deployment interface (reserved for pinning a
# specific version); the current flow installs "latest", so it is intentionally unused.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'GitVersion', Justification = 'Reserved deployment parameter; current flow installs latest')]
param(
    [string]$GitVersion = "latest",
    [switch]$Force
)

# Configuration
$AppName = "Git for Windows"
$GitHubApiUrl = "https://api.github.com/repos/git-for-windows/git/releases/latest"
$TempDir = Join-Path $env:TEMP "git_install_$(Get-Random)"
$LogFile = "C:\ProgramData\Git\install.log"
$DownloadTimeout = 120
$MaxRetries = 3

# Ensure log directory exists
$LogDir = Split-Path -Parent $LogFile
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    # Write-Log is a local helper, not a built-in cmdlet in Windows PowerShell 5.1; suppress false positive.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Local helper function, not a shipped cmdlet')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level,
        
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Write-Host $logEntry
    Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
    
    $eventLogParams = @{
        LogName   = "Application"
        Source    = "Git Installer"
        EventId   = if ($Level -eq "ERROR") { 3000 } else { 3001 }
        Message   = $Message
        EntryType = if ($Level -eq "ERROR") { "Error" } elseif ($Level -eq "WARN") { "Warning" } else { "Information" }
    }
    
    try {
        Write-EventLog @eventLogParams -ErrorAction SilentlyContinue
    } catch {
        # Best-effort event logging; ignore failures (e.g. no permission to write event log)
        Write-Verbose "Event log write failed: $_"
    }
}

function Cleanup {
    param([int]$ExitCode = 0)
    
    if (Test-Path $TempDir) {
        try {
            Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log -Level "WARN" -Message "Failed to clean up temporary directory: $TempDir"
        }
    }
    
    if ($ExitCode -eq 0) {
        Write-Log -Level "INFO" -Message "Installation completed successfully."
    } else {
        Write-Log -Level "ERROR" -Message "Installation failed with exit code $ExitCode."
    }
    
    exit $ExitCode
}

trap {
    Write-Log -Level "ERROR" -Message "Unexpected error: $_"
    Cleanup -ExitCode 1
}

Write-Log -Level "INFO" -Message "Starting $AppName deployment (PID: $PID)..."

# Verify running as administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Log -Level "ERROR" -Message "This script must be run as Administrator (via MDM)."
    Cleanup -ExitCode 1
}

# Detect system architecture
$architecture = if ([Environment]::Is64BitOperatingSystem) {
    if ((Get-CimInstance -ClassName Win32_Processor).Architecture -eq 12) {
        "arm64"
    } else {
        "64-bit"
    }
} else {
    Write-Log -Level "ERROR" -Message "32-bit Windows is not supported."
    Cleanup -ExitCode 1
}

Write-Log -Level "INFO" -Message "Detected system architecture: $architecture"

# Check for existing Git installation
$existingGit = $null
$gitPaths = @(
    "$env:ProgramFiles\Git\cmd\git.exe",
    "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
    "$env:ProgramFiles\Git\bin\git.exe"
)

foreach ($gitPath in $gitPaths) {
    if (Test-Path $gitPath) {
        $existingGit = $gitPath
        break
    }
}

if ($existingGit) {
    try {
        $currentVersion = & $existingGit --version 2>$null
        $currentVersion = ($currentVersion -replace "git version ", "").Trim()
        Write-Log -Level "INFO" -Message "Existing Git installation found: $currentVersion"
    } catch {
        Write-Log -Level "WARN" -Message "Found Git binary but could not determine version."
        $currentVersion = "unknown"
    }
} else {
    Write-Log -Level "INFO" -Message "No existing Git installation found."
    $currentVersion = $null
}

# Fetch latest release info from GitHub API
Write-Log -Level "INFO" -Message "Fetching latest Git for Windows release information..."
$downloadUrl = $null
$latestVersion = $null

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
        $progressPreference = 'SilentlyContinue'
        $releaseInfo = Invoke-RestMethod -Uri $GitHubApiUrl -TimeoutSec 30 -ErrorAction Stop
        
        $latestVersion = $releaseInfo.tag_name -replace "^v", ""
        
        # Find the ARM64 installer asset (or 64-bit fallback)
        $targetPattern = if ($architecture -eq "arm64") { "arm64.exe" } else { "64-bit.exe" }
        
        $asset = $releaseInfo.assets | Where-Object {
            $_.name -like "Git-*-$targetPattern" -and $_.name -notlike "*portable*" -and $_.name -notlike "*busybox*"
        } | Select-Object -First 1
        
        if ($asset) {
            $downloadUrl = $asset.browser_download_url
            Write-Log -Level "INFO" -Message "Found $architecture installer: $($asset.name)"
            break
        } else {
            Write-Log -Level "WARN" -Message "No $architecture installer found in release assets (attempt $attempt/$MaxRetries)."
        }
    } catch {
        Write-Log -Level "WARN" -Message "Failed to fetch release info (attempt $attempt/$MaxRetries): $_"
        
        if ($attempt -lt $MaxRetries) {
            $backoff = $attempt * 5
            Write-Log -Level "INFO" -Message "Retrying in $backoff seconds..."
            Start-Sleep -Seconds $backoff
        }
    }
}

if (-not $downloadUrl -or -not $latestVersion) {
    Write-Log -Level "ERROR" -Message "Could not determine download URL after $MaxRetries attempts."
    Cleanup -ExitCode 1
}

# Clean up version string for comparison (e.g., "v2.47.1.windows.1" -> "2.47.1")
$latestVersionClean = ($latestVersion -replace "\.windows\.\d+$", "").Trim()
Write-Log -Level "INFO" -Message "Latest available version: $latestVersionClean"

# Compare versions if already installed
if ($currentVersion -and -not $Force) {
    $currentVersionClean = ($currentVersion -replace "\.windows\.\d+$", "").Trim()
    try {
        if ([version]$currentVersionClean -ge [version]$latestVersionClean) {
            Write-Log -Level "INFO" -Message "Git is already up to date (version $currentVersionClean). Use -Force to reinstall."
            Cleanup -ExitCode 0
        }
        Write-Log -Level "INFO" -Message "Update available: $currentVersionClean -> $latestVersionClean"
    } catch {
        Write-Log -Level "WARN" -Message "Could not compare versions, proceeding with install."
    }
}

# Create temporary directory
try {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    Write-Log -Level "INFO" -Message "Created temporary directory: $TempDir"
} catch {
    Write-Log -Level "ERROR" -Message "Failed to create temporary directory: $_"
    Cleanup -ExitCode 1
}

# Download installer with retry logic
Write-Log -Level "INFO" -Message "Downloading Git for Windows ($architecture)..."
$installerPath = Join-Path $TempDir "GitInstaller.exe"
$downloadSuccess = $false

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
        $progressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -TimeoutSec $DownloadTimeout -ErrorAction Stop
        
        if ((Test-Path $installerPath) -and ((Get-Item $installerPath).Length -gt 0)) {
            Write-Log -Level "INFO" -Message "Downloaded successfully ($(((Get-Item $installerPath).Length / 1MB).ToString('F2')) MB)"
            $downloadSuccess = $true
            break
        } else {
            throw "Downloaded file is empty or missing"
        }
    } catch {
        Write-Log -Level "WARN" -Message "Download attempt $attempt/$MaxRetries failed: $_"
        
        if ($attempt -lt $MaxRetries) {
            $backoff = $attempt * 5
            Write-Log -Level "INFO" -Message "Retrying in $backoff seconds..."
            Start-Sleep -Seconds $backoff
        }
    }
}

if (-not $downloadSuccess) {
    Write-Log -Level "ERROR" -Message "Failed to download Git installer after $MaxRetries attempts."
    Cleanup -ExitCode 1
}

# Run silent installation
# InnoSetup-based installer: /VERYSILENT /NORESTART
Write-Log -Level "INFO" -Message "Installing Git for Windows silently..."
try {
    $installArgs = @(
        "/VERYSILENT",
        "/NORESTART",
        "/NOCANCEL",
        "/SP-",
        "/SUPPRESSMSGBOXES",
        "/CLOSEAPPLICATIONS",
        "/RESTARTAPPLICATIONS",
        "/COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh",
        "/DIR=`"$env:ProgramFiles\Git`"",
        "/LOG=`"$TempDir\git_install_log.txt`""
    )
    
    $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
    
    if ($process.ExitCode -eq 0) {
        Write-Log -Level "INFO" -Message "Git installer completed successfully."
    } elseif ($process.ExitCode -eq 3010) {
        Write-Log -Level "WARN" -Message "Git installed successfully but a reboot is required."
    } else {
        # Read InnoSetup log for details
        $innoLog = Join-Path $TempDir "git_install_log.txt"
        if (Test-Path $innoLog) {
            $logTail = Get-Content $innoLog -Tail 10 -ErrorAction SilentlyContinue
            Write-Log -Level "ERROR" -Message "Installer log tail: $($logTail -join ' | ')"
        }
        throw "Git installer exited with code $($process.ExitCode)"
    }
} catch {
    Write-Log -Level "ERROR" -Message "Failed to install Git: $_"
    Cleanup -ExitCode 1
}

# Verify installation
Write-Log -Level "INFO" -Message "Verifying Git installation..."
$verifyPath = "$env:ProgramFiles\Git\cmd\git.exe"

if (Test-Path $verifyPath) {
    try {
        $installedVersion = & $verifyPath --version 2>$null
        Write-Log -Level "INFO" -Message "Installation verified: $installedVersion"
    } catch {
        Write-Log -Level "WARN" -Message "Git binary found but could not get version. Installation likely succeeded."
    }
} else {
    Write-Log -Level "ERROR" -Message "Installation verification failed: git.exe not found at $verifyPath"
    Cleanup -ExitCode 1
}

# Ensure Git is in the system PATH
$systemPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$gitCmdPath = "$env:ProgramFiles\Git\cmd"

if ($systemPath -notlike "*$gitCmdPath*") {
    Write-Log -Level "INFO" -Message "Adding Git to system PATH..."
    try {
        [Environment]::SetEnvironmentVariable("Path", "$systemPath;$gitCmdPath", "Machine")
        Write-Log -Level "INFO" -Message "Git added to system PATH."
    } catch {
        Write-Log -Level "WARN" -Message "Failed to add Git to system PATH (non-critical): $_"
    }
} else {
    Write-Log -Level "INFO" -Message "Git is already in system PATH."
}

# Configure default Git settings for enterprise use
Write-Log -Level "INFO" -Message "Configuring default Git settings..."
try {
    $gitExe = "$env:ProgramFiles\Git\cmd\git.exe"
    
    # Set system-wide defaults
    & $gitExe config --system core.autocrlf true 2>$null
    & $gitExe config --system core.longpaths true 2>$null
    & $gitExe config --system credential.helper manager 2>$null
    & $gitExe config --system init.defaultBranch main 2>$null
    
    Write-Log -Level "INFO" -Message "Default Git configuration applied."
} catch {
    Write-Log -Level "WARN" -Message "Failed to configure some Git settings (non-critical): $_"
}

Write-Log -Level "INFO" -Message "$AppName installation completed successfully. Git is ready for use."
Cleanup -ExitCode 0
