# Silent install Claude Desktop for Windows

#Requires -RunAsAdministrator

param(
    [switch]$DisableAutoUpdates,
    [int]$AutoUpdaterEnforcementHours = 72,
    [switch]$DisableCowork,
    [switch]$EnableLocalMcp,
    [switch]$EnableExtensions
)

# Configuration
$DownloadUrl = "https://claude.ai/api/desktop/win32/x64/msix/latest/redirect"
$DownloadUrlArm64 = "https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect"
$TempDir = Join-Path $env:TEMP "claude_install_$(Get-Random)"
$LogFile = "C:\ProgramData\Claude\install.log"
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
        Source    = "Claude Desktop Installer"
        EventId   = if ($Level -eq "ERROR") { 1000 } else { 1001 }
        Message   = $Message
        EntryType = if ($Level -eq "ERROR") { "Error" } elseif ($Level -eq "WARN") { "Warning" } else { "Information" }
    }
    
    try {
        Write-EventLog @eventLogParams -ErrorAction SilentlyContinue
    } catch {
        # Silently fail if event log write fails (e.g. source not registered);
        # discard the error record so logging never blocks the install.
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
        Write-Log -Level "INFO" -Message "Installation completed successfully."
    } else {
        Write-Log -Level "ERROR" -Message "Installation failed with exit code $ExitCode."
    }
    
    exit $ExitCode
}

# Trap for cleanup on exit
trap {
    Write-Log -Level "ERROR" -Message "Unexpected error: $_"
    Cleanup -ExitCode 1
}

Write-Log -Level "INFO" -Message "Starting Claude Desktop deployment (PID: $PID)..."

# Verify running as administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Log -Level "ERROR" -Message "This script must be run as Administrator (via MDM)."
    Cleanup -ExitCode 1
}

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

# Function to detect installed Claude build architecture
function Get-InstalledClaudeBuild {
    $installedApp = Get-AppxPackage -Name "AnthropicClaude*" -AllUsers -ErrorAction SilentlyContinue
    
    if (-not $installedApp) {
        return $null
    }
    
    # Get the installation path
    $installPath = $installedApp.InstallLocation
    if (-not $installPath -or -not (Test-Path $installPath)) {
        return $null
    }
    
    # Check for architecture-specific binaries
    $x64Binaries = @(
        Join-Path $installPath "Contents\Resources\app-x64.asar.unpacked",
        Join-Path $installPath "Contents\Resources\app.asar"
    )
    
    # For Windows MSIX, check the package name which includes architecture info
    if ($installedApp.Name -like "*arm64*") {
        return "arm64"
    } elseif ($installedApp.Name -like "*x64*") {
        return "x64"
    }
    
    # Fallback: try to detect from binary presence (Windows MSIX structure)
    # Check if x64-specific resources exist
    foreach ($binary in $x64Binaries) {
        if (Test-Path $binary) {
            return "x64"
        }
    }
    
    # If we can't determine, assume it's the wrong build
    Write-Log -Level "WARN" -Message "Could not determine installed Claude build architecture"
    return "unknown"
}

# Function to backup user data before removal
function Backup-ClaudeUserData {
    Write-Log -Level "INFO" -Message "Backing up Claude user data..."
    
    $backupDir = Join-Path $env:TEMP "claude_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    
    try {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Write-Log -Level "INFO" -Message "Created backup directory: $backupDir"
        
        # Backup user data locations (Windows)
        $userDataPaths = @(
            "$env:APPDATA\Claude",
            "$env:LOCALAPPDATA\Claude",
            "$env:APPDATA\Anthropic"
        )
        
        foreach ($dataPath in $userDataPaths) {
            if (Test-Path $dataPath) {
                $backupPath = Join-Path $backupDir (Split-Path -Leaf $dataPath)
                try {
                    Copy-Item -Path $dataPath -Destination $backupPath -Recurse -Force -ErrorAction Stop
                    Write-Log -Level "INFO" -Message "Backed up user data from: $dataPath"
                } catch {
                    Write-Log -Level "WARN" -Message "Failed to backup $dataPath : $_"
                }
            }
        }
        
        return $backupDir
    } catch {
        Write-Log -Level "ERROR" -Message "Failed to create backup directory: $_"
        return $null
    }
}

