# Silent install Salesforce CLI (sf) for Windows with Snapdragon ARM processor
# Runs as SYSTEM context - no user interaction required

#Requires -RunAsAdministrator

param(
    [switch]$Force
)

# Configuration
$AppName = "Salesforce CLI"
$DownloadUrlArm64 = "https://developer.salesforce.com/media/salesforce-cli/sf/channels/stable/sf-arm64.exe"
$DownloadUrlX64 = "https://developer.salesforce.com/media/salesforce-cli/sf/channels/stable/sf-x64.exe"
$DownloadUrlX86 = "https://developer.salesforce.com/media/salesforce-cli/sf/channels/stable/sf-x86.exe"
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
$TempDir = Join-Path $env:TEMP "sf_cli_install_$(Get-Random)"
$LogFile = "C:\ProgramData\SalesforceCLI\install.log"
$DownloadTimeout = 120
$MaxRetries = 3

# Machine-wide npm global prefix. When the script runs as SYSTEM, npm's default
# global prefix is the SYSTEM profile (C:\Windows\System32\config\systemprofile\
# AppData\Roaming\npm), which no interactive user can reach. Forcing a shared
# location makes the installed 'sf' binary accessible to all users on the device.
$NpmGlobalPrefix = "C:\ProgramData\npm-global"

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
        Source    = "Salesforce CLI Installer"
        EventId   = if ($Level -eq "ERROR") { 5000 } else { 5001 }
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
        "x64"
    }
} else {
    "x86"
}

Write-Log -Level "INFO" -Message "Detected system architecture: $architecture"

# Build ordered list of download URLs to try (primary + fallbacks)
$downloadUrls = if ($architecture -eq "arm64") {
    Write-Log -Level "INFO" -Message "ARM64 detected. Will try native ARM64 installer, then x64 fallback via emulation."
    @($DownloadUrlArm64, $DownloadUrlX64)
} elseif ($architecture -eq "x86") {
    @($DownloadUrlX86)
} else {
    @($DownloadUrlX64)
}
Write-Log -Level "INFO" -Message "Primary download URL: $($downloadUrls[0])"

# Check for existing Salesforce CLI installation
$existingSf = $null
$sfPaths = @(
    "$NpmGlobalPrefix\sf.cmd",
    "$env:ProgramFiles\sf\bin\sf.cmd",
    "${env:ProgramFiles(x86)}\sf\bin\sf.cmd",
    "$env:LOCALAPPDATA\sf\bin\sf.cmd",
    "$env:ProgramFiles\Salesforce CLI\bin\sf.cmd",
    "$env:ProgramFiles\sfdx\bin\sfdx.cmd"
)

foreach ($sfPath in $sfPaths) {
    if (Test-Path $sfPath) {
        $existingSf = $sfPath
        break
    }
}

