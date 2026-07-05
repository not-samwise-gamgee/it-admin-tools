#!/bin/bash

# ==============================================================================
# Script Name: Install-ClaudeDesktop.sh
# Description: Downloads and installs the latest Claude Desktop app on macOS.
#              Designed for silent deployment via JumpCloud MDM (runs as root).
#              Supports both admin and standard user environments.
# ==============================================================================

set -o pipefail

APP_NAME="Claude.app"
DEST_DIR="/Applications"
TMP_DIR="/tmp/claude_install_$$"
LOG_FILE="/var/log/claude_install.log"
JSON_URL="https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"
CURL_TIMEOUT=30
MAX_RETRIES=3

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    local syslog_priority
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    case "$level" in
        ERROR) syslog_priority="user.err" ;;
        WARN)  syslog_priority="user.warning" ;;
        INFO)  syslog_priority="user.info" ;;
        *)     syslog_priority="user.notice" ;;
    esac
    logger -t "claude_install" -p "$syslog_priority" "$message"
}

# shellcheck disable=SC2329  # invoked indirectly via 'trap cleanup EXIT' below
cleanup() {
    local exit_code=$?
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ "$exit_code" -eq 0 ]; then
        log "INFO" "Installation completed successfully."
    else
        log "ERROR" "Installation failed with exit code $exit_code."
    fi
    exit "$exit_code"
}

trap cleanup EXIT

log "INFO" "Starting Claude Desktop deployment (PID: $$)..."

if [ "$EUID" -ne 0 ]; then
    log "ERROR" "This script must be run as root (via MDM)."
    exit 1
fi

mkdir -p "$TMP_DIR" || {
    log "ERROR" "Failed to create temporary directory: $TMP_DIR"
    exit 1
}

cd "$TMP_DIR" || {
    log "ERROR" "Failed to change to temporary directory: $TMP_DIR"
    exit 1
}

log "INFO" "Fetching latest Claude release information from $JSON_URL..."
DOWNLOAD_URL=""
for attempt in $(seq 1 "$MAX_RETRIES"); do
    DOWNLOAD_URL=$(curl -sL --max-time "$CURL_TIMEOUT" "$JSON_URL" 2>/dev/null | grep -Eo 'https://[^"]+\.zip' | head -n 1)
    if [ -n "$DOWNLOAD_URL" ]; then
        break
    fi
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
        log "WARN" "Failed to fetch release info (attempt $attempt/$MAX_RETRIES). Retrying in 5 seconds..."
        sleep 5
    fi
done

if [ -z "$DOWNLOAD_URL" ]; then
    log "ERROR" "Could not determine the download URL after $MAX_RETRIES attempts. JSON format may have changed."
    exit 1
fi

log "INFO" "Latest download URL identified: $DOWNLOAD_URL"

log "INFO" "Downloading Claude.zip..."
DOWNLOAD_SUCCESS=false
DOWNLOAD_TIMEOUT=60  # Increased timeout for large files (up to 60 seconds)

for attempt in $(seq 1 "$MAX_RETRIES"); do
    log "INFO" "Download attempt $attempt/$MAX_RETRIES..."
    
    # Use curl with verbose error output on failure
    if curl -L --max-time "$DOWNLOAD_TIMEOUT" --connect-timeout 10 -o "Claude.zip" "$DOWNLOAD_URL" 2>/tmp/curl_error.log; then
        # Verify file exists and has content
        if [ -f "Claude.zip" ] && [ -s "Claude.zip" ]; then
            log "INFO" "Download completed successfully ($(du -h Claude.zip | cut -f1))."
            DOWNLOAD_SUCCESS=true
            break
        else
            log "WARN" "Downloaded file is empty or missing (attempt $attempt/$MAX_RETRIES)."
            rm -f "Claude.zip"
        fi
    else
        # Log curl error for diagnostics
        CURL_ERROR=$(cat /tmp/curl_error.log 2>/dev/null || echo "Unknown error")
        log "WARN" "Download failed (attempt $attempt/$MAX_RETRIES): $CURL_ERROR"
    fi
    
    # Exponential backoff: 5s, 10s, 15s
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
        BACKOFF=$((attempt * 5))
        log "INFO" "Retrying in $BACKOFF seconds..."
        sleep "$BACKOFF"
    fi
done

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    log "ERROR" "Failed to download the archive from $DOWNLOAD_URL after $MAX_RETRIES attempts."
    log "ERROR" "Possible causes: Network timeout, CDN unavailable, or invalid URL."
    log "ERROR" "Last error: $(cat /tmp/curl_error.log 2>/dev/null || echo 'Unknown')"
    rm -f /tmp/curl_error.log
    exit 1
fi

rm -f /tmp/curl_error.log

log "INFO" "Validating ZIP archive integrity..."
if ! unzip -t "Claude.zip" >/dev/null 2>&1; then
    log "ERROR" "ZIP archive is corrupted or invalid."
    exit 1
fi

if [ -d "${DEST_DIR:?}/$APP_NAME" ]; then
    log "INFO" "Removing existing installation of Claude..."
    if ! rm -rf "${DEST_DIR:?}/$APP_NAME"; then
        log "ERROR" "Failed to remove existing installation."
        exit 1
    fi
fi

log "INFO" "Extracting Claude to $DEST_DIR..."
if ! unzip -q "Claude.zip" -d "$DEST_DIR"; then
    log "ERROR" "Extraction failed."
    exit 1
fi

if [ ! -d "$DEST_DIR/$APP_NAME" ]; then
    log "ERROR" "Extraction failed. $APP_NAME not found in $DEST_DIR."
    exit 1
fi

log "INFO" "Setting permissions and ownership..."
if chown -R root:wheel "$DEST_DIR/$APP_NAME" 2>/dev/null; then
    log "INFO" "Ownership set to root:wheel."
else
    log "WARN" "Some files could not be changed to root:wheel (may already be owned correctly)."
fi

if chmod -R u+rwX,g+rX,o+rX "$DEST_DIR/$APP_NAME" 2>/dev/null; then
    log "INFO" "Permissions set successfully."
else
    log "WARN" "Some files could not have permissions modified (non-critical)."
fi

log "INFO" "Removing quarantine attribute..."
if xattr -rc "$DEST_DIR/$APP_NAME" 2>/dev/null; then
    if xattr -p com.apple.quarantine "$DEST_DIR/$APP_NAME" >/dev/null 2>&1; then
        log "WARN" "Quarantine attribute still present after removal attempt."
    else
        log "INFO" "Quarantine attribute successfully removed."
    fi
else
    log "WARN" "Failed to remove quarantine attribute (non-critical)."
fi

log "INFO" "Installation completed successfully. Claude Desktop is ready for use."
exit 0