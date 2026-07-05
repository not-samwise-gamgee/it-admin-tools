# JDK Prerequisite Installer for Windows
# Downloads and installs Adoptium OpenJDK 17 (LTS) for the correct architecture.
# Designed for MDM deployment (JumpCloud) - runs silently as SYSTEM.

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Write-Host "Starting JDK Prerequisite Installation Script..."

# --- Variables ---
$MIN_JAVA_VERSION = 17
$INSTALL_DIR = "C:\Program Files\Eclipse Adoptium"

# Adoptium Temurin 17 download URLs (MSI installers for silent install)
$ARCH = if ([Environment]::Is64BitOperatingSystem) {
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -eq "ARM64") {
        "aarch64"
    } else {
        "x64"
    }
} else {
    "x86"
}

# Set download URL based on architecture
switch ($ARCH) {
    "x64" {
        Write-Host "Detected x64 (Intel/AMD 64-bit) architecture."
        $JDK_DOWNLOAD_URL = "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12%2B7/OpenJDK17U-jdk_x64_windows_hotspot_17.0.12_7.msi"
        $JDK_INSTALLER_NAME = "OpenJDK17U-jdk_x64_windows_hotspot_17.0.12_7.msi"
    }
    "aarch64" {
        Write-Host "Detected ARM64 architecture."
        # Note: ARM64 Windows uses x64 emulation for Java if native not available
        $JDK_DOWNLOAD_URL = "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12%2B7/OpenJDK17U-jdk_x64_windows_hotspot_17.0.12_7.msi"
        $JDK_INSTALLER_NAME = "OpenJDK17U-jdk_x64_windows_hotspot_17.0.12_7.msi"
        Write-Host "Note: Using x64 JDK (runs via emulation on ARM64 Windows)."
    }
    default {
        Write-Host "Detected x86 (32-bit) architecture."
        $JDK_DOWNLOAD_URL = "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12%2B7/OpenJDK17U-jdk_x86-32_windows_hotspot_17.0.12_7.msi"
        $JDK_INSTALLER_NAME = "OpenJDK17U-jdk_x86-32_windows_hotspot_17.0.12_7.msi"
    }
}

$TEMP_DIR = [System.IO.Path]::GetTempPath()
$DOWNLOAD_PATH = Join-Path $TEMP_DIR $JDK_INSTALLER_NAME

# --- Check for Existing Java 17+ ---
function Test-ExistingJdk {
    Write-Host "Checking for existing Java $MIN_JAVA_VERSION+ installation..."
    
    # Method 1: Check java command in PATH
    try {
        $javaVersionOutput = & java -version 2>&1
        $versionLine = $javaVersionOutput | Select-String -Pattern 'version "(\d+)' | Select-Object -First 1
        if ($versionLine -match 'version "(\d+)') {
            $majorVersion = [int]$Matches[1]
            if ($majorVersion -ge $MIN_JAVA_VERSION) {
                Write-Host "Compatible JDK ($majorVersion) found in PATH."
                return $true
            } else {
                Write-Host "Found Java $majorVersion, but version $MIN_JAVA_VERSION+ is required."
            }
        }
    } catch {
        Write-Host "Java not found in PATH."
    }
    
    # Method 2: Check registry for installed JDKs
    $jdkPaths = @(
        "HKLM:\SOFTWARE\Eclipse Adoptium\JDK",
        "HKLM:\SOFTWARE\JavaSoft\JDK",
        "HKLM:\SOFTWARE\Eclipse Foundation\JDK"
    )
    
    foreach ($regPath in $jdkPaths) {
        if (Test-Path $regPath) {
            $versions = Get-ChildItem $regPath -ErrorAction SilentlyContinue
            foreach ($version in $versions) {
                if ($version.PSChildName -match "^(\d+)") {
                    $majorVersion = [int]$Matches[1]
                    if ($majorVersion -ge $MIN_JAVA_VERSION) {
                        Write-Host "Compatible JDK ($majorVersion) found in registry: $($version.PSPath)"
                        return $true
                    }
                }
            }
        }
    }
    
    # Method 3: Check common installation directories
    $commonPaths = @(
        "C:\Program Files\Eclipse Adoptium\jdk-17*",
        "C:\Program Files\Java\jdk-17*",
        "C:\Program Files\Microsoft\jdk-17*",
        "C:\Program Files\Zulu\zulu-17*"
    )
    
    foreach ($pathPattern in $commonPaths) {
        $found = Get-ChildItem -Path $pathPattern -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            Write-Host "Compatible JDK found at: $($found.FullName)"
            return $true
        }
    }
    
    Write-Host "Compatible JDK ($MIN_JAVA_VERSION+) not found. Proceeding with installation."
    return $false
}

