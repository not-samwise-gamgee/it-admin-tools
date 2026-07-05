#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# === CONFIG ===
LATEST_VERSION="25.2.2"
DMG_URL="https://www.dbvis.com/product_download/dbvis-25.2.2/media/dbvis_macos-aarch64_25_2_2.dmg"
DMG_FILE="dbvis_arm.dmg"
VOLUME_NAME="DbVisualizer"
APP_PATH="/Applications/DbVisualizer.app"
PLIST_PATH="$APP_PATH/Contents/Info.plist"
SILENT=0

# === FUNCTIONS ===
log() {
    if [[ "$SILENT" -eq 0 ]]; then
        echo "$1"
    fi
}

get_installed_version() {
    if [[ -d "$APP_PATH" && -f "$PLIST_PATH" ]]; then
        /usr/bin/defaults read "$PLIST_PATH" CFBundleShortVersionString 2>/dev/null || echo "None"
    else
        echo "None"
    fi
}

version_compare() {
    # returns 0 if v1 >= v2, 1 if v1 < v2
    # usage: version_compare 25.2.2 25.2.1
    [ "$1" = "$2" ] && return 0
    local IFS=.
    local i
    local ver1 ver2
    IFS=. read -r -a ver1 <<< "$1"
    IFS=. read -r -a ver2 <<< "$2"
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z "${ver2[i]}" ]]; then
            # e.g. 2.2.2 > 2.2
            return 0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 0
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 1
        fi
    done
    return 0
}

silent_flag_check() {
    for arg in "$@"; do
        if [[ "$arg" == "--silent" ]]; then
            SILENT=1
        fi
    done
}

install_dbvis() {
    log "Downloading DbVisualizer..."
    curl -L "$DMG_URL" -o "$DMG_FILE" ${SILENT:+-s}

    log "Mounting DMG..."
    MOUNT_POINT=$(hdiutil attach "$DMG_FILE" | grep "/Volumes/$VOLUME_NAME" | awk '{print $3}')

    log "Copying DbVisualizer to /Applications..."
    cp -R "$MOUNT_POINT/DbVisualizer.app" /Applications/

    log "Unmounting DMG..."
    hdiutil detach "$MOUNT_POINT"

    log "Cleaning up..."
    rm "$DMG_FILE"
}

# === MAIN SCRIPT ===
silent_flag_check "$@"
INSTALLED_VERSION=$(get_installed_version)
if [[ "$INSTALLED_VERSION" != "None" ]]; then
    if version_compare "$INSTALLED_VERSION" "$LATEST_VERSION"; then
        log "DbVisualizer $INSTALLED_VERSION is already up to date."
        exit 0
    else
        log "Updating DbVisualizer from $INSTALLED_VERSION to $LATEST_VERSION..."
        rm -rf "$APP_PATH"
        install_dbvis
        log "DbVisualizer updated to $LATEST_VERSION!"
        exit 0
    fi
else
    log "DbVisualizer not found. Installing version $LATEST_VERSION..."
    install_dbvis
    log "DbVisualizer $LATEST_VERSION installed!"
    exit 0
fi

