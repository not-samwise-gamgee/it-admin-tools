#!/bin/bash

set -euo pipefail

# MDM logging setup
readonly LOG_FILE
LOG_FILE="/var/log/googledrive_install.log"
touch "$LOG_FILE" 2>/dev/null || true

# Logging and error handling functions
log() {
    local level=""
    level="$1"
    shift
    local msg=""
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

die() {
    log "ERROR" "$*"
    exit 1
}

# Cleanup function
cleanup() {
    local exit_code=$?
    
    # Record exit code for later
    if [ $exit_code -ne 0 ]; then
        log "WARN" "Script exited with code: $exit_code"
    fi
    
    # Verify final state on success
    if [ $exit_code -eq 0 ]; then
        if [ -d "$DRIVE_APP" ]; then
            new_version=$(get_app_version "$DRIVE_APP")
            log "INFO" "Installation completed. New version: $new_version"
        else
            log "ERROR" "Installation verification failed - app not found"
            exit_code=73
        fi
    fi
    
    # Clean up
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        log "INFO" "Cleaning up mount point: $MOUNT_POINT"
        diskutil unmount force "$MOUNT_POINT" || true
    fi
    
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log "INFO" "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
    
    exit $exit_code
}

# Get logged in user (when run as root via MDM)
get_user() {
    # Try multiple methods to get the user in MDM context
    local console_user=""
    
    # Method 1: Check console user
    if ! console_user=$(stat -f '%Su' /dev/console 2>/dev/null); then
        log "WARN" "Failed to get console user"
    fi
    
    # Method 2: Check for logged in users
    if [ -z "$console_user" ]; then
        console_user=$(who | grep 'console' | head -1 | awk '{print $1}')
    fi
    
    # Method 3: Check last logged in user
    if [ -z "$console_user" ]; then
        console_user=$(last -1 -t console | awk 'NR==1 {print $1}')
    fi
    
    if [ -z "$console_user" ]; then
        die "Could not determine target user for installation"
    fi
    
    echo "$console_user"
}

# Function to get user home directory
get_user_home() {
    local user=""
    user="$1"
    local home_dir=""
    
    if [ -n "$user" ]; then
        if ! home_dir=$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}'); then
            die "Failed to get home directory for user: $user"
        fi
        if [ -n "$home_dir" ] && [ -d "$home_dir" ]; then
            echo "$home_dir"
            return 0
        fi
    fi
    
    die "Could not determine home directory for user: $user"
}

# Constants
readonly BASE_DOWNLOAD_URL
BASE_DOWNLOAD_URL="https://dl.google.com/drive-file-stream/GoogleDrive.dmg"
readonly TARGET_USER
TARGET_USER=$(get_user)
readonly USER_HOME
USER_HOME=$(get_user_home "$TARGET_USER")
readonly DRIVE_APP
DRIVE_APP="$USER_HOME/Applications/Google Drive.app"
readonly CURL_OPTS
CURL_OPTS=(
    --silent
    --show-error
    --fail
    --location
    --retry 3
    --retry-delay 5
    --no-progress-meter
)
readonly TEMP_DIR
TEMP_DIR=$(mktemp -d)
readonly MOUNT_POINT
MOUNT_POINT=""

# Version check function
get_app_version() {
    local app_path=""
    app_path="$1"
    local version=""
    local plist_path=""
    
    if [ ! -d "$app_path" ]; then
        echo "unknown"
        return 0
    fi
    
    plist_path="$app_path/Contents/Info.plist"
    if [ ! -f "$plist_path" ]; then
        echo "unknown"
        return 0
    fi
    
    if ! version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist_path" 2>/dev/null); then
        echo "unknown"
        return 0
    fi
    
    echo "$version"
}

# Function to verify installation
verify_installation() {
    local installed_version=""
    
    if ! installed_version=$(get_app_version "$USER_HOME/Applications/Google Drive.app"); then
        die "Installation verification failed: Could not get installed version"
    fi
    
    if [ "$installed_version" = "unknown" ]; then
        die "Installation verification failed: App not found or version unknown"
    fi
    
    log "INFO" "Successfully installed Google Drive version: $installed_version"
}

# Get download URL with verification
get_download_url() {
    local url=""
    url="$1"
    local response=""
    
    log "INFO" "Verifying download URL"
    if ! response=$(curl "${CURL_OPTS[@]}" --head "$url"); then
        log "ERROR" "Failed to verify download URL"
        exit 71
    fi
    
    # Verify it's a DMG
    if ! echo "$response" | grep -q "application/x-apple-diskimage"; then
        log "ERROR" "URL does not point to a DMG file"
        exit 71
    fi
    
    echo "$url"
}

# Get the actual download URL
readonly DOWNLOAD_URL
DOWNLOAD_URL=$(get_download_url "$BASE_DOWNLOAD_URL") || exit 71

# Ensure ~/Applications directory exists
if [ ! -d "$USER_HOME/Applications" ]; then
    log "INFO" "Creating ~/Applications directory"
    mkdir -p "$USER_HOME/Applications"
    chown -R "$TARGET_USER:staff" "$USER_HOME/Applications"
    chmod 755 "$USER_HOME/Applications"
fi

