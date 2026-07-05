#!/bin/bash

# ==============================================================================
# Updates Claude Desktop to the latest version on macOS.
# Detects current version and updates if newer version available.
# ==============================================================================

set -o pipefail

APP_NAME="Claude.app"
DEST_DIR="/Applications"
TMP_DIR="/tmp/claude_update_$$"
LOG_FILE="/var/log/claude_update.log"
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
    logger -t "claude_update" -p "$syslog_priority" "$message"
}

# shellcheck disable=SC2329  # invoked indirectly via 'trap cleanup EXIT' below
cleanup() {
    local exit_code=$?
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
    if [ "$exit_code" -eq 0 ]; then
        log "INFO" "Update completed successfully."
    else
        log "ERROR" "Update failed with exit code $exit_code."
    fi
    exit "$exit_code"
}

trap cleanup EXIT

log "INFO" "Starting Claude Desktop update check (PID: $$)..."

if [ "$EUID" -ne 0 ]; then
    log "ERROR" "This script must be run as root (via MDM)."
    exit 1
fi

# Check if Claude is installed
if [ ! -d "${DEST_DIR:?}/$APP_NAME" ]; then
    log "WARN" "Claude Desktop not found at $DEST_DIR/$APP_NAME. Skipping update."
    exit 0
fi

# Get current installed version
current_version=$(mdls -name kMDItemVersion "${DEST_DIR:?}/$APP_NAME" 2>/dev/null | cut -d'"' -f2)
if [ -z "$current_version" ]; then
    log "WARN" "Could not determine current Claude Desktop version. Skipping update."
    exit 0
fi

log "INFO" "Current Claude Desktop version: $current_version"

# Fetch latest version from release JSON
log "INFO" "Fetching latest Claude release information..."
latest_version=""
latest_url=""

for attempt in $(seq 1 "$MAX_RETRIES"); do
    latest_info=$(curl -sL --max-time "$CURL_TIMEOUT" "$JSON_URL" 2>/dev/null)
    if [ -n "$latest_info" ]; then
        latest_version=$(echo "$latest_info" | grep -o '"version":"[^"]*' | head -n 1 | cut -d'"' -f4)
        latest_url=$(echo "$latest_info" | grep -Eo 'https://[^"]+\.zip' | head -n 1)
        if [ -n "$latest_version" ] && [ -n "$latest_url" ]; then
            break
        fi
    fi
    
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
        log "WARN" "Failed to fetch release info (attempt $attempt/$MAX_RETRIES). Retrying in 5 seconds..."
        sleep 5
    fi
done

if [ -z "$latest_version" ] || [ -z "$latest_url" ]; then
    log "ERROR" "Could not determine latest Claude Desktop version after $MAX_RETRIES attempts."
    exit 1
fi

log "INFO" "Latest available version: $latest_version"

# Compare versions (simple string comparison for semantic versioning)
if [ "$current_version" = "$latest_version" ]; then
    log "INFO" "Claude Desktop is already up to date (version $current_version)."
    exit 0
fi

# Check if update is needed (current < latest)
# Simple version comparison: convert to comparable format
current_normalized=$(echo "$current_version" | tr '.' ' ' | awk '{printf "%05d%05d%05d%05d", $1, $2, $3, $4}')
latest_normalized=$(echo "$latest_version" | tr '.' ' ' | awk '{printf "%05d%05d%05d%05d", $1, $2, $3, $4}')

if [ "$current_normalized" -ge "$latest_normalized" ]; then
    log "INFO" "Claude Desktop is already up to date (version $current_version)."
    exit 0
fi

log "INFO" "Update available: $current_version → $latest_version"

# Create temporary directory
mkdir -p "$TMP_DIR" || {
    log "ERROR" "Failed to create temporary directory: $TMP_DIR"
    exit 1
}

cd "$TMP_DIR" || {
    log "ERROR" "Failed to change to temporary directory: $TMP_DIR"
    exit 1
}

# Download latest version
log "INFO" "Downloading Claude Desktop $latest_version..."
if ! curl -L --max-time "$CURL_TIMEOUT" -o "Claude.zip" "$latest_url" 2>/dev/null; then
    log "ERROR" "Failed to download Claude Desktop from $latest_url"
    exit 1
fi

if [ ! -f "Claude.zip" ] || [ ! -s "Claude.zip" ]; then
    log "ERROR" "Downloaded file is missing or empty."
    exit 1
fi

# Validate ZIP archive integrity
log "INFO" "Validating ZIP archive integrity..."
if ! unzip -t "Claude.zip" >/dev/null 2>&1; then
    log "ERROR" "ZIP archive is corrupted or invalid."
    exit 1
fi

# Check if Claude is running and quit it gracefully
log "INFO" "Checking if Claude Desktop is running..."
if pgrep -x "Claude" >/dev/null; then
    log "INFO" "Claude Desktop is running. Attempting graceful quit..."
    osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
    
    # Wait for app to quit (max 10 seconds)
    for _ in {1..10}; do
        if ! pgrep -x "Claude" >/dev/null; then
            log "INFO" "Claude Desktop quit successfully."
            break
        fi
        sleep 1
    done
    
    # Force quit if still running
    if pgrep -x "Claude" >/dev/null; then
        log "WARN" "Claude Desktop did not quit gracefully. Force quitting..."
        killall Claude 2>/dev/null || true
        sleep 2
    fi
fi

# Backup current version
log "INFO" "Backing up current installation..."
if ! mv "${DEST_DIR:?}/$APP_NAME" "${DEST_DIR:?}/$APP_NAME.backup"; then
    log "ERROR" "Failed to backup current installation."
    exit 1
fi

# Extract new version
log "INFO" "Extracting Claude Desktop $latest_version to $DEST_DIR..."
if ! unzip -q "Claude.zip" -d "$DEST_DIR"; then
    log "ERROR" "Extraction failed. Restoring backup..."
    rm -rf "${DEST_DIR:?}/$APP_NAME"
    mv "${DEST_DIR:?}/$APP_NAME.backup" "${DEST_DIR:?}/$APP_NAME"
    exit 1
fi

if [ ! -d "$DEST_DIR/$APP_NAME" ]; then
    log "ERROR" "Extraction failed. $APP_NAME not found in $DEST_DIR. Restoring backup..."
    rm -rf "${DEST_DIR:?}/$APP_NAME"
    mv "${DEST_DIR:?}/$APP_NAME.backup" "${DEST_DIR:?}/$APP_NAME"
    exit 1
fi

# Remove backup on successful extraction
rm -rf "${DEST_DIR:?}/$APP_NAME.backup"

# Set correct permissions and ownership
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

# Remove quarantine attribute
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

# Verify new version
new_version=$(mdls -name kMDItemVersion "$DEST_DIR/$APP_NAME" 2>/dev/null | cut -d'"' -f2)
if [ "$new_version" != "$latest_version" ]; then
    log "WARN" "Version verification mismatch. Expected: $latest_version, Got: $new_version"
fi

log "INFO" "Claude Desktop successfully updated to version $new_version."
exit 0
