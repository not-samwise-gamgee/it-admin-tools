# Silent auto-update Claude Desktop for Windows

#Requires -RunAsAdministrator

param(
    # Retained for MDM call-site compatibility; per-request timeout is governed by $CurlTimeout.
    [int]$TimeoutSeconds = 300
)

# Configuration
$DownloadUrl = "https://claude.ai/api/desktop/win32/x64/msix/latest/redirect"
$DownloadUrlArm64 = "https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect"
$TempDir = Join-Path $env:TEMP "claude_update_$(Get-Random)"
$LogFile = "C:\ProgramData\Claude\update.log"
$CurlTimeout = 30
$MaxRetries = 3

# Ensure log directory exists
$LogDir = Split-Path -Parent $LogFile
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level,
        
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console
    Write-Host $logEntry
    
    # Write to log file
    Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
    
    # Write to Windows Event Log
    $eventLogParams = @{
        LogName   = "Application"
        Source    = "Claude Desktop Updater"
        EventId   = if ($Level -eq "ERROR") { 2000 } else { 2001 }
        Message   = $Message
        EntryType = if ($Level -eq "ERROR") { "Error" } elseif ($Level -eq "WARN") { "Warning" } else { "Information" }
    }
    
    try {
        Write-EventLog @eventLogParams -ErrorAction SilentlyContinue
    } catch {
        # Silently fail if event log write fails (e.g. source not registered);
        # discard the error record so logging never blocks the update.
        $null = $_
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
        Write-Log -Level "INFO" -Message "Update completed successfully."
    } else {
        Write-Log -Level "ERROR" -Message "Update failed with exit code $ExitCode."
    }
    
    exit $ExitCode
}

# Trap for cleanup on exit
trap {
    Write-Log -Level "ERROR" -Message "Unexpected error: $_"
    Cleanup -ExitCode 1
}

Write-Log -Level "INFO" -Message "Starting Claude Desktop update check (PID: $PID)..."

# Verify running as administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Log -Level "ERROR" -Message "This script must be run as Administrator (via MDM)."
    Cleanup -ExitCode 1
}

# Check if Claude is installed
$installedApp = Get-AppxPackage -Name "AnthropicClaude*" -ErrorAction SilentlyContinue
if (-not $installedApp) {
    Write-Log -Level "WARN" -Message "Claude Desktop not found. Skipping update."
    Cleanup -ExitCode 0
}

# Get current installed version
$currentVersion = $installedApp.Version
Write-Log -Level "INFO" -Message "Current Claude Desktop version: $currentVersion"

# Detect system architecture
$architecture = if ([Environment]::Is64BitOperatingSystem) {
    if ((Get-WmiObject -Class Win32_Processor).Architecture -eq 12) {
        "arm64"
    } else {
        "x64"
    }
} else {
    Write-Log -Level "ERROR" -Message "32-bit Windows is not supported."
    Cleanup -ExitCode 1
}

Write-Log -Level "INFO" -Message "Detected system architecture: $architecture"

# Select appropriate download URL
$selectedUrl = if ($architecture -eq "arm64") { $DownloadUrlArm64 } else { $DownloadUrl }

# Fetch latest version from release JSON
Write-Log -Level "INFO" -Message "Fetching latest Claude release information..."
$latestVersion = ""
$latestUrl = ""

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
        $progressPreference = 'SilentlyContinue'
        $releaseInfo = Invoke-WebRequest -Uri "https://downloads.claude.ai/releases/darwin/universal/RELEASES.json" -TimeoutSec $CurlTimeout -ErrorAction Stop
        
        if ($releaseInfo.Content) {
            # Parse JSON to extract latest version
            $releaseJson = $releaseInfo.Content | ConvertFrom-Json
            $latestVersion = $releaseJson.version
            $latestUrl = $releaseJson.url
            
            if ($latestVersion -and $latestUrl) {
                break
            }
        }
    } catch {
        Write-Log -Level "WARN" -Message "Failed to fetch release info (attempt $attempt/$MaxRetries): $_"
        
        if ($attempt -lt $MaxRetries) {
            Write-Log -Level "INFO" -Message "Retrying in 5 seconds..."
            Start-Sleep -Seconds 5
        }
    }
}

if (-not $latestVersion -or -not $latestUrl) {
    Write-Log -Level "ERROR" -Message "Could not determine latest Claude Desktop version after $MaxRetries attempts."
    Cleanup -ExitCode 1
}

Write-Log -Level "INFO" -Message "Latest available version: $latestVersion"

# Compare versions (simple string comparison for semantic versioning)
if ([version]$currentVersion -ge [version]$latestVersion) {
    Write-Log -Level "INFO" -Message "Claude Desktop is already up to date (version $currentVersion)."
    Cleanup -ExitCode 0
}

Write-Log -Level "INFO" -Message "Update available: $currentVersion → $latestVersion"

# Create temporary directory
try {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    Write-Log -Level "INFO" -Message "Created temporary directory: $TempDir"
} catch {
    Write-Log -Level "ERROR" -Message "Failed to create temporary directory: $_"
    Cleanup -ExitCode 1
}

