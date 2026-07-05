#!/bin/bash
# JDK Prerequisite Installer for macOS 
# Downloads and installs Adoptium OpenJDK 17 (LTS) for the correct architecture.

set -e

echo "Starting JDK Prerequisite Installation Script..."

# --- Variables ---
JDK_BASE_PATH="/Library/Java/JavaVirtualMachines"
MIN_JAVA_VERSION="17"

# --- Architecture Detection ---
ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" ]]; then
    echo "Detected Apple Silicon (arm64)."
    # Download URL for macOS aarch64 (ARM64)
    JDK_DOWNLOAD_URL="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12%2B7/OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.12_7.tar.gz"
    JDK_ARCHIVE_NAME="OpenJDK17U-jdk_aarch64_mac_hotspot.tar.gz"
else
    echo "Detected Intel Mac (x86_64)."
    # Download URL for macOS x64 (Intel)
    JDK_DOWNLOAD_URL="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.12%2B7/OpenJDK17U-jdk_x64_mac_hotspot_17.0.12_7.tar.gz"
    JDK_ARCHIVE_NAME="OpenJDK17U-jdk_x64_mac_hotspot.tar.gz"
fi

# --- Check for Existing Java ---
check_for_existing_jdk() {
    # Check specifically for version 17 or newer
    if /usr/libexec/java_home -v "$MIN_JAVA_VERSION" >/dev/null 2>&1; then
        local java_path
        java_path=$(/usr/libexec/java_home -v "$MIN_JAVA_VERSION")
        echo "Compatible JDK ($MIN_JAVA_VERSION+) found at: $java_path"
        return 0
    else
        echo "Compatible JDK not found. Proceeding with installation."
        return 1
    fi
}

# --- Install JDK Function ---
install_jdk() {
    echo "Installing OpenJDK 17 ($ARCH)..."
    
    local TMPDIR_JDK
    TMPDIR_JDK=$(mktemp -d)
    
    # 1. Download
    echo "Downloading from: $JDK_DOWNLOAD_URL"
    if ! curl -fsSL --retry 3 --connect-timeout 30 "$JDK_DOWNLOAD_URL" -o "$TMPDIR_JDK/$JDK_ARCHIVE_NAME"; then
        echo "ERROR: Failed to download JDK archive."
        rm -rf "$TMPDIR_JDK"
        return 1
    fi
    
    # 2. Extract
    echo "Extracting JDK..."
    mkdir -p "${JDK_BASE_PATH:?}"
    if ! tar -xzf "$TMPDIR_JDK/$JDK_ARCHIVE_NAME" -C "$TMPDIR_JDK"; then
        echo "ERROR: Failed to extract JDK archive."
        rm -rf "$TMPDIR_JDK"
        return 1
    fi
    
    # 3. Find extracted root
    local EXTRACTED_ROOT_DIR
    EXTRACTED_ROOT_DIR=$(find "$TMPDIR_JDK" -maxdepth 1 -mindepth 1 -type d | head -1)
    
    if [[ -z "$EXTRACTED_ROOT_DIR" ]]; then
        echo "ERROR: Extracted directory not found."
        rm -rf "$TMPDIR_JDK"
        return 1
    fi
    
    # 4. Rename to bundle format
    local NEW_BUNDLE_NAME="temurin-17.jdk"
    local FINAL_BUNDLE_PATH="$TMPDIR_JDK/$NEW_BUNDLE_NAME"
    
    # Remove existing if present to avoid conflict
    if [[ -d "${JDK_BASE_PATH:?}/$NEW_BUNDLE_NAME" ]]; then
        echo "Removing existing JDK version to ensure clean install..."
        rm -rf "${JDK_BASE_PATH:?}/$NEW_BUNDLE_NAME"
    fi

    echo "Renaming extracted folder to $NEW_BUNDLE_NAME..."
    mv "$EXTRACTED_ROOT_DIR" "$FINAL_BUNDLE_PATH"
    
    # 5. Move to system path
    echo "Moving JDK bundle to $JDK_BASE_PATH/"
    if ! mv "$FINAL_BUNDLE_PATH" "${JDK_BASE_PATH:?}/"; then
        echo "ERROR: Failed to move JDK to $JDK_BASE_PATH."
        rm -rf "$TMPDIR_JDK"
        return 1
    fi

    # 6. Set permissions
    chown -R root:wheel "${JDK_BASE_PATH:?}/$NEW_BUNDLE_NAME"
    chmod -R 755 "${JDK_BASE_PATH:?}/$NEW_BUNDLE_NAME"
    
    echo "OpenJDK 17 installed successfully."
    rm -rf "$TMPDIR_JDK"
    return 0
}

# --- Main Logic ---
if check_for_existing_jdk; then
    echo "JDK prerequisite check passed."
    exit 0
else
    if install_jdk; then
        echo "JDK installation complete."
        exit 0
    else
        echo "JDK installation failed."
        exit 1
    fi
fi