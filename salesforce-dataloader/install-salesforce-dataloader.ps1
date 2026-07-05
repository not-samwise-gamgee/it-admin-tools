# Salesforce DataLoader Windows Silent Install Script
# Uses official install.bat with silent mode parameters for MDM deployment.
# Requires: Java 17+ pre-installed

# Force is a declared part of the deployment interface (reserved to force reinstall);
# the current flow always reinstalls, so it is intentionally unused.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Force', Justification = 'Reserved deployment parameter; current flow always reinstalls')]
param(
    [switch]$Force
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Variables
$DATALOADER_URL = "https://a.sfdcstatic.com/developer-website/media/dataloader/dataloader_v64.1.0.zip"
$DATALOADER_VERSION = "64.1.0"
$TEMP_DIR = [System.IO.Path]::GetTempPath()
$DOWNLOAD_PATH = Join-Path $TEMP_DIR "dataloader.zip"
$EXTRACT_PATH = Join-Path $TEMP_DIR "dataloader_extract"

# Installation path (system-wide for MDM deployment)
$INSTALL_DIR = "C:\Program Files\dataloader"

# Get logged-in user when running as SYSTEM (MDM context)
function Get-LoggedInUser {
    try {
        $explorerProcess = Get-Process -Name "explorer" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($explorerProcess) {
            $cimProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$($explorerProcess.Id)"
            $owner = Invoke-CimMethod -InputObject $cimProcess -MethodName GetOwner
            return $owner.User
        }
    } catch {
        Write-Verbose "Could not determine logged-in user via explorer process: $_"
    }
    return $env:USERNAME
}

$LOGGED_IN_USER = Get-LoggedInUser
Write-Host "Detected logged-in user: $LOGGED_IN_USER"

# Verify Java 17+ is available before proceeding
function Find-JavaExecutable {
    # Refresh PATH from system environment (in case JDK was just installed)
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    
    # Method 1: Check if java is in PATH
    $javaInPath = Get-Command java -ErrorAction SilentlyContinue
    if ($javaInPath) {
        return $javaInPath.Source
    }
    
    # Method 2: Check common installation directories
    $commonPaths = @(
        "C:\Program Files\Eclipse Adoptium\jdk-*\bin\java.exe",
        "C:\Program Files\Java\jdk-*\bin\java.exe",
        "C:\Program Files\Microsoft\jdk-*\bin\java.exe",
        "C:\Program Files\Zulu\zulu-*\bin\java.exe",
        "C:\Program Files\Eclipse Adoptium\jdk*\bin\java.exe"
    )
    
    foreach ($pattern in $commonPaths) {
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }
    
    # Method 3: Check registry for JAVA_HOME
    $regPaths = @(
        "HKLM:\SOFTWARE\Eclipse Adoptium\JDK",
        "HKLM:\SOFTWARE\JavaSoft\JDK"
    )
    foreach ($regPath in $regPaths) {
        if (Test-Path $regPath) {
            $versions = Get-ChildItem $regPath -ErrorAction SilentlyContinue | Sort-Object -Descending
            foreach ($ver in $versions) {
                $javaHome = (Get-ItemProperty "$($ver.PSPath)\hotspot\MSI" -ErrorAction SilentlyContinue).Path
                if ($javaHome) {
                    $javaExe = Join-Path $javaHome "bin\java.exe"
                    if (Test-Path $javaExe) {
                        return $javaExe
                    }
                }
            }
        }
    }
    
    return $null
}

function Get-JavaVersion {
    param([string]$JavaPath)
    
    # Use cmd.exe to capture java -version output reliably (it outputs to stderr)
    $tempFile = Join-Path $env:TEMP "java_version_$([guid]::NewGuid().ToString('N')).txt"
    
    try {
        $null = Start-Process -FilePath "cmd.exe" `
            -ArgumentList "/c", "`"$JavaPath`" -version 2>&1" `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $tempFile
        
        if (Test-Path $tempFile) {
            $output = Get-Content $tempFile -Raw
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            return $output
        }
    } catch {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
    
    return $null
}

function Test-Java17 {
    $javaExe = Find-JavaExecutable
    
    if (-not $javaExe) {
        Write-Host "ERROR: Java not found in PATH or common locations."
        return $false
    }
    
    # Verify the file actually exists
    if (-not (Test-Path $javaExe)) {
        Write-Host "ERROR: Java executable not found at: $javaExe"
        return $false
    }
    
    Write-Host "Found Java at: $javaExe"
    
    # Get java version using cmd.exe for reliable stderr capture
    $outputText = Get-JavaVersion -JavaPath $javaExe
    
    if (-not $outputText) {
        Write-Host "WARNING: Could not get version from PATH java. Trying direct paths..."
        
        # Try known Adoptium paths directly
        $directPaths = @(
            "C:\Program Files\Eclipse Adoptium\jdk-17.0.12+7\bin\java.exe",
            "C:\Program Files\Eclipse Adoptium\jdk-17.0.11+9\bin\java.exe",
            "C:\Program Files\Eclipse Adoptium\jdk-17.0.10+7\bin\java.exe"
        )
        
        # Also search for any jdk-17* folder
        $adoptiumBase = "C:\Program Files\Eclipse Adoptium"
        if (Test-Path $adoptiumBase) {
            $jdkFolders = Get-ChildItem -Path $adoptiumBase -Directory -Filter "jdk-17*" -ErrorAction SilentlyContinue
            foreach ($folder in $jdkFolders) {
                $directPaths = @((Join-Path $folder.FullName "bin\java.exe")) + $directPaths
            }
        }
        
        foreach ($path in $directPaths) {
            if (Test-Path $path) {
                Write-Host "Trying: $path"
                $javaExe = $path
                $outputText = Get-JavaVersion -JavaPath $path
                if ($outputText) {
                    Write-Host "Found working Java at: $path"
                    break
                }
            }
        }
    }
    
    Write-Host "Java version output: $outputText"
    
    if (-not $outputText) {
        Write-Host "ERROR: Could not get Java version output."
        return $false
    }
    
    # Try multiple patterns to extract version
    $majorVersion = $null
    
    # Pattern 1: version "17.0.12" or version "17"
    if ($outputText -match 'version "(\d+)') {
        $majorVersion = [int]$Matches[1]
    }
    # Pattern 2: openjdk 17.0.12 or java 17.0.12
    elseif ($outputText -match '(?:openjdk|java)\s+(\d+)') {
        $majorVersion = [int]$Matches[1]
    }
    # Pattern 3: Runtime Environment.*(\d+)
    elseif ($outputText -match 'Runtime Environment[^\d]*(\d+)') {
        $majorVersion = [int]$Matches[1]
    }
    
    if ($majorVersion) {
        if ($majorVersion -ge 17) {
            Write-Host "Java $majorVersion detected."
            # Add to PATH for this session if not already there
            $javaDir = Split-Path $javaExe -Parent
            if ($env:Path -notlike "*$javaDir*") {
                $env:Path = "$javaDir;$env:Path"
            }
            return $true
        } else {
            Write-Host "ERROR: Java $majorVersion found, but Java 17+ is required."
            return $false
        }
    } else {
        Write-Host "ERROR: Could not parse Java version from output."
        return $false
    }
}

if (-not (Test-Java17)) {
    Write-Error "Java 17+ is required. Please install JDK 17 first."
    exit 1
}

# Helper: Remove old DataLoader installations
function Remove-OldDataLoader {
    # Runs non-interactively under SYSTEM during MDM deployment; -WhatIf/-Confirm
    # prompting is intentionally not supported. Suppress to preserve behavior.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Non-interactive MDM install helper; must not prompt')]
    param()
    Write-Host "Cleaning up old DataLoader installations..."

    # Stop any running DataLoader processes
    Get-Process -Name "dataloader*" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process -Name "java*" -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowTitle -like "*Data Loader*"
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    
    # Remove previous installations
    $pathsToRemove = @(
        $INSTALL_DIR,
        "C:\Program Files\Salesforce DataLoader",
        "C:\Program Files (x86)\Salesforce DataLoader",
        "$env:LOCALAPPDATA\Programs\Salesforce DataLoader"
    )
    
    foreach ($path in $pathsToRemove) {
        if (Test-Path $path) {
            try {
                Remove-Item $path -Recurse -Force
                Write-Host "Removed: $path"
            } catch {
                Write-Warning "Could not remove $path : $($_.Exception.Message)"
            }
        }
    }
    
    # Remove shortcuts from all user profiles
    $userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notin @("Public", "Default", "Default User") }
    foreach ($userDir in $userProfiles) {
        $shortcuts = @(
            (Join-Path $userDir.FullName "Desktop\Data Loader.lnk"),
            (Join-Path $userDir.FullName "Desktop\dataloader.lnk"),
            (Join-Path $userDir.FullName "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Data Loader.lnk")
        )
        foreach ($shortcut in $shortcuts) {
            if (Test-Path $shortcut) {
                Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Helper: Install DataLoader using official installer with silent mode
function Install-DataLoader {
    Write-Host "Downloading DataLoader $DATALOADER_VERSION..."
    
    # Download the zip file
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $DATALOADER_URL -OutFile $DOWNLOAD_PATH -UseBasicParsing
    } catch {
        throw "Failed to download DataLoader: $($_.Exception.Message)"
    }
    
    # Extract the zip file
    if (Test-Path $EXTRACT_PATH) {
        Remove-Item $EXTRACT_PATH -Recurse -Force
    }
    Expand-Archive -Path $DOWNLOAD_PATH -DestinationPath $EXTRACT_PATH -Force
    
    # Find install.bat
    $installBat = Get-ChildItem -Path $EXTRACT_PATH -Filter "install.bat" -Recurse | Select-Object -First 1
    
    if (-not $installBat) {
        throw "install.bat not found in downloaded package"
    }
    
    Write-Host "Found installer at: $($installBat.FullName)"
    $extractDir = $installBat.DirectoryName
    
    # Run official installer with silent mode parameters
    Write-Host "Running silent installation to $INSTALL_DIR..."
    
    $installArgs = @(
        "salesforce.installation.dir=`"$INSTALL_DIR`"",
        "salesforce.installation.shortcut.desktop=false",
        "salesforce.installation.shortcut.windows.startmenu=false"
    )
    
    # Pipe "Yes" to handle any prompts
    Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", "echo Yes | `"$($installBat.FullName)`" $($installArgs -join ' ')" `
        -WorkingDirectory $extractDir `
        -Wait `
        -NoNewWindow
    
    # Verify installation
    if (-not (Test-Path $INSTALL_DIR)) {
        Write-Host "Silent install may have failed. Attempting manual setup..."
        New-Item -Path $INSTALL_DIR -ItemType Directory -Force | Out-Null
        Copy-Item "$extractDir\*" -Destination $INSTALL_DIR -Recurse -Force
    }
    
    # Ensure configs directory exists and is writable
    $configsDir = Join-Path $INSTALL_DIR "configs"
    if (-not (Test-Path $configsDir)) {
        New-Item -Path $configsDir -ItemType Directory -Force | Out-Null
    }
    
    # Set permissions - allow Users to modify configs
    try {
        $acl = Get-Acl $configsDir
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Users", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $acl.SetAccessRule($rule)
        Set-Acl -Path $configsDir -AclObject $acl
        Write-Host "Set write permissions on configs directory."
    } catch {
        Write-Warning "Could not set permissions on configs: $($_.Exception.Message)"
    }
    
    # Create Start Menu shortcut for all users
    $startMenuPath = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs"
    $shortcutPath = Join-Path $startMenuPath "Data Loader.lnk"
    
    try {
        $dataloaderExe = Join-Path $INSTALL_DIR "dataloader.exe"
        $dataloaderBat = Join-Path $INSTALL_DIR "dataloader.bat"
        
        # Prefer .exe if it exists, otherwise use .bat
        $targetPath = if (Test-Path $dataloaderExe) { $dataloaderExe } else { $dataloaderBat }
        
        if (Test-Path $targetPath) {
            $WshShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WshShell.CreateShortcut($shortcutPath)
            $Shortcut.TargetPath = $targetPath
            $Shortcut.WorkingDirectory = $INSTALL_DIR
            $Shortcut.Description = "Salesforce Data Loader $DATALOADER_VERSION"
            $Shortcut.Save()
            Write-Host "Created Start Menu shortcut: $shortcutPath"
        }
    } catch {
        Write-Warning "Could not create Start Menu shortcut: $($_.Exception.Message)"
    }
    
    Write-Host "Installation complete at: $INSTALL_DIR"
    
    # Cleanup
    Remove-Item $DOWNLOAD_PATH -Force -ErrorAction SilentlyContinue
    Remove-Item $EXTRACT_PATH -Recurse -Force -ErrorAction SilentlyContinue
}

# Main execution
try {
    Write-Host "Salesforce DataLoader Silent Installation Script"
    Write-Host "================================================"
    Write-Host ""
    
    # Remove old installations
    Remove-OldDataLoader
    
    # Install DataLoader
    Install-DataLoader
    
    Write-Host ""
    Write-Host "Installation completed successfully!"
    Write-Host "DataLoader installed to: $INSTALL_DIR"
    Write-Host "Users can launch from Start Menu or: $INSTALL_DIR\dataloader.bat"
    
    exit 0
    
} catch {
    Write-Error "Installation failed: $($_.Exception.Message)"
    exit 1
}
