#!/bin/bash
# shellcheck shell=bash

set -euo pipefail
IFS=$'\n\t'

# === CONFIG ===
DMG_URL_PRIMARY="https://dbeaver.io/files/dbeaver-ce-latest-macos-aarch64.dmg"
DMG_FILE="dbeaver_arm.dmg"
APP_PATH="/Applications/DBeaver.app"
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
    [ "$1" = "$2" ] && return 0
    local IFS=.
    local i
    local ver1 ver2
    IFS=. read -r -a ver1 <<< "$1"
    IFS=. read -r -a ver2 <<< "$2"
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z "${ver2[i]}" ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 0
        elif ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 1
        fi
    done
    return 0
}

# === MAIN ===
log "Checking for existing DBeaver installation..."
INSTALLED_VERSION=$(get_installed_version)

if [[ "$INSTALLED_VERSION" != "None" ]]; then
    log "DBeaver is already installed (version: $INSTALLED_VERSION). Proceeding to update."
else
    log "No existing DBeaver installation found. Proceeding with install."
fi

LATEST_VERSION=$(/usr/bin/curl -s "https://api.github.com/repos/dbeaver/dbeaver/releases/latest" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || true)
INSTALLED_VERSION_NORM="${INSTALLED_VERSION#v}"
LATEST_VERSION_NORM="${LATEST_VERSION#v}"

if [[ "$INSTALLED_VERSION" != "None" && -n "$LATEST_VERSION_NORM" ]]; then
    if version_compare "$INSTALLED_VERSION_NORM" "$LATEST_VERSION_NORM"; then
        log "DBeaver is already up-to-date (installed: $INSTALLED_VERSION_NORM, latest: $LATEST_VERSION_NORM)."
        exit 0
    fi
fi

log "Downloading DBeaver DMG..."
DOWNLOAD_SUCCESS=0

# Try primary URL first
log "Trying: $DMG_URL_PRIMARY"
if /usr/bin/curl -L --fail --retry 2 -A "Mozilla/5.0 (Macintosh)" "$DMG_URL_PRIMARY" -o "$DMG_FILE" 2>&1; then
    DOWNLOAD_SUCCESS=1
fi

# Fallback: Get latest version from GitHub API and download
if [[ "$DOWNLOAD_SUCCESS" -eq 0 ]]; then
    log "Primary download failed, trying GitHub..."
    if [[ -n "$LATEST_VERSION" ]]; then
        GITHUB_URL="https://github.com/dbeaver/dbeaver/releases/download/${LATEST_VERSION}/dbeaver-ce-${LATEST_VERSION}-macos-aarch64.dmg"
        log "Trying: $GITHUB_URL"
        if /usr/bin/curl -L --fail --retry 2 -A "Mozilla/5.0 (Macintosh)" "$GITHUB_URL" -o "$DMG_FILE" 2>&1; then
            DOWNLOAD_SUCCESS=1
        fi
    else
        log "Could not determine latest version from GitHub API"
    fi
fi

if [[ "$DOWNLOAD_SUCCESS" -eq 0 ]]; then
    log "ERROR: Failed to download DBeaver DMG from all sources"
    exit 1
fi

log "Mounting DMG..."
MOUNT_OUTPUT=$(hdiutil attach "$DMG_FILE" -nobrowse)
VOLUME_PATH=$(echo "$MOUNT_OUTPUT" | grep -o '/Volumes/[^"]*' | head -1)

if [[ -z "$VOLUME_PATH" ]]; then
    log "ERROR: Failed to detect mounted volume"
    exit 1
fi

log "Mounted at: $VOLUME_PATH"

# Find the .app bundle in the mounted volume
APP_SOURCE=$(find "$VOLUME_PATH" -maxdepth 1 -name "*.app" -type d | head -1)

if [[ -z "$APP_SOURCE" ]]; then
    log "ERROR: Could not find .app in mounted volume"
    hdiutil detach "$VOLUME_PATH" -quiet 2>/dev/null || true
    exit 1
fi

log "Copying DBeaver to /Applications..."
rm -rf "$APP_PATH"
cp -R "$APP_SOURCE" "$APP_PATH"

log "Unmounting DMG..."
hdiutil detach "$VOLUME_PATH" -quiet

log "Cleaning up..."
rm -f "$DMG_FILE"

log "DBeaver installation complete!"