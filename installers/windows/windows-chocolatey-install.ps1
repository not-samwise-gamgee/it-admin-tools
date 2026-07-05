# Silent install Chocolatey for Windows 11 with Snapdragon ARM processor
# Runs as SYSTEM context (via JumpCloud MDM) - no user interaction required
# Installs machine-wide (C:\ProgramData\chocolatey) so standard, non-admin users
# can run choco-installed tools. (Note: running `choco install` itself still
# requires an elevated context per Chocolatey design.)

#Requires -RunAsAdministrator

param(
    [switch]$Force
)

# Configuration
$AppName = "Chocolatey"
# Official Chocolatey bootstrap installer (HTTPS, TLS 1.2 enforced below).
$InstallScriptUrl = "https://community.chocolatey.org/install.ps1"
# Default machine-wide install location.
$ChocoInstallDir = "C:\ProgramData\chocolatey"
$ChocoExe = Join-Path $ChocoInstallDir "bin\choco.exe"
$TempDir = Join-Path $env:TEMP "choco_install_$(Get-Random)"
$LogFile = "C:\ProgramData\ChocolateyInstall\bootstrap.log"
$DownloadTimeout = 180
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
        Source    = "Chocolatey Installer"
        EventId   = if ($Level -eq "ERROR") { 5200 } else { 5201 }
        Message   = $Message
        EntryType = if ($Level -eq "ERROR") { "Error" } elseif ($Level -eq "WARN") { "Warning" } else { "Information" }
    }

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists("Chocolatey Installer")) {
            New-EventLog -LogName "Application" -Source "Chocolatey Installer" -ErrorAction SilentlyContinue
        }
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

# Detect system architecture (informational; Chocolatey core runs on ARM via emulation)
$architecture = if ([Environment]::Is64BitOperatingSystem) {
    if ((Get-CimInstance -ClassName Win32_Processor).Architecture -eq 12) {
        "arm64"
    } else {
        "x64"
    }
} else {
    "x86"
}
Write-Log -Level "INFO" -Message "Detected system architecture: $architecture"
if ($architecture -eq "arm64") {
    Write-Log -Level "INFO" -Message "ARM64 detected. Chocolatey runs under x64 emulation on Windows 11 ARM."
}

# Refresh PATH from registry
function Update-PathFromRegistry {
    # Only refreshes the in-process $env:Path; changes no persistent state,
    # so ShouldProcess support is unnecessary.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only refreshes in-process $env:Path; changes no persistent state')]
    param()
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

# Locate choco.exe
function Get-ChocoExe {
    Update-PathFromRegistry
    if (Test-Path $ChocoExe) { return $ChocoExe }
    $cmd = (Get-Command choco -ErrorAction SilentlyContinue).Source
    if ($cmd) { return $cmd }
    if ($env:ChocolateyInstall -and (Test-Path "$env:ChocolateyInstall\bin\choco.exe")) {
        return "$env:ChocolateyInstall\bin\choco.exe"
    }
    return $null
}

# Check for existing Chocolatey installation
$existingChoco = Get-ChocoExe
if ($existingChoco) {
    try {
        $currentVersion = (& $existingChoco --version 2>$null | Select-Object -First 1).Trim()
        Write-Log -Level "INFO" -Message "Existing Chocolatey found: v$currentVersion at $existingChoco"
    } catch {
        Write-Log -Level "INFO" -Message "Existing Chocolatey found at $existingChoco (version check skipped)."
    }
    if (-not $Force) {
        Write-Log -Level "INFO" -Message "Chocolatey is already installed. Use -Force to reinstall."
        Cleanup -ExitCode 0
    }
    Write-Log -Level "INFO" -Message "Force flag set. Proceeding with reinstall..."
} else {
    Write-Log -Level "INFO" -Message "No existing Chocolatey installation found."
}

# ============================================================
# INSTALLATION
# Bootstrap Chocolatey from the official install script over HTTPS (TLS 1.2).
# Set machine-wide install dir explicitly so all users share one install.
# ============================================================
$installSuccess = $false

# Environment expected by the official bootstrap script
$env:ChocolateyInstall = $ChocoInstallDir
# Do NOT set ChocolateyUseWindowsCompression off etc. - defaults are fine.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
} catch {
    Write-Log -Level "ERROR" -Message "Failed to create temporary directory: $_"
    Cleanup -ExitCode 1
}

