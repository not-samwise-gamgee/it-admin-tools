# Salesforce DataLoader Windows Install Script
# Installs latest stable DataLoader release for the current user, removes old versions, and installs JRE if needed.

param(
    [switch]$Force
)

# Set error action preference
$ErrorActionPreference = "Stop"

# ----------------------------------------------------
# --- Base System Variables (DEFINED FIRST)
# ----------------------------------------------------
$TEMP_DIR = [System.IO.Path]::GetTempPath()
$PROGRAM_FILES = ${env:ProgramFiles}

# ----------------------------------------------------
# --- JRE Variables
# ----------------------------------------------------
# Using OpenJDK for silent deployment
$JRE_DOWNLOAD_URL = "https://cdn.azul.com/zulu/bin/zulu21.0.3-sa-jdk21.0.3-win_x64.msi"
$JRE_MSI_NAME = "Zulu_OpenJDK_21_x64.msi"
$JRE_INSTALL_PATH = Join-Path $PROGRAM_FILES "Zulu\zulu-21"
$JRE_DOWNLOAD_PATH = Join-Path $TEMP_DIR $JRE_MSI_NAME

# ----------------------------------------------------
# --- DataLoader Variables
# ----------------------------------------------------
$DATALOADER_URL = "https://a.sfdcstatic.com/developer-website/media/dataloader/dataloader_v64.1.0.zip"
$DATALOADER_VERSION = "64.1.0"
$DOWNLOAD_PATH = Join-Path $TEMP_DIR "dataloader.zip"
$EXTRACT_PATH = Join-Path $TEMP_DIR "dataloader_extract"

# ----------------------------------------------------
# --- User Context Determination (CRITICAL for non-admin user installs)
# ----------------------------------------------------
$USERNAME = $null
$USER_PROFILE = $null

