# Silent install Node.js LTS for Windows 11 with Snapdragon ARM processor
# Runs as SYSTEM context (via JumpCloud MDM) - no user interaction required
# Installs machine-wide so standard, non-admin users can use node/npm

#Requires -RunAsAdministrator

param(
    [switch]$Force
)

# Configuration
$AppName = "Node.js LTS"
$WingetId = "OpenJS.NodeJS.LTS"
# Direct-download fallback (nodejs.org permits automated downloads; no CDN/WAF block).
# Pinned to a specific LTS to satisfy reproducible/pinned-dependency requirements.
$NodeVersion = "20.18.1"
$NodeMsiArm64 = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-arm64.msi"
$NodeMsiX64   = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-x64.msi"
$NodeMsiX86   = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-x86.msi"
$TempDir = Join-Path $env:TEMP "nodejs_install_$(Get-Random)"
$LogFile = "C:\ProgramData\NodeJSInstall\install.log"
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
        Source    = "NodeJS Installer"
        EventId   = if ($Level -eq "ERROR") { 5100 } else { 5101 }
        Message   = $Message
        EntryType = if ($Level -eq "ERROR") { "Error" } elseif ($Level -eq "WARN") { "Warning" } else { "Information" }
    }

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists("NodeJS Installer")) {
            New-EventLog -LogName "Application" -Source "NodeJS Installer" -ErrorAction SilentlyContinue
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

# Detect system architecture
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

# Select MSI URL (ordered: native first, then x64 emulation fallback on ARM)
$msiUrls = if ($architecture -eq "arm64") {
    Write-Log -Level "INFO" -Message "ARM64 detected. Will try native ARM64 MSI, then x64 fallback via emulation."
    @($NodeMsiArm64, $NodeMsiX64)
} elseif ($architecture -eq "x86") {
    @($NodeMsiX86)
} else {
    @($NodeMsiX64)
}

# Refresh PATH from registry so we detect prior installs
function Update-PathFromRegistry {
    # Only refreshes the in-process $env:Path; changes no persistent state,
    # so ShouldProcess support is unnecessary.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only refreshes in-process $env:Path; changes no persistent state')]
    param()
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

# Check for existing Node.js installation
function Get-NodeExe {
    Update-PathFromRegistry
    $cmd = (Get-Command node -ErrorAction SilentlyContinue).Source
    if ($cmd) { return $cmd }
    $candidates = @(
        "$env:ProgramFiles\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

$existingNode = Get-NodeExe
if ($existingNode) {
    try {
        $currentVersion = (& $existingNode --version 2>$null).Trim()
        Write-Log -Level "INFO" -Message "Existing Node.js found: $currentVersion at $existingNode"
    } catch {
        Write-Log -Level "INFO" -Message "Existing Node.js found at $existingNode (version check skipped)."
    }
    if (-not $Force) {
        Write-Log -Level "INFO" -Message "Node.js is already installed. Use -Force to reinstall."
        Cleanup -ExitCode 0
    }
    Write-Log -Level "INFO" -Message "Force flag set. Proceeding with reinstall..."
} else {
    Write-Log -Level "INFO" -Message "No existing Node.js installation found."
}

$installSuccess = $false

# Helper: locate winget.exe in SYSTEM context
function Find-Winget {
    $paths = @(
        (Get-Command winget -ErrorAction SilentlyContinue).Source,
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"
    )
    foreach ($p in $paths) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $resolved = Get-Item -Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($resolved) { return $resolved.FullName }
    return $null
}

# --- Step 1: Install via winget (machine scope) ---
$wingetExe = Find-Winget
if ($wingetExe) {
    Write-Log -Level "INFO" -Message "Found winget at: $wingetExe"
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Write-Log -Level "INFO" -Message "winget install attempt $attempt/$MaxRetries..."
            $wingetOutput = & $wingetExe install --id "$WingetId" --silent --accept-package-agreements --accept-source-agreements --scope machine 2>&1
            $wingetExit = $LASTEXITCODE

            if ($wingetExit -eq 0 -or $wingetExit -eq -1978335189 -or $wingetExit -eq 3010) {
                Write-Log -Level "INFO" -Message "Node.js installed successfully via winget."
                $installSuccess = $true
                break
            } else {
                $outputStr = ($wingetOutput | Where-Object { $_ -notmatch '[^\x20-\x7E]' } | Select-Object -Last 3) -join " "
                throw "winget exited with code $wingetExit : $outputStr"
            }
        } catch {
            Write-Log -Level "WARN" -Message "winget attempt $attempt/$MaxRetries failed: $_"
            if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds 5 }
        }
    }
} else {
    Write-Log -Level "WARN" -Message "winget not found. Will try direct MSI download."
}

# --- Step 2: Direct MSI download + msiexec silent install (fallback) ---
if (-not $installSuccess) {
    Write-Log -Level "INFO" -Message "Attempting direct MSI install from nodejs.org..."
    try {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    } catch {
        Write-Log -Level "ERROR" -Message "Failed to create temporary directory: $_"
        Cleanup -ExitCode 1
    }

    $curlExe = "$env:SystemRoot\System32\curl.exe"
    $msiPath = Join-Path $TempDir "nodejs.msi"

    foreach ($url in $msiUrls) {
        Write-Log -Level "INFO" -Message "Trying MSI URL: $url"
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                if (Test-Path $msiPath) { Remove-Item $msiPath -Force -ErrorAction SilentlyContinue }

                if (Test-Path $curlExe) {
                    $dl = Start-Process -FilePath $curlExe -ArgumentList @(
                        "-L", "-f", "-s", "-S",
                        "--connect-timeout", "30",
                        "--max-time", "$DownloadTimeout",
                        "-o", "`"$msiPath`"",
                        "`"$url`""
                    ) -Wait -PassThru -NoNewWindow
                    if ($dl.ExitCode -ne 0) { throw "curl.exe exit code $($dl.ExitCode)" }
                } else {
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri $url -OutFile $msiPath -UseBasicParsing -TimeoutSec $DownloadTimeout
                }

                if ((Test-Path $msiPath) -and ((Get-Item $msiPath).Length -gt 1048576)) {
                    $fileSizeMB = [math]::Round((Get-Item $msiPath).Length / 1MB, 2)
                    Write-Log -Level "INFO" -Message "Downloaded $fileSizeMB MB. Running msiexec..."

                    $msiLog = Join-Path $TempDir "nodejs_msi.log"
                    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @(
                        "/i", "`"$msiPath`"",
                        "/qn", "/norestart",
                        "ADDLOCAL=ALL",
                        "/L*v", "`"$msiLog`""
                    ) -Wait -PassThru
                    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                        Start-Sleep -Seconds 3
                        $installSuccess = $true
                        break
                    } else {
                        throw "msiexec exited with code $($proc.ExitCode)"
                    }
                } else {
                    throw "Downloaded file missing or too small"
                }
            } catch {
                Write-Log -Level "WARN" -Message "MSI attempt $attempt failed: $_"
                if ($attempt -lt 2) { Start-Sleep -Seconds 10 }
            }
        }
        if ($installSuccess) { break }
    }
}

