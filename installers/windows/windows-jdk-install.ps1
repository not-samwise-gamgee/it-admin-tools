# Silent install Microsoft Build of OpenJDK 21 LTS (ARM64 native) for devices with Snapdragon ARM processor
# Runs as SYSTEM context - no user interaction required

#Requires -RunAsAdministrator

param(
    [int]$JdkMajorVersion = 21,
    [switch]$Force
)

# Configuration
$AppName = "Microsoft OpenJDK $JdkMajorVersion"
# Native ARM64 MSI from Microsoft - runs natively on Snapdragon (no emulation)
$DownloadUrlArm64 = "https://aka.ms/download-jdk/microsoft-jdk-21.0.11-windows-aarch64.msi"
$DownloadUrlX64 = "https://aka.ms/download-jdk/microsoft-jdk-21.0.11-windows-x64.msi"
$TempDir = Join-Path $env:TEMP "jdk_install_$(Get-Random)"
$LogFile = "C:\ProgramData\OpenJDK\install.log"
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
        Source    = "OpenJDK Installer"
        EventId   = if ($Level -eq "ERROR") { 4000 } else { 4001 }
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
    Write-Log -Level "ERROR" -Message "32-bit Windows is not supported."
    Cleanup -ExitCode 1
}

Write-Log -Level "INFO" -Message "Detected system architecture: $architecture"

# Select appropriate download URL
$selectedUrl = if ($architecture -eq "arm64") { $DownloadUrlArm64 } else { $DownloadUrlX64 }
Write-Log -Level "INFO" -Message "Selected download URL: $selectedUrl"

# Check for existing Java installation
$existingJava = $null
$javaPaths = @(
    "$env:ProgramFiles\Microsoft\jdk-$JdkMajorVersion*",
    "$env:ProgramFiles\Java\jdk-$JdkMajorVersion*",
    "$env:ProgramFiles\Zulu\zulu-$JdkMajorVersion*",
    "$env:ProgramFiles\Eclipse Adoptium\jdk-$JdkMajorVersion*"
)

foreach ($javaPattern in $javaPaths) {
    $found = Get-Item -Path $javaPattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $existingJava = $found
        break
    }
}

if ($existingJava) {
    $javaExe = Join-Path $existingJava.FullName "bin\java.exe"
    if (Test-Path $javaExe) {
        try {
            $versionOutput = & $javaExe -version 2>&1
            $currentVersion = ($versionOutput | Select-String "version" | Select-Object -First 1).ToString()
            Write-Log -Level "INFO" -Message "Existing JDK installation found: $currentVersion at $($existingJava.FullName)"
            
            if (-not $Force) {
                # Check if it's already the Microsoft Build of OpenJDK
                $isMicrosoft = $versionOutput | Select-String "Microsoft" | Select-Object -First 1
                if ($isMicrosoft) {
                    Write-Log -Level "INFO" -Message "Microsoft OpenJDK is already installed. Use -Force to reinstall."
                    Cleanup -ExitCode 0
                }
            }
        } catch {
            Write-Log -Level "WARN" -Message "Found JDK directory but could not determine version."
        }
    }
} else {
    Write-Log -Level "INFO" -Message "No existing JDK $JdkMajorVersion installation found."
}

# Also check via java -version in PATH
try {
    $pathJava = & java -version 2>&1
    $pathJavaVersion = ($pathJava | Select-String "version" | Select-Object -First 1).ToString()
    Write-Log -Level "INFO" -Message "Java in PATH: $pathJavaVersion"
} catch {
    Write-Log -Level "INFO" -Message "No Java found in system PATH."
}

# Create temporary directory
try {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    Write-Log -Level "INFO" -Message "Created temporary directory: $TempDir"
} catch {
    Write-Log -Level "ERROR" -Message "Failed to create temporary directory: $_"
    Cleanup -ExitCode 1
}

# Download MSI installer with retry logic
Write-Log -Level "INFO" -Message "Downloading $AppName MSI ($architecture)..."
$msiPath = Join-Path $TempDir "microsoft-jdk-$JdkMajorVersion.msi"
$downloadSuccess = $false

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
        $progressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $selectedUrl -OutFile $msiPath -TimeoutSec $DownloadTimeout -ErrorAction Stop
        
        if ((Test-Path $msiPath) -and ((Get-Item $msiPath).Length -gt 0)) {
            Write-Log -Level "INFO" -Message "Downloaded successfully ($(((Get-Item $msiPath).Length / 1MB).ToString('F2')) MB)"
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
    Write-Log -Level "ERROR" -Message "Failed to download JDK installer after $MaxRetries attempts."
    Cleanup -ExitCode 1
}

