#PowerShell script for silent AWS VPN Client install via JumpCloud MDM

#----- CONFIGURATION -----
$msiUrl = "https://d20adtppz83p9s.cloudfront.net/WPF/latest/AWS_VPN_Client.msi"
$msiPath = "C:\Windows\Temp\AWS_VPN_Client.msi"   # Hardcoded for reliability in SYSTEM context
$logPath = "C:\Windows\Temp\aws_vpnclient_install.log"

#----- DOWNLOAD -----
try {
    Write-Output "Downloading AWS VPN Client MSI from $msiUrl to $msiPath..."
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -ErrorAction Stop
    Write-Output "Download complete. Checking file existence..."
    if (-not (Test-Path $msiPath)) {
        Write-Error "Download failed: $msiPath does not exist."
        exit 2
    }
} catch {
    Write-Error "Failed to download AWS VPN Client MSI: $_"
    exit 1
}

# ----- INSTALL -----
try {
    Write-Output "Installing AWS VPN Client silently..."
    $arguments = @("/i", $msiPath, "/qn", "/norestart", "/log", $logPath)
    Write-Output "Running: msiexec.exe $($arguments -join ' ')"
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        Write-Error "AWS VPN Client installation failed with exit code $($process.ExitCode). See $logPath for details."
        exit $process.ExitCode
    }
} catch {
    Write-Error "Failed to install AWS VPN Client: $_"
    exit 3
}

# ----- CLEANUP -----
try {
    Remove-Item $msiPath -Force
} catch {
    Write-Warning "Failed to remove MSI file: $_"
}

Write-Output "AWS VPN Client installed successfully. Log: $logPath"