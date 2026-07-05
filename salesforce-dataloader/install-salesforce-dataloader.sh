#!/bin/bash
# Salesforce DataLoader macOS Silent Install Script
# Uses official install.command with silent mode parameters for MDM deployment.
# Requires: Java 17+ pre-installed

set -e

# --- Variables ---
DATALOADER_URL="https://a.sfdcstatic.com/developer-website/media/dataloader/dataloader_v64.1.0.zip"
DATALOADER_VERSION="64.1.0"
INSTALL_DIR="/Applications/dataloader"
# Note: Official installer creates lowercase "dataloader.app"
DATALOADER_APP_NAME="dataloader.app"

# Verify Java 17+ is available before proceeding
if ! /usr/libexec/java_home -v 17 &>/dev/null; then
    echo "ERROR: Java 17+ not found. Run jdk_installer.sh first."
    exit 1
fi
echo "Java 17+ detected: $(/usr/libexec/java_home -v 17)"

# Get the actual logged-in console user (not root when running via MDM)
CONSOLE_USER=$(stat -f %Su /dev/console 2>/dev/null || echo "")
if [[ -z "$CONSOLE_USER" ]] || [[ "$CONSOLE_USER" == "root" ]]; then
    # shellcheck disable=SC2012  # fixed single path /dev/console; ls -l owner fallback is intentional
    CONSOLE_USER=$(ls -l /dev/console | awk '{print $3}')
fi

# --- Helper Functions ---

remove_old_dataloader() {
    echo "Cleaning up old DataLoader installations..."
    pkill -f "dataloader" 2>/dev/null || true
    
    # Remove previous system installations
    rm -rf "$INSTALL_DIR"
    rm -rf "/Applications/$DATALOADER_APP_NAME"
    rm -rf "/Applications/dataloader.app"
    rm -rf "/Applications/Data Loader.app"
    
    # Remove User App (legacy) - use explicit paths, not $HOME which is /var/root under MDM
    rm -rf "/Users/*/Applications/dataloader.app"
    rm -rf "/Users/*/Applications/Data Loader.app"
    
    # Cleanup downloads/desktop clutter
    find /Users/*/Desktop /Users/*/Downloads -maxdepth 2 -type d -name "*ataloader*" -exec rm -rf {} + 2>/dev/null || true
}

install_dataloader() {
    echo "Downloading DataLoader $DATALOADER_VERSION..."
    TMPDIR=$(mktemp -d)
    
    # Download and extract
    curl -L "$DATALOADER_URL" -o "$TMPDIR/dataloader.zip"
    unzip -q "$TMPDIR/dataloader.zip" -d "$TMPDIR"
    
    # Locate install.command
    INSTALL_CMD=$(find "$TMPDIR" -name "install.command" -type f | head -1)
    
    if [[ -z "$INSTALL_CMD" ]]; then
        echo "Error: install.command not found in download."
        rm -rf "$TMPDIR"
        exit 1
    fi
    
    echo "Found installer at: $INSTALL_CMD"
    EXTRACT_DIR=$(dirname "$INSTALL_CMD")
    
    # Make installer executable
    chmod +x "$INSTALL_CMD"
    
    # Run official installer with silent mode parameters
    # salesforce.installation.dir - where to install
    # salesforce.installation.shortcut.desktop=false - no desktop shortcut (fails in headless MDM)
    # salesforce.installation.shortcut.macos.appsfolder=false - no /Applications symlink (we handle this)
    echo "Running silent installation to $INSTALL_DIR..."
    cd "$EXTRACT_DIR"
    
    # Disable desktop shortcut creation entirely - it can fail in headless MDM context
    # Pipe Yes to handle any remaining interactive prompts
    echo "Yes" | bash "$INSTALL_CMD" \
        "salesforce.installation.dir=$INSTALL_DIR" \
        "salesforce.installation.shortcut.desktop=false" \
        "salesforce.installation.shortcut.macos.appsfolder=false" || true
    
    # Verify installation
    if [[ ! -d "$INSTALL_DIR" ]]; then
        echo "Silent install may have failed. Attempting manual setup..."
        mkdir -p "$INSTALL_DIR"
        cp -R "$EXTRACT_DIR/"* "$INSTALL_DIR/"
    fi
    
    # Set permissions - install dir must be writable for configs
    chown -R root:admin "$INSTALL_DIR"
    chmod -R 755 "$INSTALL_DIR"
    
    # Make configs writable by all users
    if [[ -d "$INSTALL_DIR/configs" ]]; then
        chmod -R 777 "$INSTALL_DIR/configs"
    else
        mkdir -p "$INSTALL_DIR/configs"
        chmod -R 777 "$INSTALL_DIR/configs"
    fi
    
    # Clear quarantine from all files
    xattr -dr com.apple.quarantine "$INSTALL_DIR" 2>/dev/null || true
    
    # Create symlink in /Applications for easier access
    APP_PATH="$INSTALL_DIR/$DATALOADER_APP_NAME"
    if [[ -d "$APP_PATH" ]]; then
        xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
        # Create symlink so users can find it in /Applications
        ln -sf "$APP_PATH" "/Applications/$DATALOADER_APP_NAME" 2>/dev/null || true
        # Also create friendly-named alias
        ln -sf "$APP_PATH" "/Applications/Data Loader.app" 2>/dev/null || true
        /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP_PATH"
        echo "App registered at: $APP_PATH"
    else
        echo "Warning: App bundle not found at $APP_PATH"
        ls -la "$INSTALL_DIR/" || true
    fi
    
    echo "Installation complete at $INSTALL_DIR"
    rm -rf "$TMPDIR"
}

# --- Main Logic ---

echo "Starting Global Data Loader Install..."
remove_old_dataloader
install_dataloader
echo "Success."
exit 0