# --- Install JDK Function ---
function Install-Jdk {
    Write-Host "Installing OpenJDK 17 ($ARCH)..."
    
    # 1. Download
    Write-Host "Downloading from: $JDK_DOWNLOAD_URL"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        # Use BITS for more reliable download, fallback to Invoke-WebRequest
        try {
            Start-BitsTransfer -Source $JDK_DOWNLOAD_URL -Destination $DOWNLOAD_PATH -ErrorAction Stop
        } catch {
            Write-Host "BITS transfer failed, using Invoke-WebRequest..."
            Invoke-WebRequest -Uri $JDK_DOWNLOAD_URL -OutFile $DOWNLOAD_PATH -UseBasicParsing
        }
    } catch {
        throw "Failed to download JDK: $($_.Exception.Message)"
    }
    
    if (-not (Test-Path $DOWNLOAD_PATH)) {
        throw "Download failed - installer file not found."
    }
    
    $fileSize = (Get-Item $DOWNLOAD_PATH).Length / 1MB
    Write-Host "Downloaded: $([math]::Round($fileSize, 2)) MB"
    
    # 2. Install silently using msiexec
    Write-Host "Installing JDK silently..."
    
    # MSI properties for Adoptium Temurin:
    # ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome
    # - FeatureMain: Core JDK files
    # - FeatureEnvironment: Add to PATH
    # - FeatureJarFileRunWith: Associate .jar files
    # - FeatureJavaHome: Set JAVA_HOME
    
    $msiArgs = @(
        "/i", "`"$DOWNLOAD_PATH`"",
        "/qn",  # Quiet, no UI
        "/norestart",
        "ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome",
        "INSTALLDIR=`"$INSTALL_DIR`"",
        "/l*v", "`"$TEMP_DIR\jdk_install.log`""
    )
    
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    
    if ($process.ExitCode -ne 0) {
        Write-Host "MSI installer returned exit code: $($process.ExitCode)"
        Write-Host "Check log file: $TEMP_DIR\jdk_install.log"
        
        # Common exit codes
        switch ($process.ExitCode) {
            1603 { throw "Installation failed (1603) - Fatal error during installation." }
            1618 { throw "Installation failed (1618) - Another installation is in progress." }
            1619 { throw "Installation failed (1619) - Installer package could not be opened." }
            3010 { Write-Host "Installation succeeded, but a reboot is required (3010)." }
            default { throw "Installation failed with exit code: $($process.ExitCode)" }
        }
    }
    
    # 3. Verify installation
    Write-Host "Verifying installation..."
    
    # Refresh PATH for this session
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    
    # Check if java is now available
    Start-Sleep -Seconds 2  # Give Windows a moment to update
    
    try {
        $javaCheck = & java -version 2>&1
        Write-Host "Java verification: $($javaCheck | Select-Object -First 1)"
    } catch {
        Write-Host "Note: Java may require a new terminal/reboot to appear in PATH."
    }
    
    # 4. Cleanup
    Remove-Item $DOWNLOAD_PATH -Force -ErrorAction SilentlyContinue
    
    Write-Host "OpenJDK 17 installed successfully to: $INSTALL_DIR"
    return $true
}

# --- Main Logic ---
try {
    if (-not $Force -and (Test-ExistingJdk)) {
        Write-Host "JDK prerequisite check passed."
        exit 0
    } else {
        if ($Force) {
            Write-Host "Force flag set - reinstalling JDK..."
        }
        
        if (Install-Jdk) {
            Write-Host "JDK installation complete."
            exit 0
        } else {
            Write-Host "JDK installation failed."
            exit 1
        }
    }
} catch {
    Write-Error "JDK installation failed: $($_.Exception.Message)"
    exit 1
}
