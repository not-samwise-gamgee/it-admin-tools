#Install Workday Adaptive Planning plugin and Office Connect add-in for Excel
# --- PARAMETERS ---

# Workday Adaptive Planning Excel Interface
$adaptivePlanningUrl = "https://clickonce.adaptiveinsights.com/planning/latest/WorkdayAdaptivePlanningExcelMachineSetup.exe"

# Workday Office Connect
$officeConnectUrl = "https://clickonce.adaptiveinsights.com/officeconnect/latest/OfficeConnectMachineSetup.exe"

$tempDir = "$env:TEMP\WorkdayEIP"

$adaptiveInstallerPath = "$tempDir\adaptive-installer.exe"
$officeConnectInstallerPath = "$tempDir\officeconnect-installer.exe"



# --- 1. SETUP AND DOWNLOAD ---


Write-Host "Creating temp directory..."


if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force }



Write-Host "Downloading installers from official Workday sources..."

# Function to download and validate installer
function Get-ValidatedInstaller {
    param(
        [string]$Url,
        [string]$OutputPath,
        [string]$ProductName
    )
    
    try {
        Write-Host "Downloading $ProductName installer..."
        Invoke-WebRequest -Uri $Url -OutFile $OutputPath -ErrorAction Stop
        Write-Host "✓ $ProductName download completed successfully."
        
        # Validate downloaded file
        if (-not (Test-Path $OutputPath)) {
            throw "Downloaded file not found at $OutputPath"
        }
        
        $fileSize = (Get-Item $OutputPath).Length
        if ($fileSize -lt 1MB) {
            throw "Downloaded file appears to be invalid (size: $fileSize bytes)"
        }
        
        Write-Host "✓ $ProductName file validation passed. Size: $([math]::Round($fileSize/1MB, 2)) MB"
        return $true
        
    } catch {
        Write-Error "Failed to download or validate $ProductName installer from $Url. Error: $($_.Exception.Message)"
        return $false
    }
}

# Download both installers
$adaptiveSuccess = Get-ValidatedInstaller -Url $adaptivePlanningUrl -OutputPath $adaptiveInstallerPath -ProductName "Workday Adaptive Planning"
$officeConnectSuccess = Get-ValidatedInstaller -Url $officeConnectUrl -OutputPath $officeConnectInstallerPath -ProductName "Workday Office Connect"

if (-not $adaptiveSuccess -or -not $officeConnectSuccess) {
    Write-Error "One or more downloads failed. Exiting installation."
    exit 1
}



# --- 2. SILENT INSTALLATION ---


Write-Host "Starting silent per-machine installations..."

# Enhanced silent installation parameters for complete non-interactive installation
# /S = Silent mode, /SILENT = Alternative silent flag, /SUPPRESSMSGBOXES = Suppress all dialog boxes
# /NORESTART = Prevent automatic restart, /FORCECLOSEAPPLICATIONS = Close apps if needed

$installArgs = @(
    "/S",
    "/SILENT", 
    "/SUPPRESSMSGBOXES",
    "/NORESTART",
    "/FORCECLOSEAPPLICATIONS"
)

# Function to install a product
function Install-WorkdayProduct {
    param(
        [string]$InstallerPath,
        [string]$ProductName,
        [array]$Arguments
    )
    
    Write-Host "Installing $ProductName..."
    Write-Host "Installation arguments: $($Arguments -join ' ')"
    
    try {
        $exitCode = (Start-Process -FilePath $InstallerPath -ArgumentList $Arguments -Wait -PassThru).ExitCode
        return @{
            ExitCode = $exitCode
            ProductName = $ProductName
        }
    } catch {
        Write-Error "Failed to start installation for $ProductName. Error: $($_.Exception.Message)"
        return @{
            ExitCode = -1
            ProductName = $ProductName
        }
    }
}

# Install both products
Write-Host "=== Installing Workday Adaptive Planning ==="
$adaptiveResult = Install-WorkdayProduct -InstallerPath $adaptiveInstallerPath -ProductName "Workday Adaptive Planning" -Arguments $installArgs

Write-Host "`n=== Installing Workday Office Connect ==="
$officeConnectResult = Install-WorkdayProduct -InstallerPath $officeConnectInstallerPath -ProductName "Workday Office Connect" -Arguments $installArgs



# Function to handle exit codes with detailed logging
function Test-InstallationResult {
    param(
        [hashtable]$Result
    )
    
    $exitCode = $Result.ExitCode
    $productName = $Result.ProductName
    
    Write-Host "`n--- $productName Installation Result ---"
    
    switch ($exitCode) {
        0 { 
            Write-Host "✓ $productName installation completed successfully."
            return $true
        }
        3010 { 
            Write-Host "✓ $productName installation completed successfully but requires restart."
            Write-Host "Note: A system restart may be required for full functionality."
            return $true
        }
        1602 {
            Write-Error "$productName installation cancelled by user or system policy."
            return $false
        }
        1603 {
            Write-Error "$productName installation failed with fatal error. Check system requirements."
            return $false
        }
        1618 {
            Write-Error "$productName installation failed - another installation is already in progress."
            return $false
        }
        1633 {
            Write-Error "$productName installation failed - package not supported on this platform."
            return $false
        }
        -1 {
            Write-Error "$productName installation failed to start."
            return $false
        }
        default {
            Write-Error "$productName installation failed with exit code: $exitCode"
            Write-Error "Please check the Windows Event Log for more details."
            return $false
        }
    }
}

# Process installation results
Write-Host "`n=== Processing Installation Results ==="
$adaptiveSuccess = Test-InstallationResult -Result $adaptiveResult
$officeConnectSuccess = Test-InstallationResult -Result $officeConnectResult

# Overall result
if ($adaptiveSuccess -and $officeConnectSuccess) {
    Write-Host "`n✓ All installations completed successfully!"
} elseif ($adaptiveSuccess -or $officeConnectSuccess) {
    Write-Warning "Some installations completed successfully, but others failed."
    Write-Host "Successfully installed:"
    if ($adaptiveSuccess) { Write-Host "  - Workday Adaptive Planning" }
    if ($officeConnectSuccess) { Write-Host "  - Workday Office Connect" }
    exit 1
} else {
    Write-Error "All installations failed."
    exit 1
}



# --- 3. CLEANUP ---


Write-Host "Cleaning up temporary files..."
try {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction Stop
    Write-Host "✓ Cleanup completed successfully."
} catch {
    Write-Warning "Failed to clean up temporary directory: $($_.Exception.Message)"
    # Don't exit on cleanup failure - installation was successful
}

Write-Host "`n=== Installation Summary ==="
Write-Host "Products Installed:"
Write-Host "  - Workday Adaptive Planning Excel Interface"
Write-Host "  - Workday Office Connect"
Write-Host "Installation Type: Machine-wide (all users)"
Write-Host "Download Source: Official Workday CDN"
Write-Host "Status: Completed successfully"
Write-Host "=============================="