# Check if Google Drive is already installed
if [ -d "$DRIVE_APP" ]; then
    current_version=$(get_app_version "$DRIVE_APP")
    log "INFO" "Current Google Drive version: $current_version"
    
    log "INFO" "Stopping Google Drive"
    killall "Google Drive" 2>/dev/null || true
    pkill -f "Google Drive" 2>/dev/null || true
    sleep 2  # Wait for app to fully close
    
    log "INFO" "Removing old Google Drive installation"
    rm -rf "$DRIVE_APP" || {
        log "ERROR" "Failed to remove existing installation"
        exit 74  # Exit code for removal failure
    }
fi

# Set cleanup trap
trap 'cleanup' EXIT

# Navigate to Temp Folder
cd "$TEMP_DIR" || exit 1

# Check available disk space (need at least 1GB)
log "INFO" "Checking available disk space"
check_disk_space() {
    local available_space=""
    if ! available_space=$(df -k "$USER_HOME" | awk 'NR==2 {print $4}'); then
        die "Failed to check disk space"
    fi
    
    if [ "$available_space" -lt 1048576 ]; then  # 1GB in KB
        die "Insufficient disk space. Need at least 1GB free in $USER_HOME"
    fi
}
check_disk_space

# Download File with timeout and retry
log "INFO" "Downloading Google Drive installer"
download_dmg() {
    local temp_dir=""
    temp_dir="$1"
    local dmg_path
    dmg_path="$temp_dir/GoogleDrive.dmg"
    
    log "INFO" "Downloading Google Drive DMG"
    if ! curl "${CURL_OPTS[@]}" --connect-timeout 30 --max-time 300 -o "$dmg_path" "$DOWNLOAD_URL"; then
        die "Failed to download DMG"
    fi
    
    echo "$dmg_path"
}
dmg_path=$(download_dmg "$TEMP_DIR")

# Verify DMG integrity
log "INFO" "Verifying DMG integrity"
if ! hdiutil verify "$dmg_path" >/dev/null 2>&1; then
    die "DMG file is corrupted. Please try again"
fi

# Mount DMG with retries and better error handling
log "INFO" "Mounting Google Drive DMG"
mount_dmg() {
    local dmg_path=""
    dmg_path="$1"
    local mount_point=""
    
    if ! mount_point=$(hdiutil attach -nobrowse -noverify "$dmg_path" | grep "Install Google Drive" | cut -f 3-); then
        die "Failed to mount DMG"
    fi
    
    if [ ! -d "$mount_point" ]; then
        die "Invalid mount point: $mount_point"
    fi
    
    echo "$mount_point"
}
if ! MOUNT_POINT=$(mount_dmg "$dmg_path"); then
    die "Failed to mount DMG"
fi

log "INFO" "DMG mounted at: $MOUNT_POINT"

# Find the installer package
PKG_PATH=$(find "$MOUNT_POINT" -maxdepth 2 -name "*.pkg" -print -quit)
if [ -z "$PKG_PATH" ]; then
    die "Could not find installer package in DMG"
fi

log "INFO" "Found installer package: $PKG_PATH"

# Install the package to root first (required by package)
log "INFO" "Installing Google Drive package"
if ! installer -pkg "$PKG_PATH" -target /; then
    log "ERROR" "Package installation failed"
    exit 72 # Exit code for MDM to detect installation failure
fi

# Unmount DMG
log "INFO" "Unmounting Google Drive DMG"
hdiutil detach "$MOUNT_POINT" -force || true

# Wait for installation to complete
sleep 5

# Move to user's Applications directory with space check
if [ -d "/Applications/Google Drive.app" ]; then
    log "INFO" "Moving Google Drive to user's Applications folder"
    
    # Check space required for the move
    app_size=$(du -sk "/Applications/Google Drive.app" | awk '{print $1}')
    available_space=$(df -k "$USER_HOME/Applications" | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -lt "$app_size" ]; then
        die "Insufficient space in $USER_HOME/Applications. Need ${app_size}KB free"
    fi
    
    # Ensure target directory exists
    mkdir -p "$USER_HOME/Applications"
    
    # Remove existing installation if present
    if [ -d "$DRIVE_APP" ]; then
        log "INFO" "Removing existing installation"
        rm -rf "$DRIVE_APP" || exit 70
    fi
    
    # Move the app with progress
    log "INFO" "Moving Google Drive.app (${app_size}KB)"
    if ! mv "/Applications/Google Drive.app" "$USER_HOME/Applications/"; then
        log "ERROR" "Failed to move Google Drive.app to user Applications directory"
        exit 70 # Exit code for MDM to detect move failure
    fi
    
    # Verify the move
    if [ ! -d "$DRIVE_APP" ]; then
        die "Google Drive.app not found after moving to $USER_HOME/Applications"
    fi
else
    die "Google Drive.app not found after installation"
fi

# Set proper ownership and permissions
chown -R "$TARGET_USER:staff" "$DRIVE_APP"
chmod -R 755 "$DRIVE_APP"

# Verify installation
verify_installation

# Wait for plist to be available
sleep 2

# Function to launch app
launch_app() {
    log "INFO" "Launching Google Drive"
    if ! sudo -u "$TARGET_USER" open -a "Google Drive"; then
        log "WARN" "Failed to launch Google Drive"
    fi
}

# Handle app launch based on deployment mode
if [ -z "${MDM_SILENT:-}" ]; then
    launch_app
fi

log "INFO" "Google Drive installation complete"