if ($existingSf) {
    try {
        # Get the directory containing sf.cmd and look for sf.exe or run sf.cmd
        $sfDir = Split-Path -Parent $existingSf
        $currentVersion = $null
        
        # Try sf --version
        $sfCmd = Join-Path $sfDir "sf.cmd"
        if (Test-Path $sfCmd) {
            $versionOutput = & cmd.exe /c "`"$sfCmd`" --version" 2>$null
            $currentVersion = ($versionOutput | Select-Object -First 1).Trim()
        }
        
        if ($currentVersion) {
            Write-Log -Level "INFO" -Message "Existing Salesforce CLI found: $currentVersion"
            
            if (-not $Force) {
                Write-Log -Level "INFO" -Message "Salesforce CLI is already installed. Use -Force to reinstall."
                Cleanup -ExitCode 0
            }
            
            Write-Log -Level "INFO" -Message "Force flag set. Proceeding with reinstall..."
        } else {
            Write-Log -Level "WARN" -Message "Found Salesforce CLI binary but could not determine version."
        }
    } catch {
        Write-Log -Level "WARN" -Message "Error checking existing installation: $_"
    }
} else {
    Write-Log -Level "INFO" -Message "No existing Salesforce CLI installation found."
}

# ============================================================
# INSTALLATION
# Salesforce CLI (sf) is NOT available in winget. The Salesforce CDN
# (developer.salesforce.com) blocks automated downloads from SYSTEM context
# with HTTP 403 via Akamai WAF. The reliable method is npm, which downloads
# from the npm registry (registry.npmjs.org) instead.
# Strategy: 1) Use npm if available, 2) Install Node.js via winget then npm
# ============================================================

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
    # Search WindowsApps for the DesktopAppInstaller package
    $resolved = Get-Item -Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($resolved) { return $resolved.FullName }
    return $null
}

# Helper: locate npm.exe (refresh PATH to pick up newly-installed Node.js)
function Find-Npm {
    # Refresh PATH from registry so we pick up winget-installed Node.js
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
    
    $npm = (Get-Command npm -ErrorAction SilentlyContinue).Source
    if ($npm) { return $npm }
    
    # Check common Node.js install locations
    $nodePaths = @(
        "$env:ProgramFiles\nodejs\npm.cmd",
        "$env:ProgramFiles\nodejs\npm.exe",
        "${env:ProgramFiles(x86)}\nodejs\npm.cmd"
    )
    foreach ($p in $nodePaths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# Helper: install Salesforce CLI via npm
function Install-SfViaNpm {
    param([string]$NpmPath)
    
    Write-Log -Level "INFO" -Message "Installing Salesforce CLI via npm..."
    Write-Log -Level "INFO" -Message "Using npm at: $NpmPath"

    # Force a machine-wide global prefix so 'sf' is reachable by all users.
    # Running as SYSTEM, the default prefix lands in the SYSTEM profile and is
    # invisible to interactive users. Set it both for this process and persist
    # it via npm config so the install target is the shared location.
    if (-not (Test-Path $NpmGlobalPrefix)) {
        New-Item -ItemType Directory -Path $NpmGlobalPrefix -Force | Out-Null
    }
    Write-Log -Level "INFO" -Message "Setting npm global prefix to: $NpmGlobalPrefix"
    & $NpmPath config set prefix "$NpmGlobalPrefix" --global 2>&1 | Out-Null

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Write-Log -Level "INFO" -Message "npm install attempt $attempt/$MaxRetries..."

            $npmOutput = & $NpmPath install --global --prefix "$NpmGlobalPrefix" @salesforce/cli 2>&1
            $npmExit = $LASTEXITCODE
            
            if ($npmExit -eq 0) {
                Write-Log -Level "INFO" -Message "npm installation completed successfully."
                return $true
            } else {
                $outputStr = ($npmOutput | Select-Object -Last 5) -join " "
                throw "npm exited with code $npmExit : $outputStr"
            }
        } catch {
            Write-Log -Level "WARN" -Message "npm attempt $attempt/$MaxRetries failed: $_"
            if ($attempt -lt $MaxRetries) {
                Start-Sleep -Seconds 10
            }
        }
    }
    return $false
}

# --- Step 1: Try npm if already available ---
$npmExe = Find-Npm
if ($npmExe) {
    Write-Log -Level "INFO" -Message "Found existing npm at: $npmExe"
    $installSuccess = Install-SfViaNpm -NpmPath $npmExe
}

# --- Step 2: Install Node.js via winget, then use npm ---
if (-not $installSuccess) {
    $wingetExe = Find-Winget
    
    if ($wingetExe) {
        Write-Log -Level "INFO" -Message "Found winget at: $wingetExe"
        
        # Check if Node.js is already installed
        $nodeExisting = (Get-Command node -ErrorAction SilentlyContinue).Source
        if (-not $nodeExisting) {
            $nodeExisting = Get-Item -Path "$env:ProgramFiles\nodejs\node.exe" -ErrorAction SilentlyContinue
        }
        
        if (-not $nodeExisting) {
            Write-Log -Level "INFO" -Message "Node.js not found. Installing Node.js LTS via winget..."
            
            for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
                try {
                    Write-Log -Level "INFO" -Message "winget Node.js install attempt $attempt/$MaxRetries..."
                    
                    $wingetOutput = & $wingetExe install --id "OpenJS.NodeJS.LTS" --silent --accept-package-agreements --accept-source-agreements --scope machine 2>&1
                    $wingetExit = $LASTEXITCODE
                    
                    if ($wingetExit -eq 0 -or $wingetExit -eq -1978335189 -or $wingetExit -eq 3010) {
                        Write-Log -Level "INFO" -Message "Node.js installed successfully via winget."
                        Start-Sleep -Seconds 3
                        break
                    } else {
                        $outputStr = ($wingetOutput | Where-Object { $_ -notmatch '[^\x20-\x7E]' } | Select-Object -Last 3) -join " "
                        throw "winget exited with code $wingetExit : $outputStr"
                    }
                } catch {
                    Write-Log -Level "WARN" -Message "winget attempt $attempt/$MaxRetries failed: $_"
                    if ($attempt -lt $MaxRetries) {
                        Start-Sleep -Seconds 5
                    }
                }
            }
        } else {
            Write-Log -Level "INFO" -Message "Node.js already installed at: $nodeExisting"
        }
        
        # Now try npm again (Node.js should be installed)
        $npmExe = Find-Npm
        if ($npmExe) {
            $installSuccess = Install-SfViaNpm -NpmPath $npmExe
        } else {
            Write-Log -Level "WARN" -Message "npm still not found after Node.js installation."
        }
    } else {
        Write-Log -Level "WARN" -Message "winget not found. Cannot install Node.js automatically."
    }
}

# --- Step 3: Direct download via curl.exe (last resort, may be blocked by CDN) ---
if (-not $installSuccess) {
    Write-Log -Level "INFO" -Message "Attempting direct download from Salesforce CDN via curl.exe (may be blocked)..."
    
    try {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    } catch {
        Write-Log -Level "ERROR" -Message "Failed to create temporary directory: $_"
        Cleanup -ExitCode 1
    }
    
    $installerPath = Join-Path $TempDir "sf-installer.exe"
    $curlExe = "$env:SystemRoot\System32\curl.exe"
    
    if (Test-Path $curlExe) {
        foreach ($tryUrl in $downloadUrls) {
            Write-Log -Level "INFO" -Message "Trying URL: $tryUrl"
            
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                try {
                    if (Test-Path $installerPath) {
                        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
                    }
                    
                    $curlProcess = Start-Process -FilePath $curlExe -ArgumentList @(
                        "-L", "-f", "-s", "-S",
                        "--connect-timeout", "30",
                        "--max-time", "$DownloadTimeout",
                        "-H", "`"User-Agent: $UserAgent`"",
                        "-o", "`"$installerPath`"",
                        "`"$tryUrl`""
                    ) -Wait -PassThru -NoNewWindow
                    
                    if ($curlProcess.ExitCode -ne 0) {
                        throw "curl.exe exit code $($curlProcess.ExitCode) (22=HTTP 403 CDN block)"
                    }
                    
                    if ((Test-Path $installerPath) -and ((Get-Item $installerPath).Length -gt 1048576)) {
                        $fileBytes = [System.IO.File]::ReadAllBytes($installerPath)
                        if ($fileBytes[0] -ne 0x4D -or $fileBytes[1] -ne 0x5A) {
                            throw "Not a valid Windows executable"
                        }
                        
                        $fileSizeMB = [math]::Round((Get-Item $installerPath).Length / 1MB, 2)
                        Write-Log -Level "INFO" -Message "Downloaded $fileSizeMB MB"
                        
                        $installProcess = Start-Process -FilePath $installerPath -ArgumentList "/S", "/D=$env:ProgramFiles\sf" -Wait -PassThru -NoNewWindow
                        if ($installProcess.ExitCode -eq 0) {
                            Start-Sleep -Seconds 5
                            $installSuccess = $true
                            break
                        } else {
                            throw "Installer exited with code $($installProcess.ExitCode)"
                        }
                    } else {
                        throw "File missing or too small"
                    }
                } catch {
                    Write-Log -Level "WARN" -Message "curl attempt $attempt failed: $_"
                    if ($attempt -lt 2) { Start-Sleep -Seconds 10 }
                }
            }
            
            if ($installSuccess) { break }
        }
    }
}