# Download latest version
Write-Log -Level "INFO" -Message "Downloading Claude Desktop $latestVersion..."
$msixPath = Join-Path $TempDir "Claude.msix"
$downloadSuccess = $false

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
        $progressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $selectedUrl -OutFile $msixPath -TimeoutSec $CurlTimeout -ErrorAction Stop
        
        # Verify file exists and is not empty
        if ((Test-Path $msixPath) -and ((Get-Item $msixPath).Length -gt 0)) {
            Write-Log -Level "INFO" -Message "Downloaded MSIX package successfully ($(((Get-Item $msixPath).Length / 1MB).ToString('F2')) MB)"
            $downloadSuccess = $true
            break
        } else {
            throw "Downloaded file is empty or missing"
        }
    } catch {
        Write-Log -Level "WARN" -Message "Download attempt $attempt/$MaxRetries failed: $_"
        
        if ($attempt -lt $MaxRetries) {
            Write-Log -Level "INFO" -Message "Retrying in 5 seconds..."
            Start-Sleep -Seconds 5
        }
    }
}

if (-not $downloadSuccess) {
    Write-Log -Level "ERROR" -Message "Failed to download MSIX package after $MaxRetries attempts."
    Cleanup -ExitCode 1
}

# Validate MSIX package integrity (MSIX is a ZIP file)
Write-Log -Level "INFO" -Message "Validating MSIX package integrity..."
try {
    # Check ZIP file signature (first 4 bytes should be 'PK' for valid ZIP/MSIX)
    $fileStream = [System.IO.File]::OpenRead($msixPath)
    $buffer = New-Object byte[] 4
    $bytesRead = $fileStream.Read($buffer, 0, 4)
    $fileStream.Dispose()
    
    # ZIP files start with 'PK' (0x50 0x4B)
    if ($bytesRead -lt 2 -or $buffer[0] -ne 0x50 -or $buffer[1] -ne 0x4B) {
        throw "Invalid ZIP/MSIX file signature"
    }
    
    Write-Log -Level "INFO" -Message "MSIX package validation successful."
} catch {
    Write-Log -Level "ERROR" -Message "MSIX package is corrupted or invalid: $_"
    Cleanup -ExitCode 1
}

# Check if Claude is running and close it gracefully
Write-Log -Level "INFO" -Message "Checking if Claude Desktop is running..."
$claudeProcess = Get-Process -Name "Claude" -ErrorAction SilentlyContinue

if ($claudeProcess) {
    Write-Log -Level "INFO" -Message "Claude Desktop is running. Attempting graceful shutdown..."
    
    try {
        $claudeProcess | Stop-Process -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Log -Level "INFO" -Message "Claude Desktop stopped successfully."
    } catch {
        Write-Log -Level "WARN" -Message "Failed to stop Claude Desktop: $_"
    }
}

# Remove existing installation
$existingApp = Get-AppxPackage -Name "AnthropicClaude*" -AllUsers -ErrorAction SilentlyContinue
if ($existingApp) {
    Write-Log -Level "INFO" -Message "Removing existing Claude Desktop installation..."
    try {
        Remove-AppxPackage -Package $existingApp.PackageFullName -AllUsers -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Log -Level "INFO" -Message "Existing installation removed successfully."
    } catch {
        Write-Log -Level "WARN" -Message "Failed to remove existing installation (may not exist): $_"
    }
}

# Install MSIX package using DISM (proper tool for SYSTEM context provisioning)
Write-Log -Level "INFO" -Message "Installing Claude Desktop MSIX package..."
try {
    # Use DISM.exe for system-wide MSIX provisioning (works in SYSTEM context)
    # This is the proper tool for provisioning packages and handles dependencies
    $dismOutput = & dism.exe /Online /Add-ProvisionedAppxPackage /PackagePath:$msixPath /SkipLicense 2>&1
    
    # Check if DISM succeeded (exit code 0 or 3010 for reboot required)
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {
        Write-Log -Level "INFO" -Message "MSIX package installed successfully (provisioned for all users)."
        if ($LASTEXITCODE -eq 3010) {
            Write-Log -Level "WARN" -Message "System reboot may be required to complete installation."
        }
    } else {
        throw "DISM failed with exit code $LASTEXITCODE : $dismOutput"
    }
} catch {
    Write-Log -Level "ERROR" -Message "Failed to install MSIX package: $_"
    Cleanup -ExitCode 1
}

# Verify installation
# Check both installed packages and provisioned packages (provisioned packages don't show in Get-AppxPackage until user logs in)
$installedApp = Get-AppxPackage -Name "AnthropicClaude*" -ErrorAction SilentlyContinue
$provisionedApp = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Claude*" }

if (-not $installedApp -and -not $provisionedApp) {
    Write-Log -Level "ERROR" -Message "Installation verification failed: Claude Desktop not found in installed or provisioned apps."
    Cleanup -ExitCode 1
}

if ($installedApp) {
    Write-Log -Level "INFO" -Message "Installation verified. Claude Desktop version: $($installedApp.Version)"
} elseif ($provisionedApp) {
    Write-Log -Level "INFO" -Message "Installation verified. Claude Desktop provisioned for all users (will appear after user login)."
}

Write-Log -Level "INFO" -Message "Claude Desktop successfully updated to version $latestVersion."
Cleanup -ExitCode 0