# Run silent MSI installation
# Features: ZuluInstallation, FeatureEnvironment (PATH), FeatureJavaHome (JAVA_HOME)
Write-Log -Level "INFO" -Message "Installing $AppName silently..."
try {
    $msiLogPath = Join-Path $TempDir "jdk_msi_install.log"
    
    $msiArgs = @(
        "/i",
        "`"$msiPath`"",
        "ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome",
        "/qn",
        "/norestart",
        "/l*v",
        "`"$msiLogPath`""
    )
    
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    
    if ($process.ExitCode -eq 0) {
        Write-Log -Level "INFO" -Message "MSI installation completed successfully."
    } elseif ($process.ExitCode -eq 3010) {
        Write-Log -Level "WARN" -Message "MSI installation completed. A reboot may be required."
    } elseif ($process.ExitCode -eq 1603) {
        # Fatal error during installation - check log
        if (Test-Path $msiLogPath) {
            $logTail = Get-Content $msiLogPath -Tail 20 -ErrorAction SilentlyContinue
            Write-Log -Level "ERROR" -Message "MSI log tail: $($logTail -join ' | ')"
        }
        throw "MSI installation failed with fatal error (1603)"
    } else {
        if (Test-Path $msiLogPath) {
            $logTail = Get-Content $msiLogPath -Tail 10 -ErrorAction SilentlyContinue
            Write-Log -Level "ERROR" -Message "MSI log tail: $($logTail -join ' | ')"
        }
        throw "MSI installer exited with code $($process.ExitCode)"
    }
} catch {
    Write-Log -Level "ERROR" -Message "Failed to install JDK: $_"
    Cleanup -ExitCode 1
}

# Verify installation
Write-Log -Level "INFO" -Message "Verifying JDK installation..."

# Look for the installed JDK directory
$jdkInstallDir = $null
$searchPaths = @(
    "$env:ProgramFiles\Microsoft\jdk-$JdkMajorVersion*"
)

foreach ($searchPattern in $searchPaths) {
    $found = Get-Item -Path $searchPattern -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($found) {
        $jdkInstallDir = $found.FullName
        break
    }
}

if (-not $jdkInstallDir) {
    Write-Log -Level "ERROR" -Message "Installation verification failed: JDK directory not found."
    Cleanup -ExitCode 1
}

$javaExe = Join-Path $jdkInstallDir "bin\java.exe"
if (Test-Path $javaExe) {
    try {
        $versionOutput = & $javaExe -version 2>&1
        $installedVersion = ($versionOutput | Select-String "version" | Select-Object -First 1).ToString()
        Write-Log -Level "INFO" -Message "Installation verified: $installedVersion"
        Write-Log -Level "INFO" -Message "JDK installed at: $jdkInstallDir"
    } catch {
        Write-Log -Level "WARN" -Message "JDK directory found but could not verify version. Installation likely succeeded."
    }
} else {
    Write-Log -Level "ERROR" -Message "Installation verification failed: java.exe not found at $javaExe"
    Cleanup -ExitCode 1
}

# Verify JAVA_HOME is set
$javaHome = [Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")
if ($javaHome) {
    Write-Log -Level "INFO" -Message "JAVA_HOME is set to: $javaHome"
} else {
    # Set JAVA_HOME manually if the MSI didn't do it
    Write-Log -Level "INFO" -Message "Setting JAVA_HOME manually..."
    try {
        [Environment]::SetEnvironmentVariable("JAVA_HOME", $jdkInstallDir, "Machine")
        Write-Log -Level "INFO" -Message "JAVA_HOME set to: $jdkInstallDir"
    } catch {
        Write-Log -Level "WARN" -Message "Failed to set JAVA_HOME (non-critical): $_"
    }
}

# Verify java is in PATH
$systemPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$javaBinPath = Join-Path $jdkInstallDir "bin"

if ($systemPath -notlike "*$javaBinPath*") {
    Write-Log -Level "INFO" -Message "Adding JDK bin to system PATH..."
    try {
        [Environment]::SetEnvironmentVariable("Path", "$systemPath;$javaBinPath", "Machine")
        Write-Log -Level "INFO" -Message "JDK bin added to system PATH."
    } catch {
        Write-Log -Level "WARN" -Message "Failed to add JDK bin to PATH (non-critical): $_"
    }
} else {
    Write-Log -Level "INFO" -Message "JDK bin is already in system PATH."
}

Write-Log -Level "INFO" -Message "$AppName installation completed successfully. Java is ready for use."
Cleanup -ExitCode 0