# Function to restore user data after installation
function Restore-ClaudeUserData {
    param([string]$BackupDir)
    
    if (-not $BackupDir -or -not (Test-Path $BackupDir)) {
        Write-Log -Level "WARN" -Message "Backup directory not found, skipping restore"
        return $false
    }
    
    Write-Log -Level "INFO" -Message "Restoring Claude user data from backup..."
    
    try {
        # Restore to original locations
        $restorePaths = @(
            @{ Backup = "Claude"; Target = "$env:APPDATA\Claude" },
            @{ Backup = "Claude"; Target = "$env:LOCALAPPDATA\Claude" },
            @{ Backup = "Anthropic"; Target = "$env:APPDATA\Anthropic" }
        )
        
        foreach ($restorePath in $restorePaths) {
            $backupPath = Join-Path $BackupDir $restorePath.Backup
            if (Test-Path $backupPath) {
                # Ensure target directory exists
                $targetParent = Split-Path -Parent $restorePath.Target
                if (-not (Test-Path $targetParent)) {
                    New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
                }
                
                # Remove existing if present
                if (Test-Path $restorePath.Target) {
                    Remove-Item -Path $restorePath.Target -Recurse -Force -ErrorAction SilentlyContinue
                }
                
                # Restore backup
                Copy-Item -Path $backupPath -Destination $restorePath.Target -Recurse -Force -ErrorAction Stop
                Write-Log -Level "INFO" -Message "Restored user data to: $($restorePath.Target)"
            }
        }
        
        return $true
    } catch {
        Write-Log -Level "ERROR" -Message "Failed to restore user data: $_"
        return $false
    }
}

# Check for incorrect build and handle replacement
$installedBuild = Get-InstalledClaudeBuild
if ($installedBuild -and $installedBuild -ne "unknown" -and $installedBuild -ne $architecture) {
    Write-Log -Level "WARN" -Message "Detected incorrect Claude build: installed=$installedBuild, required=$architecture"
    Write-Log -Level "INFO" -Message "Will backup user data, remove incorrect build, and install correct build..."
    
    # Backup user data first
    $backupDir = Backup-ClaudeUserData
    
    # Remove incorrect build
    Write-Log -Level "INFO" -Message "Removing incorrect Claude Desktop build ($installedBuild)..."
    try {
        $existingApp = Get-AppxPackage -Name "AnthropicClaude*" -AllUsers -ErrorAction SilentlyContinue
        if ($existingApp) {
            Remove-AppxPackage -Package $existingApp.PackageFullName -AllUsers -ErrorAction Stop
            Start-Sleep -Seconds 2
            Write-Log -Level "INFO" -Message "Incorrect build removed successfully. User data preserved in backup."
        }
    } catch {
        Write-Log -Level "WARN" -Message "Failed to remove incorrect build: $_"
    }
} elseif ($installedBuild -eq $architecture) {
    Write-Log -Level "INFO" -Message "Installed Claude build matches system architecture ($architecture). No replacement needed."
    $backupDir = $null
}

# Select appropriate download URL
$selectedUrl = if ($architecture -eq "arm64") { $DownloadUrlArm64 } else { $DownloadUrl }

# Create temporary directory
try {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    Write-Log -Level "INFO" -Message "Created temporary directory: $TempDir"
} catch {
    Write-Log -Level "ERROR" -Message "Failed to create temporary directory: $_"
    Cleanup -ExitCode 1
}

# Download MSIX package with retry logic
Write-Log -Level "INFO" -Message "Downloading Claude Desktop MSIX package ($architecture)..."
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

# Check for existing installation
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