$bootstrapPath = Join-Path $TempDir "choco-install.ps1"
$curlExe = "$env:SystemRoot\System32\curl.exe"

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
        Write-Log -Level "INFO" -Message "Chocolatey install attempt $attempt/$MaxRetries..."

        # Download the official bootstrap script to disk (so we can validate it)
        if (Test-Path $bootstrapPath) { Remove-Item $bootstrapPath -Force -ErrorAction SilentlyContinue }

        if (Test-Path $curlExe) {
            $dl = Start-Process -FilePath $curlExe -ArgumentList @(
                "-L", "-f", "-s", "-S",
                "--connect-timeout", "30",
                "--max-time", "$DownloadTimeout",
                "-o", "`"$bootstrapPath`"",
                "`"$InstallScriptUrl`""
            ) -Wait -PassThru -NoNewWindow
            if ($dl.ExitCode -ne 0) { throw "curl.exe exit code $($dl.ExitCode)" }
        } else {
            Invoke-WebRequest -Uri $InstallScriptUrl -OutFile $bootstrapPath -UseBasicParsing -TimeoutSec $DownloadTimeout
        }

        if (-not (Test-Path $bootstrapPath) -or ((Get-Item $bootstrapPath).Length -lt 1024)) {
            throw "Bootstrap script download failed or file too small"
        }

        # Basic sanity check: confirm it looks like the Chocolatey installer
        $scriptContent = Get-Content -Path $bootstrapPath -Raw
        if ($scriptContent -notmatch "chocolatey") {
            throw "Downloaded script does not appear to be the Chocolatey installer"
        }

        Write-Log -Level "INFO" -Message "Bootstrap script downloaded. Executing..."

        # Execute the official installer in a child scope
        & $bootstrapPath
        $bootstrapExit = $LASTEXITCODE

        Start-Sleep -Seconds 3
        if (Get-ChocoExe) {
            Write-Log -Level "INFO" -Message "Chocolatey bootstrap completed."
            $installSuccess = $true
            break
        } else {
            throw "Bootstrap ran (exit $bootstrapExit) but choco.exe not found"
        }
    } catch {
        Write-Log -Level "WARN" -Message "Chocolatey install attempt $attempt/$MaxRetries failed: $_"
        if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds 10 }
    }
}

# --- Final check ---
if (-not $installSuccess) {
    Write-Log -Level "ERROR" -Message "All Chocolatey installation methods failed."
    Cleanup -ExitCode 1
}

# ============================================================
# VERIFICATION
# ============================================================
Write-Log -Level "INFO" -Message "Verifying Chocolatey installation..."
Start-Sleep -Seconds 2

$chocoExe = Get-ChocoExe
if (-not $chocoExe) {
    Write-Log -Level "ERROR" -Message "Verification failed: choco.exe not found after install."
    Cleanup -ExitCode 1
}

try {
    $chocoVer = (& $chocoExe --version 2>$null | Select-Object -First 1).Trim()
    Write-Log -Level "INFO" -Message "Chocolatey verified: v$chocoVer"
} catch {
    Write-Log -Level "INFO" -Message "choco.exe found at $chocoExe (version check skipped)."
}

# Ensure choco bin dir is in machine PATH (the bootstrap normally handles this)
$chocoBinDir = Split-Path -Parent $chocoExe
$systemPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($systemPath -notlike "*$chocoBinDir*") {
    Write-Log -Level "INFO" -Message "Adding Chocolatey to system PATH..."
    try {
        [Environment]::SetEnvironmentVariable("Path", "$systemPath;$chocoBinDir", "Machine")
        Write-Log -Level "INFO" -Message "Chocolatey added to system PATH."
    } catch {
        Write-Log -Level "WARN" -Message "Failed to add to system PATH (non-critical): $_"
    }
} else {
    Write-Log -Level "INFO" -Message "Chocolatey is already in system PATH."
}

# Ensure ChocolateyInstall machine env var is set for future sessions
$machineChocoVar = [Environment]::GetEnvironmentVariable("ChocolateyInstall", "Machine")
if (-not $machineChocoVar) {
    try {
        [Environment]::SetEnvironmentVariable("ChocolateyInstall", $ChocoInstallDir, "Machine")
        Write-Log -Level "INFO" -Message "Set machine ChocolateyInstall variable to $ChocoInstallDir."
    } catch {
        Write-Log -Level "WARN" -Message "Failed to set ChocolateyInstall machine variable (non-critical): $_"
    }
}

Write-Log -Level "INFO" -Message "$AppName installation completed successfully. choco is ready for use (new elevated sessions)."
Cleanup -ExitCode 0