function Get-LoggedOnUserProfile {
    # 1. Try to find the active console session user
    $ActiveUser = query user | Select-String -Pattern "console"
    if ($ActiveUser) {
        # Extract the username
        $UsernameMatch = $ActiveUser.ToString() -split "\s+" | Where-Object { $_ -ne "" }
        if ($UsernameMatch.Length -ge 1) {
             # Get the first token that is not a session descriptor ('console', 'rdp', session ID, state, or empty)
             $USERNAME = ($ActiveUser.ToString() -split "\s+")[1..($ActiveUser.ToString() -split "\s+").Length] | 
                         Where-Object { $_ -ne "console" -and $_ -ne "rdp" -and $_ -ne "" -and $_ -notmatch '^\d+$' -and $_ -notmatch 'Active|Disc' } | 
                         Select-Object -First 1
        }
    }

    # 2. Get the profile path for the determined user
    if (-not [string]::IsNullOrEmpty($USERNAME)) {
        try {
            # Getting the SID and then the profile path from HKEY_USERS
            $UserSID = (New-Object System.Security.Principal.NTAccount($USERNAME)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            $ProfilePathKey = "Registry::HKEY_USERS\$UserSID\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
            $USER_PROFILE = (Get-ItemProperty -Path $ProfilePathKey -ErrorAction Stop).Desktop.Replace("\Desktop", "")
        } catch {
            Write-Warning "Failed to read user profile for $USERNAME from HKEY_USERS. Falling back to environment variable mapping."
            $USER_PROFILE = "C:\Users\$($USERNAME.Split('\')[-1])"
        }
    }

    # 3. Final Fallback if user lookup failed
    if ([string]::IsNullOrEmpty($USER_PROFILE) -or $USER_PROFILE -like "*systemprofile*") {
        Write-Warning "No active user session found. Falling back to current system profile ($($env:USERPROFILE)). Installation will likely fail for the end user."
        $USER_PROFILE = $env:USERPROFILE
    }

    # Define all user paths based on the CORRECT $USER_PROFILE (Set to script scope for use outside the function)
    if ($USER_PROFILE) {
        $APPDATA = Join-Path $USER_PROFILE "AppData\Roaming"
        $LOCALAPPDATA = Join-Path $USER_PROFILE "AppData\Local"
        
        $script:USER_INSTALL_PATH = Join-Path $LOCALAPPDATA "Programs\Salesforce DataLoader"
        $script:USER_CONFIG_PATH = Join-Path $APPDATA "dataloader"
        $script:DESKTOP_PATH = Join-Path $USER_PROFILE "Desktop"
        $script:START_MENU_PATH = Join-Path $APPDATA "Microsoft\Windows\Start Menu"
        
        $script:DESKTOP_SHORTCUT = Join-Path $DESKTOP_PATH "Data Loader.lnk"
        $script:START_MENU_SHORTCUT = Join-Path $START_MENU_PATH "Programs\Data Loader.lnk"

        Write-Host "Targeting User Profile: $USER_PROFILE"
    }
}

# Call the function to set the global user variables
Get-LoggedOnUserProfile

# ----------------------------------------------------
# --- JRE Helper Functions
# ----------------------------------------------------

function Test-JavaInstalled {
    # Check if the desired JRE (OpenJDK 21) is installed
    if (Test-Path $JRE_INSTALL_PATH) {
        Write-Host "Required JRE found at: $JRE_INSTALL_PATH"
        return $true
    }
    
    # Optional: Check if *any* JRE is in the system PATH
    try {
        & java -version 2>&1 | Select-String "version" | Out-Null
        Write-Host "Generic Java detected in PATH."
        return $true
    } catch {
        return $false
    }
}

function Install-JRE {
    Write-Host "Installing OpenJDK 21 JRE for system use..."
    
    # Download the MSI installer
    try {
        Invoke-WebRequest -Uri $JRE_DOWNLOAD_URL -OutFile $JRE_DOWNLOAD_PATH -UseBasicParsing
    } catch {
        # FIX: Using ${} to prevent parser error (e.g., when the URL contains a colon)
        throw "Failed to download JRE installer from ${JRE_DOWNLOAD_URL}: $($_.Exception.Message)"
    }
    
    # Execute the silent MSI install (requires System/Admin context)
    $msiArguments = @(
        "/i", "`"$JRE_DOWNLOAD_PATH`"",
        "/qn", # Quiet, no user interaction
        "/norestart", # Suppress reboot
        "INSTALLDIR=`"$JRE_INSTALL_PATH`"",
        "ADDLOCAL=ALL" # Install all features, including PATH update
    )
    
    try {
        Write-Host "Executing silent JRE installation..."
        # Wait for the MSI installation to complete
        Start-Process -FilePath msiexec.exe -ArgumentList $msiArguments -Wait -NoNewWindow
    } catch {
        throw "JRE installation failed. Error: $($_.Exception.Message)"
    }
    
    if (-not (Test-Path $JRE_INSTALL_PATH)) {
        throw "JRE installation failed or target directory was not created."
    }
    
    Write-Host "JRE installation completed successfully."
    Remove-Item $JRE_DOWNLOAD_PATH -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------
# --- DataLoader Helper Functions
# ----------------------------------------------------

function Get-InstalledVersion {
    # Check user installation path
    $userExe = Join-Path $USER_INSTALL_PATH "dataloader.exe"
    if (Test-Path $userExe) {
        try {
            $version = (Get-ItemProperty $userExe).VersionInfo.ProductVersion
            if ($version) { return $version }
        } catch {
            Write-Verbose "Could not read version from ${userExe}: $_"
        }
    }
    # Check registry (HKCU for user install)
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        $dataLoaderReg = Get-ItemProperty $regPath -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Data Loader*" }
        if ($dataLoaderReg) { return $dataLoaderReg.DisplayVersion }
    } catch {
        Write-Verbose "Could not read DataLoader version from registry: $_"
    }
    return $null
}

function Remove-OldDataLoader {
    # Runs non-interactively during MDM deployment; -WhatIf/-Confirm prompting is
    # intentionally not supported. Suppress to preserve behavior.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Non-interactive MDM install helper; must not prompt')]
    param()
    Write-Host "Removing old DataLoader installation..."
    Get-Process -Name "dataloader*" -ErrorAction SilentlyContinue | Stop-Process -Force
    if (Test-Path $USER_INSTALL_PATH) {
        Remove-Item $USER_INSTALL_PATH -Recurse -Force
    }
    if ($DESKTOP_SHORTCUT -and (Test-Path $DESKTOP_SHORTCUT)) { Remove-Item $DESKTOP_SHORTCUT -Force }
    if ($START_MENU_SHORTCUT -and (Test-Path $START_MENU_SHORTCUT)) { Remove-Item $START_MENU_SHORTCUT -Force }
    if (Test-Path $USER_CONFIG_PATH) {
        Remove-Item $USER_CONFIG_PATH -Recurse -Force
    }
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        Get-ItemProperty $regPath -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Data Loader*" } |
            ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
    } catch {
        Write-Warning "Could not clean HKCU registry: $($_.Exception.Message)"
    }
}

