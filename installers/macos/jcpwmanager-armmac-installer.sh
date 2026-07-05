#!/bin/bash

#install JumpCloud Password Manager and assign permissions for standard users to update where applicable

#Exit on non-zero status and variable errors, report back individual pipefails  
set -euo pipefail   
set -x  # Enable shell debug tracing for troubleshooting

# Constants
readonly BASE_URL="https://cdn.pwm.jumpcloud.com/DA/release/arm64/JumpCloud-Password-Manager-latest.dmg"
TEMP_FOLDER=$(mktemp -d)
readonly TEMP_FOLDER
trap cleanup EXIT
readonly LOG_FILE="/tmp/jcpwmanager_install.log"
readonly CURL_OPTS=(    
    --silent
    --location
    --fail
    --retry 3
    --retry-delay 2
)

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
get_real_user_and_home


# Logging function
logger() {
    local level="$1"; shift
    local message="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

logger INFO "JumpCloud Password Manager installer started"

# Cleanup function

cleanup() {
    if [ -d "$TEMP_FOLDER" ]; then
        rm -rf "$TEMP_FOLDER"
    fi
}

# Download JumpCloud Password Manager DMG
DMG_PATH="$TEMP_FOLDER/JumpCloud-Password-Manager-latest.dmg"

logger INFO "Downloading DMG from $BASE_URL to $DMG_PATH"
if curl "${CURL_OPTS[@]}" "$BASE_URL" -o "$DMG_PATH"; then
    logger INFO "Download complete"
else
    logger ERROR "Failed to download DMG"
    exit 1
fi

# Debug: Confirm script progress and variable state after download
logger INFO "POST-DOWNLOAD DEBUG: TEMP_FOLDER is $TEMP_FOLDER, DMG_PATH is $DMG_PATH, LOG_FILE is $LOG_FILE"
echo "DEBUG: TEMP_FOLDER=$TEMP_FOLDER, DMG_PATH=$DMG_PATH, LOG_FILE=$LOG_FILE" >&2

# Helper function to log and exit on error
fail() {
    logger ERROR "$1"
    exit 1
}

logger INFO "Checking DMG file at $DMG_PATH before mount."
if [ ! -f "$DMG_PATH" ]; then
    logger ERROR "DMG file does not exist at $DMG_PATH"
    exit 1
fi
if [ ! -s "$DMG_PATH" ]; then
    logger ERROR "DMG file at $DMG_PATH is empty. Download may have failed."
    exit 1
fi
DMG_FILE_TYPE=$(file "$DMG_PATH")
logger INFO "DMG file type: $DMG_FILE_TYPE"

logger INFO "About to mount DMG at $DMG_PATH"
# Remove -quiet for debugging
MOUNT_OUTPUT=$(hdiutil attach "$DMG_PATH" -nobrowse 2>&1)
MOUNT_EXIT_CODE=$?
logger INFO "hdiutil attach output: $MOUNT_OUTPUT"
if [ $MOUNT_EXIT_CODE -ne 0 ]; then
    logger ERROR "Failed to mount DMG. Exit code: $MOUNT_EXIT_CODE. Output: $MOUNT_OUTPUT"
    exit 1
fi
MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | grep '/Volumes/' | sed -E 's/.*(\/Volumes\/.*)/\1/' | head -n1)
logger INFO "Mount point resolved as: $MOUNT_POINT"
if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
    logger ERROR "Mount point not found or not a directory. Output: $MOUNT_OUTPUT"
    exit 1
fi
logger INFO "Mounted at $MOUNT_POINT"

trap cleanup EXIT

# Install JumpCloud Password Manager from DMG
APP_NAME="JumpCloud Password Manager.app"
APP_SOURCE=$(find "$MOUNT_POINT" -maxdepth 1 -type d -name "$APP_NAME" | head -n 1)

if [ -z "$APP_SOURCE" ]; then
    logger ERROR "Could not find $APP_NAME in mounted DMG at $MOUNT_POINT"
    hdiutil detach "$MOUNT_POINT" || true
    exit 1
fi

# Always install to real user's ~/Applications
APP_DEST="$USER_HOME/Applications/$APP_NAME"
logger INFO "Preparing to copy $APP_NAME from $APP_SOURCE to $APP_DEST."
mkdir -p "$USER_HOME/Applications"
if cp -R "$APP_SOURCE" "$APP_DEST" 2> /tmp/jcpwmanager_copy_error.log; then
    logger INFO "Successfully copied $APP_NAME to $APP_DEST."
else
    logger ERROR "Failed to copy $APP_NAME to $APP_DEST. Error: $(cat /tmp/jcpwmanager_copy_error.log)"
    hdiutil detach "$MOUNT_POINT" || true
    exit 1
fi

# Set ownership for the user
chown -R "$USERNAME" "$APP_DEST"
chmod -R u+rwX "$APP_DEST"

# Verify installation
if [ -d "$APP_DEST" ]; then
    logger INFO "JumpCloud Password Manager successfully installed in $APP_DEST."
else
    logger ERROR "JumpCloud Password Manager not found after attempted install."
    hdiutil detach "$MOUNT_POINT" || true
    exit 1
fi

# Unmount DMG
logger INFO "Unmounting DMG at $MOUNT_POINT"
hdiutil detach "$MOUNT_POINT" -quiet || logger ERROR "Failed to unmount $MOUNT_POINT"
logger INFO "Cleanup complete."






