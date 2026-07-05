#!/bin/bash
# ============================================================
# Silent Node.js Installer for macOS (JumpCloud MDM)
# Dynamically resolves latest Node.js 22 LTS — no hardcoded version.
# ============================================================

set -euo pipefail

# -- Configuration -------------------------------------------
NODE_MAJOR="22"                 # LTS major version to track
LOG_FILE="/var/log/nodejs_mdm_install.log"
# ------------------------------------------------------------

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [nodejs-install] $*" | tee -a "$LOG_FILE"
}

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/nodejs_mdm_install.log"

log "=========================================="
log "Starting Node.js v${NODE_MAJOR} LTS install"
log "=========================================="

# -- Already installed? --------------------------------------
if command -v npx &>/dev/null; then
    CURRENT=$(node --version 2>/dev/null || echo "unknown")
    log "Node.js already present (${CURRENT}). Nothing to do."
    exit 0
fi

# -- Resolve latest patch version dynamically ----------------
log "Resolving latest Node.js v${NODE_MAJOR} LTS version..."
BASE_URL="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"

NODE_VERSION=$(curl -fsSL "${BASE_URL}/" \
    | grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+\.pkg" \
    | head -1 \
    | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")

if [[ -z "$NODE_VERSION" ]]; then
    log "ERROR: Could not determine latest Node.js v${NODE_MAJOR} version from ${BASE_URL}"
    exit 1
fi

log "Resolved version: v${NODE_VERSION}"

# -- Universal macOS installer (works on both arm64 and x64) -
PKG_NAME="node-v${NODE_VERSION}.pkg"
NODE_URL="${BASE_URL}/${PKG_NAME}"
TMP_PKG="/tmp/${PKG_NAME}"

log "Architecture : $(uname -m) (using universal pkg)"
log "Package URL  : ${NODE_URL}"

# -- Download ------------------------------------------------
log "Downloading..."
if ! curl -fsSL \
        --retry 3 \
        --retry-delay 5 \
        --connect-timeout 30 \
        -o "$TMP_PKG" \
        "$NODE_URL"; then
    log "ERROR: Download failed for ${NODE_URL}"
    exit 1
fi

# -- Checksum verification -----------------------------------
log "Verifying checksum..."
EXPECTED=$(curl -fsSL "${BASE_URL}/SHASUMS256.txt" | grep " ${PKG_NAME}\$" | awk '{print $1}')
ACTUAL=$(shasum -a 256 "$TMP_PKG" | awk '{print $1}')

if [[ -z "$EXPECTED" || "$EXPECTED" != "$ACTUAL" ]]; then
    log "ERROR: Checksum mismatch. Expected: '${EXPECTED}' Got: '${ACTUAL}'"
    rm -f "$TMP_PKG"
    exit 1
fi
log "Checksum OK: ${ACTUAL}"

# -- Install -------------------------------------------------
log "Running installer..."
if ! installer -pkg "$TMP_PKG" -target / >> "$LOG_FILE" 2>&1; then
    log "ERROR: installer command failed"
    rm -f "$TMP_PKG"
    exit 1
fi

rm -f "$TMP_PKG"

# -- Verify --------------------------------------------------
if [[ -x "/usr/local/bin/npx" ]]; then
    NODE_V=$(/usr/local/bin/node --version 2>/dev/null)
    NPM_V=$(/usr/local/bin/npm --version 2>/dev/null)
    NPX_V=$(/usr/local/bin/npx --version 2>/dev/null)
    log "SUCCESS: node ${NODE_V}, npm ${NPM_V}, npx ${NPX_V}"
else
    log "ERROR: Binaries not found after install"
    exit 1   # trap writes FAILED marker
fi

# -- Success marker ------------------------------------------
{
    echo "status=SUCCESS"
    echo "exit_code=0"
    echo "node_version=${NODE_VERSION}"
    echo "node=${NODE_V}"
    echo "npm=${NPM_V}"
    echo "npx=${NPX_V}"
    echo "npx_path=/usr/local/bin/npx"
    echo "timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "host=$(scutil --get LocalHostName 2>/dev/null || hostname)"
} > "$MARKER_FILE"
log "Wrote SUCCESS marker to ${MARKER_FILE}"

trap - EXIT   # clear trap so clean exit doesn't overwrite success marker

log "=========================================="
log "Installation complete"
log "=========================================="
exit 0