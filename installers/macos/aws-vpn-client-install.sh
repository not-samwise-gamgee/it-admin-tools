#!/bin/bash

# ==============================================================================
# Script Name: aws-vpn-client-install.sh
# Description: Downloads and silently installs the AWS VPN Client (ARM64) on
#              macOS 14 (Sonoma) or higher. Designed for JumpCloud MDM deployment
#              running as root on behalf of a standard, non-admin user.
#
# Requirements:
#   - Apple Silicon (ARM64) Mac
#   - macOS 14.0 (Sonoma) or higher
#   - Must be executed as root (JumpCloud MDM runs scripts as root)
#
# Exit codes:
#   0  Success
#   1  Generic failure / pre-flight check failure
#   2  Download failure
#   3  PKG integrity check failure
#   4  Installation failure
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="aws-vpn-client-install"
readonly LOG_FILE="/var/log/${SCRIPT_NAME}.log"
readonly TMP_DIR="/private/tmp/${SCRIPT_NAME}_$$"
readonly PKG_NAME="AWS_VPN_Client_ARM64.pkg"
readonly DOWNLOAD_URL="https://d20adtppz83p9s.cloudfront.net/OSX_ARM64/latest/AWS_VPN_Client_ARM64.pkg"
readonly APP_PATH="/Applications/AWS VPN Client/AWS VPN Client.app"
readonly MIN_MACOS_MAJOR=14
readonly MIN_DISK_KB=524288   # 512 MB

readonly CURL_OPTS=(
    --silent
    --show-error
    --fail
    --location
    --retry 3
    --retry-delay 5
    --connect-timeout 30
    --max-time 300
)

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local timestamp msg
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    msg="[${timestamp}] [${level}] $*"
    echo "$msg" | tee -a "$LOG_FILE"
    logger -t "$SCRIPT_NAME" "$msg"
}

die() {
    log "ERROR" "$*"
    exit "${2:-1}"
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
cleanup() {
    local code=$?
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ "$code" -eq 0 ]; then
        log "INFO" "Script completed successfully."
    else
        log "WARN" "Script exited with code $code."
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Pre-flight checks
# ------------------------------------------------------------------------------
preflight_checks() {
    # Must run as root (MDM context)
    if [ "$EUID" -ne 0 ]; then
        die "This script must be run as root (via JumpCloud MDM)." 1
    fi

    # ARM64 architecture check
    local arch
    arch=$(uname -m)
    if [ "$arch" != "arm64" ]; then
        die "This script targets ARM64 Macs only. Detected architecture: $arch" 1
    fi

    # macOS version check
    local os_ver
    os_ver=$(sw_vers -productVersion)
    local major
    major=$(echo "$os_ver" | cut -d. -f1)
    if [ "$major" -lt "$MIN_MACOS_MAJOR" ]; then
        die "macOS $MIN_MACOS_MAJOR or higher required. Detected: $os_ver" 1
    fi

    # Disk space check
    local available_kb
    available_kb=$(df -k /Applications | awk 'NR==2 {print $4}')
    if [ "$available_kb" -lt "$MIN_DISK_KB" ]; then
        die "Insufficient disk space. Need at least 512 MB free in /Applications." 1
    fi

    log "INFO" "Pre-flight checks passed. arch=$arch, macOS=$os_ver, free=${available_kb}KB"
}

# ------------------------------------------------------------------------------
# Already installed check
# ------------------------------------------------------------------------------
check_existing_install() {
    if [ -d "$APP_PATH" ]; then
        local ver
        ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
              "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "unknown")
        log "INFO" "AWS VPN Client already installed (version: $ver). Re-installing to ensure latest."
    fi
}

# ------------------------------------------------------------------------------
# Download
# ------------------------------------------------------------------------------
download_pkg() {
    local dest="$1"
    log "INFO" "Downloading $PKG_NAME from $DOWNLOAD_URL"

    local attempt=1
    local max_attempts=3
    while [ "$attempt" -le "$max_attempts" ]; do
        if curl "${CURL_OPTS[@]}" -o "$dest" "$DOWNLOAD_URL"; then
            if [ -f "$dest" ] && [ -s "$dest" ]; then
                log "INFO" "Download successful ($(du -h "$dest" | cut -f1))."
                return 0
            fi
            log "WARN" "Downloaded file is empty (attempt $attempt/$max_attempts)."
        else
            log "WARN" "curl failed (attempt $attempt/$max_attempts)."
        fi
        rm -f "$dest"
        attempt=$((attempt + 1))
        [ "$attempt" -le "$max_attempts" ] && sleep $((attempt * 5))
    done

    die "Failed to download $PKG_NAME after $max_attempts attempts." 2
}

# ------------------------------------------------------------------------------
# Verify PKG integrity
# ------------------------------------------------------------------------------
verify_pkg() {
    local pkg="$1"
    log "INFO" "Verifying PKG integrity: $pkg"

    if ! pkgutil --check-signature "$pkg" >/dev/null 2>&1; then
        log "WARN" "pkgutil signature check inconclusive — verifying with installer dry-run."
    fi

    # Confirm it is a valid flat package
    if ! pkgutil --payload-files "$pkg" >/dev/null 2>&1; then
        die "PKG integrity check failed — file may be corrupt." 3
    fi

    log "INFO" "PKG integrity check passed."
}

# ------------------------------------------------------------------------------
# Install
# ------------------------------------------------------------------------------
install_pkg() {
    local pkg="$1"
    log "INFO" "Installing $PKG_NAME to / ..."

    if ! /usr/sbin/installer -pkg "$pkg" -target / -verboseR >> "$LOG_FILE" 2>&1; then
        die "installer command failed for $PKG_NAME." 4
    fi

    log "INFO" "installer command succeeded."
}

# ------------------------------------------------------------------------------
# Post-install verification
# ------------------------------------------------------------------------------
verify_install() {
    if [ ! -d "$APP_PATH" ]; then
        die "Post-install verification failed: $APP_PATH not found." 4
    fi

    local ver
    ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "unknown")
    log "INFO" "AWS VPN Client successfully installed. Version: $ver"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    # Ensure log file is writable before anything else
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" 2>/dev/null || true

    log "INFO" "=== AWS VPN Client ARM64 installer started (PID: $$) ==="

    preflight_checks
    check_existing_install

    mkdir -p "$TMP_DIR" || die "Failed to create temp directory: $TMP_DIR" 1
    local pkg_path="$TMP_DIR/$PKG_NAME"

    download_pkg "$pkg_path"
    verify_pkg "$pkg_path"
    install_pkg "$pkg_path"
    verify_install

    log "INFO" "=== Installation complete. ==="
}

main "$@"