function Install-DataLoader {
    Write-Host "Downloading DataLoader $DATALOADER_VERSION..."
    try {
        Invoke-WebRequest -Uri $DATALOADER_URL -OutFile $DOWNLOAD_PATH -UseBasicParsing
    } catch {
        throw "Failed to download DataLoader: $($_.Exception.Message)"
    }
    
    if (Test-Path $EXTRACT_PATH) { Remove-Item $EXTRACT_PATH -Recurse -Force }
    Expand-Archive -Path $DOWNLOAD_PATH -DestinationPath $EXTRACT_PATH -Force
    
    $jarFile = Get-ChildItem -Path $EXTRACT_PATH -Filter "dataloader-*.jar" -Recurse | Select-Object -First 1
    if (-not $jarFile) { throw "DataLoader JAR file not found in downloaded package" }
    
    Write-Host "Found JAR file: $($jarFile.Name)"
    
    New-Item -Path $USER_INSTALL_PATH -ItemType Directory -Force | Out-Null
    Copy-Item $jarFile.FullName -Destination (Join-Path $USER_INSTALL_PATH "dataloader.jar")
    
    # Create batch file launcher to explicitly use the installed JRE
    $javaExePath = Join-Path $JRE_INSTALL_PATH "bin\java.exe"
    $batchContent = @"
@echo off
cd /d "%~dp0"
"$javaExePath" -jar dataloader.jar %*
"@
    $batchPath = Join-Path $USER_INSTALL_PATH "dataloader.bat"
    Set-Content -Path $batchPath -Value $batchContent
    
    # Create desktop shortcut
    if ($DESKTOP_SHORTCUT) {
        try {
            $WshShell = New-Object -ComObject WScript.Shell
            $Shortcut = $WshShell.CreateShortcut($DESKTOP_SHORTCUT)
            $Shortcut.TargetPath = (Join-Path $USER_INSTALL_PATH 'dataloader.bat')
            $Shortcut.WorkingDirectory = $USER_INSTALL_PATH
            $Shortcut.IconLocation = "cmd.exe,0"
            $Shortcut.Description = "Salesforce Data Loader"
            $Shortcut.Save()
        } catch {
            Write-Warning "Could not create desktop shortcut: $($_.Exception.Message)"
        }
    }
    
    Write-Host "Installed DataLoader to: $USER_INSTALL_PATH"
    Remove-Item $DOWNLOAD_PATH -Force -ErrorAction SilentlyContinue
    Remove-Item $EXTRACT_PATH -Recurse -Force -ErrorAction SilentlyContinue
}

function Set-SalesforceConfig {
    # Runs non-interactively during MDM deployment; -WhatIf/-Confirm prompting is
    # intentionally not supported. Suppress to preserve behavior.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Non-interactive MDM install helper; must not prompt')]
    param()
    Write-Host "Configuring DataLoader for [your-org].my.salesforce.com..."
    New-Item -Path $USER_CONFIG_PATH -ItemType Directory -Force | Out-Null
    $configContent = @"
sfdc.endpoint=https://[your-org].my.salesforce.com
sfdc.timeout=60000
sfdc.timeoutSecs=60
process.enableLastRunOutput=true
"@
    $configPath = Join-Path $USER_CONFIG_PATH "dataloader.properties"
    Set-Content -Path $configPath -Value $configContent
    Write-Host "Created configuration file: $configPath"
}

# ----------------------------------------------------
# --- Main Execution
# ----------------------------------------------------
try {
    Write-Host "Salesforce DataLoader Installation Script"
    Write-Host "========================================"
    Write-Host "Targeting OS User: $($USERNAME)"
    
    # 1. Check and Install JRE Prerequisite
    if (-not (Test-JavaInstalled)) {
        Write-Host "JRE not found. Starting installation..."
        Install-JRE
    } else {
        Write-Host "JRE prerequisite is met."
    }
    
    # 2. Install DataLoader
    $installedVersion = Get-InstalledVersion
    
    if ($installedVersion) {
        Write-Host "Found existing DataLoader version: $installedVersion"
        if ([version]$installedVersion -lt [version]$DATALOADER_VERSION -or $Force) {
            Remove-OldDataLoader
            Install-DataLoader
            Set-SalesforceConfig
        } else {
            Write-Host "DataLoader $installedVersion is already up to date."
            exit 0
        }
    } else {
        Write-Host "No existing DataLoader installation found."
        Install-DataLoader
        Set-SalesforceConfig
    }
    
    Write-Host ""
    Write-Host "Installation completed successfully!"
    Write-Host "DataLoader can be launched from: $USER_INSTALL_PATH\dataloader.bat"
    
} catch {
    Write-Error "Installation failed: $($_.Exception.Message)"
    exit 1
}