# --- Final check ---
if (-not $installSuccess) {
    Write-Log -Level "ERROR" -Message "All installation methods failed."
    Write-Log -Level "ERROR" -Message "The Salesforce CDN blocks automated downloads (HTTP 403)."
    Write-Log -Level "ERROR" -Message "To install manually, run: npm install -g @salesforce/cli"
    Cleanup -ExitCode 1
}

# ============================================================
# VERIFICATION
# ============================================================
Write-Log -Level "INFO" -Message "Verifying Salesforce CLI installation..."

$verified = $false
$sfBinPath = $null

# Check known installation locations
$verifyPaths = @(
    "$NpmGlobalPrefix\sf.cmd",
    "$NpmGlobalPrefix\sf.ps1",
    "$env:ProgramFiles\sf\bin\sf.cmd",
    "$env:ProgramFiles\sf\bin\sf.exe",
    "$env:ProgramFiles\Salesforce CLI\bin\sf.cmd",
    "${env:ProgramFiles(x86)}\sf\bin\sf.cmd",
    "$env:LOCALAPPDATA\sf\bin\sf.cmd"
)

foreach ($vPath in $verifyPaths) {
    if (Test-Path $vPath) {
        try {
            $versionOutput = & cmd.exe /c "`"$vPath`" --version" 2>$null
            $installedVersion = ($versionOutput | Select-Object -First 1).Trim()
            
            if ($installedVersion) {
                Write-Log -Level "INFO" -Message "Installation verified: $installedVersion"
            } else {
                Write-Log -Level "INFO" -Message "Salesforce CLI binary found at: $vPath"
            }
            $sfBinPath = Split-Path -Parent $vPath
            $verified = $true
            break
        } catch {
            Write-Log -Level "INFO" -Message "Found binary at $vPath (version check skipped)."
            $sfBinPath = Split-Path -Parent $vPath
            $verified = $true
            break
        }
    }
}

# Also check if sf is accessible via PATH (npm installs add to PATH automatically)
if (-not $verified) {
    try {
        $sfVersion = & sf --version 2>$null
        if ($sfVersion) {
            Write-Log -Level "INFO" -Message "Installation verified via PATH: $($sfVersion | Select-Object -First 1)"
            $verified = $true
        }
    } catch {
        Write-Verbose "sf --version check failed: $_"
    }
}

if (-not $verified) {
    Write-Log -Level "ERROR" -Message "Installation verification failed: Salesforce CLI not found."
    Cleanup -ExitCode 1
}

# Ensure sf is in the system PATH (if installed via winget/NSIS, may already be)
if ($sfBinPath) {
    $systemPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($systemPath -notlike "*$sfBinPath*") {
        Write-Log -Level "INFO" -Message "Adding Salesforce CLI to system PATH..."
        try {
            [Environment]::SetEnvironmentVariable("Path", "$systemPath;$sfBinPath", "Machine")
            Write-Log -Level "INFO" -Message "Salesforce CLI added to system PATH."
        } catch {
            Write-Log -Level "WARN" -Message "Failed to add to system PATH (non-critical): $_"
        }
    } else {
        Write-Log -Level "INFO" -Message "Salesforce CLI is already in system PATH."
    }
}

Write-Log -Level "INFO" -Message "$AppName installation completed successfully. The sf command is ready for use."
Cleanup -ExitCode 0