# --- Final check ---
if (-not $installSuccess) {
    Write-Log -Level "ERROR" -Message "All Node.js installation methods failed."
    Cleanup -ExitCode 1
}

# ============================================================
# VERIFICATION
# ============================================================
Write-Log -Level "INFO" -Message "Verifying Node.js installation..."
Start-Sleep -Seconds 2

$nodeExe = Get-NodeExe
if (-not $nodeExe) {
    Write-Log -Level "ERROR" -Message "Verification failed: node.exe not found after install."
    Cleanup -ExitCode 1
}

try {
    $nodeVer = (& $nodeExe --version 2>$null).Trim()
    Write-Log -Level "INFO" -Message "Node.js verified: $nodeVer"
} catch {
    Write-Log -Level "INFO" -Message "node.exe found at $nodeExe (version check skipped)."
}

# Verify npm and ensure nodejs dir is in machine PATH
$nodeDir = Split-Path -Parent $nodeExe
$npmCmd = Join-Path $nodeDir "npm.cmd"
if (Test-Path $npmCmd) {
    try {
        $npmVer = (& cmd.exe /c "`"$npmCmd`" --version" 2>$null | Select-Object -First 1).Trim()
        Write-Log -Level "INFO" -Message "npm verified: $npmVer"
    } catch {
        Write-Log -Level "INFO" -Message "npm found at $npmCmd."
    }
}

$systemPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($systemPath -notlike "*$nodeDir*") {
    Write-Log -Level "INFO" -Message "Adding Node.js to system PATH..."
    try {
        [Environment]::SetEnvironmentVariable("Path", "$systemPath;$nodeDir", "Machine")
        Write-Log -Level "INFO" -Message "Node.js added to system PATH."
    } catch {
        Write-Log -Level "WARN" -Message "Failed to add to system PATH (non-critical): $_"
    }
} else {
    Write-Log -Level "INFO" -Message "Node.js is already in system PATH."
}

Write-Log -Level "INFO" -Message "$AppName installation completed successfully. node and npm are ready for use (new sessions)."
Cleanup -ExitCode 0
