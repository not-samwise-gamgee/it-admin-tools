#!/bin/bash

#install Figma MacOS Desktop app
#check permissions and add logic to enable standard users to approve app updates without admin credentials

#Exit on non-zero status and variable errors, report back individual pipefails  
set -euo pipefail   
set -x  # Enable shell debug tracing for troubleshooting

# Constants
readonly BASE_URL="https://www.figma.com/download/desktop/mac"
TEMP_FOLDER=$(mktemp -d)
readonly TEMP_FOLDER
readonly LOG_FILE="/tmp/figma-macos-desktop-installer.log"

# Determine the real user and their home directory
get_real_user_and_home() {
    # If running as root (MDM), get the console user
    if [ "$EUID" -eq 0 ]; then
        USERNAME=$(stat -f "%Su" /dev/console)
        USER_HOME=$(dscl . -read /Users/"$USERNAME" NFSHomeDirectory | awk '{print $2}')
    else
        USERNAME="$USER"
        USER_HOME="$HOME"
    fi
    if [ -z "$USERNAME" ] || [ -z "$USER_HOME" ]; then
        logger ERROR "Could not determine real user or home directory"
        exit 1
    fi
}

# Download the latest Figma DMG with retries and integrity check
FIGMA_DMG="$TEMP_FOLDER/Figma.dmg"
download_figma_dmg() {
    local retries=3
    local delay=5
    local attempt=1
    while [ $attempt -le $retries ]; do
        logger INFO "Downloading Figma DMG (attempt $attempt/$retries) from $BASE_URL"
        if curl -fL "$BASE_URL" -o "$FIGMA_DMG"; then
            logger INFO "Download successful. Verifying DMG integrity."
            if hdiutil verify "$FIGMA_DMG" >/dev/null 2>&1; then
                logger INFO "DMG verified successfully."
                return 0
            else
                logger ERROR "DMG integrity check failed."
            fi
        else
            logger ERROR "Download failed."
        fi
        attempt=$((attempt+1))
        sleep $delay
    done
    logger ERROR "Failed to download and verify Figma DMG after $retries attempts."
    exit 1
}

# Mount the DMG and get the mount point
MOUNT_POINT=""
mount_dmg() {
    logger INFO "Mounting DMG: $FIGMA_DMG"
    local plist_output mount_point
    plist_output=$(hdiutil attach "$FIGMA_DMG" -nobrowse -plist 2>/dev/null)
    mount_point=$(echo "$plist_output" | awk -F '<string>|</string>' '/<key>mount-point<\/key>/ {getline; print $2; exit}')
    if [ -z "$mount_point" ]; then
        # Fallback: try to find the most recently mounted /Volumes entry
        # shellcheck disable=SC2012  # volume names are alphanumeric; -t sort by mtime is intended
        mount_point=$(ls -td /Volumes/* | head -1)
    fi
    if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
        logger ERROR "Could not detect mount point."
        exit 1
    fi
    MOUNT_POINT="$mount_point"
    logger INFO "Mounted at $MOUNT_POINT"
}

# Install Figma.app to /Applications or user's ~/Applications
install_figma_app() {
    local app_source="$MOUNT_POINT/Figma.app"
    local app_target="/Applications/Figma.app"
    if [ "$EUID" -eq 0 ]; then
        # Try system-wide install first
        logger INFO "Copying Figma.app to $app_target"
        rm -rf "$app_target"
        cp -R "$app_source" "$app_target" || {
            logger ERROR "Failed to copy Figma.app to /Applications. Trying user Applications."
            app_target="$USER_HOME/Applications/Figma.app"
            mkdir -p "$USER_HOME/Applications"
            rm -rf "$app_target"
            cp -R "$app_source" "$app_target" || {
                logger ERROR "Failed to copy Figma.app to user Applications folder."
                exit 1
            }
        }
    else
        app_target="$USER_HOME/Applications/Figma.app"
        mkdir -p "$USER_HOME/Applications"
        logger INFO "Copying Figma.app to $app_target"
        rm -rf "$app_target"
        cp -R "$app_source" "$app_target" || {
            logger ERROR "Failed to copy Figma.app to user Applications folder."
            exit 1
        }
    fi
    logger INFO "Figma.app installed to $app_target"
    # Remove quarantine attribute to prevent 'Please move the Figma app...' warning
    if [ -d "$app_target" ]; then
        xattr -dr com.apple.quarantine "$app_target" && logger INFO "Removed quarantine attribute from $app_target"
    fi
}

# Check if the user is a standard (non-admin) user
is_standard_user() {
    if dscl . -read /Groups/admin GroupMembership | grep -qw "$USERNAME"; then
        return 1  # Admin
    else
        return 0  # Standard
    fi
}

# Set correct permissions for user updates (only for standard users)
set_permissions() {
    local app_target
    if [ -d "/Applications/Figma.app" ]; then
        app_target="/Applications/Figma.app"
    else
        app_target="$USER_HOME/Applications/Figma.app"
    fi
    if is_standard_user; then
        logger INFO "$USERNAME is a standard user. Setting ownership and update permissions on $app_target."
        chown -R "$USERNAME" "$app_target"
        chmod -R u+rwX,go+rX "$app_target"
        logger INFO "Permissions set to allow standard user updates."
    else
        logger INFO "$USERNAME is an admin user. No special permission changes needed."
    fi
}

# Cleanup: unmount DMG and remove temp files
cleanup() {
    logger INFO "Cleaning up..."
    if [ -n "$MOUNT_POINT" ] && mount | grep -q "$MOUNT_POINT"; then
        hdiutil detach "$MOUNT_POINT" -quiet || logger ERROR "Failed to unmount $MOUNT_POINT"
    fi
    rm -rf "$TEMP_FOLDER"
    logger INFO "Cleanup complete."
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Main control flow
main() {
    get_real_user_and_home
    logger INFO "Starting Figma macOS Desktop installer."
    download_figma_dmg
    mount_dmg
    install_figma_app
    set_permissions
    logger INFO "Figma installation complete."
}

main
get_real_user_and_home

# Logging function
logger() {
    local level="$1"; shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}