# Restore user data if backup was created (build replacement scenario)
if ($backupDir -and (Test-Path $backupDir)) {
    Write-Log -Level "INFO" -Message "Restoring user data from backup..."
    if (Restore-ClaudeUserData -BackupDir $backupDir) {
        Write-Log -Level "INFO" -Message "User data restored successfully. Chat history, code history, and project files preserved."
        
        # Clean up backup directory after successful restore
        try {
            Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log -Level "INFO" -Message "Backup directory cleaned up."
        } catch {
            Write-Log -Level "WARN" -Message "Failed to clean up backup directory (non-critical): $_"
        }
    } else {
        Write-Log -Level "WARN" -Message "Failed to restore user data. Backup preserved at: $backupDir"
    }
}

# Configure enterprise settings
Write-Log -Level "INFO" -Message "Configuring enterprise settings..."
try {
    $policyPath = "HKLM:\SOFTWARE\Policies\Claude"
    
    # Create policy registry path if it doesn't exist
    if (-not (Test-Path $policyPath)) {
        New-Item -Path $policyPath -Force | Out-Null
    }
    
    # Set auto-update policy
    $autoUpdateValue = if ($DisableAutoUpdates) { 1 } else { 0 }
    Set-ItemProperty -Path $policyPath -Name "disableAutoUpdates" -Value $autoUpdateValue -Type DWord -Force
    Write-Log -Level "INFO" -Message "Set disableAutoUpdates to $autoUpdateValue"
    
    # Set auto-updater enforcement hours
    Set-ItemProperty -Path $policyPath -Name "autoUpdaterEnforcementHours" -Value $AutoUpdaterEnforcementHours -Type DWord -Force
    Write-Log -Level "INFO" -Message "Set autoUpdaterEnforcementHours to $AutoUpdaterEnforcementHours"
    
    # Set Cowork setting
    $coworkValue = if ($DisableCowork) { 0 } else { 1 }
    Set-ItemProperty -Path $policyPath -Name "secureVmFeaturesEnabled" -Value $coworkValue -Type DWord -Force
    Write-Log -Level "INFO" -Message "Set secureVmFeaturesEnabled to $coworkValue"
    
    # Set local MCP setting
    $mcpValue = if ($EnableLocalMcp) { 1 } else { 0 }
    Set-ItemProperty -Path $policyPath -Name "isLocalDevMcpEnabled" -Value $mcpValue -Type DWord -Force
    Write-Log -Level "INFO" -Message "Set isLocalDevMcpEnabled to $mcpValue"
    
    # Set extensions setting
    $extensionsValue = if ($EnableExtensions) { 1 } else { 0 }
    Set-ItemProperty -Path $policyPath -Name "isDesktopExtensionEnabled" -Value $extensionsValue -Type DWord -Force
    Write-Log -Level "INFO" -Message "Set isDesktopExtensionEnabled to $extensionsValue"
    
    Write-Log -Level "INFO" -Message "Enterprise settings configured successfully."
} catch {
    Write-Log -Level "WARN" -Message "Failed to configure some enterprise settings: $_"
}

# Optionally enable Virtual Machine Platform for Cowork (if not disabled)
if (-not $DisableCowork) {
    Write-Log -Level "INFO" -Message "Checking Virtual Machine Platform for Cowork support..."
    try {
        $vmPlatform = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction SilentlyContinue
        
        if ($vmPlatform -and $vmPlatform.State -ne "Enabled") {
            Write-Log -Level "INFO" -Message "Enabling Virtual Machine Platform..."
            Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop
            Write-Log -Level "INFO" -Message "Virtual Machine Platform enabled (reboot may be required for full functionality)."
        } else {
            Write-Log -Level "INFO" -Message "Virtual Machine Platform is already enabled."
        }
    } catch {
        Write-Log -Level "WARN" -Message "Failed to enable Virtual Machine Platform (non-critical): $_"
    }
}

Write-Log -Level "INFO" -Message "Installation completed successfully. Claude Desktop is ready for use."
Cleanup -ExitCode 0
