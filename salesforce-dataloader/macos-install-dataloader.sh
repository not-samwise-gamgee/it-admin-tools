#!/bin/bash
# Salesforce DataLoader macOS Install Script
# Installs latest stable DataLoader release for the logged-in user, removes old versions, bypasses Gatekeeper, and pre-configures for [your-org].my.salesforce.com
# FIX: Launcher updated to use '/usr/libexec/java_home' for reliable Java detection.

set -e

# Variables
DATALOADER_URL="https://a.sfdcstatic.com/developer-website/media/dataloader/dataloader_v64.1.0.zip"
DATALOADER_APP_NAME="Data Loader.app"
DATALOADER_VERSION="64.1.0"

# Get the actual logged-in user (not root when running via sudo)
CONSOLE_USER=$(stat -f%Su /dev/console)
if [[ -z "$CONSOLE_USER" ]]; then
    echo "Error: Could not determine console user"
    exit 1
fi
echo "Console user detected: $CONSOLE_USER"

USER_HOME=$(eval echo "~${CONSOLE_USER}")
USER_APP_DIR="$USER_HOME/Applications"
USER_SUPPORT_DIR="$USER_HOME/Library/Application Support"
USER_PREFS_DIR="$USER_HOME/Library/Preferences"
USER_DATALOADER_CONFIG="$USER_HOME/.dataloader"
APP_BUNDLE="${USER_APP_DIR:?}/$DATALOADER_APP_NAME" # Define this globally for helpers

# Helper: get installed DataLoader version (returns version or empty)
get_installed_version() {
    local highest_version=""
    
    local locations=(
        "$USER_APP_DIR/$DATALOADER_APP_NAME"
        "/Applications/$DATALOADER_APP_NAME"
        "$USER_APP_DIR/DataLoader.app"
        "/Applications/DataLoader.app"
    )
    
    for app_path in "${locations[@]}"; do
        if [[ -d "$app_path" ]]; then
            local version
            version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist" 2>/dev/null || echo "")
            if [[ -n "$version" ]]; then
                if [[ -z "$highest_version" ]] || [[ "$version" > "$highest_version" ]]; then
                    highest_version="$version"
                fi
            fi
        fi
    done
    
    echo "$highest_version"
}

# Helper: check if any DataLoader installations exist (kept for logging)
check_all_dataloader_installations() {
    local locations=(
        "$USER_APP_DIR/$DATALOADER_APP_NAME"
        "/Applications/$DATALOADER_APP_NAME"
        "$USER_APP_DIR/DataLoader.app"
        "/Applications/DataLoader.app"
    )
    
    for app_path in "${locations[@]}"; do
        if [[ -d "$app_path" ]]; then
            echo "Found DataLoader at: $app_path"
        fi
    done
}

# Remove old DataLoader and config
remove_old_dataloader() {
    echo "Removing old DataLoader installations and configuration..."
    
    pkill -f "dataloader" 2>/dev/null || true
    pkill -f "DataLoader" 2>/dev/null || true
    sleep 1
    
    local app_locations=(
        "${USER_APP_DIR:?}/$DATALOADER_APP_NAME"
        "/Applications/$DATALOADER_APP_NAME"
        "${USER_APP_DIR:?}/DataLoader.app"
        "/Applications/DataLoader.app"
        "${USER_HOME:?}/Desktop/dataloader_v63.0.0 2"
        "${USER_HOME:?}/Desktop/Dataloader"
    )
    
    for app_path in "${app_locations[@]}"; do
        if [[ -e "$app_path" ]]; then
            echo "Removing: $app_path"
            rm -rf "$app_path"
        fi
    done
    
    echo "Scanning for additional DataLoader installations..."
    find "${USER_HOME:?}/Desktop" "${USER_HOME:?}/Downloads" -maxdepth 2 -name "*ataloader*" -type d 2>/dev/null | while read -r extra_path; do
        if [[ "$extra_path" != *"Library"* ]]; then
            echo "Removing additional installation: $extra_path"
            rm -rf "$extra_path"
        fi
    done
    
    rm -rf "${USER_SUPPORT_DIR:?}/dataloader"*
    rm -rf "${USER_SUPPORT_DIR:?}/DataLoader"*
    rm -rf "${USER_PREFS_DIR:?}/com.salesforce.dataloader"*
    rm -rf "${USER_PREFS_DIR:?}/com.salesforce.DataLoader"*
    rm -rf "${USER_DATALOADER_CONFIG:?}"
    
    # Crucial: Clear LaunchServices database entries (run as user)
    echo "Clearing LaunchServices database entries..."
    sudo -u "${CONSOLE_USER:?}" /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user 2>/dev/null || true
}

# Download and install DataLoader for user
install_dataloader() {
    echo "Downloading DataLoader $DATALOADER_VERSION..."
    TMPDIR=$(mktemp -d)
    curl -L "$DATALOADER_URL" -o "$TMPDIR/dataloader.zip"
    unzip -q "$TMPDIR/dataloader.zip" -d "$TMPDIR"
    
    echo "Contents of extracted zip:"
    ls -la "$TMPDIR/"
    
    JAR_FILE=$(find "$TMPDIR" -name "dataloader-*.jar" | head -1)
    if [[ -z "$JAR_FILE" ]]; then
        echo "Error: No dataloader JAR found in downloaded zip"
        ls -la "$TMPDIR/"
        exit 1
    fi
    
    # Create .app bundle structure
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    
    # Copy JAR file
    cp "$JAR_FILE" "$APP_BUNDLE/Contents/Resources/"
    JAR_NAME=$(basename "$JAR_FILE")
    
    # --- CRITICAL FIX: Handle Icon File (dataloader.icns) ---
    ICON_FILE=$(find "$TMPDIR" -name "dataloader.icns" | head -1)
    if [[ -n "$ICON_FILE" ]]; then
        echo "Copying icon file ($ICON_FILE) to Resources..."
        cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/"
    else
        echo "Warning: dataloader.icns file not found in extracted zip."
        echo "Creating fallback icon from system resources..."
        # Create a basic app icon using system iconutil if available
        # This ensures the app has a proper icon and bundle structure
        if command -v iconutil >/dev/null 2>&1; then
            # Create a simple iconset directory structure for fallback
            mkdir -p "$APP_BUNDLE/Contents/Resources/AppIcon.iconset"
            # Use system's generic app icon as base - this is better than no icon
            if [[ -f "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns" ]]; then
                cp "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns" "$APP_BUNDLE/Contents/Resources/dataloader.icns"
                echo "Applied fallback icon for better app recognition."
            fi
        fi
    fi
    # --- END CRITICAL FIX ---
    
    # Create Info.plist 
    cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DataLoader</string>
    <key>CFBundleIdentifier</key>
    <string>com.salesforce.dataloader</string>
    <key>CFBundleName</key>
    <string>Data Loader</string>
    <key>CFBundleDisplayName</key>
    <string>Data Loader</string>
    <key>CFBundleShortVersionString</key>
    <string>$DATALOADER_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$DATALOADER_VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>dataloader.icns</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.15</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.business</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
    
    # Create executable launcher script (Enhanced Java detection)
    cat > "$APP_BUNDLE/Contents/MacOS/DataLoader" <<EOF
#!/bin/bash

# Enhanced Java detection with multiple fallbacks
JAVA_HOME_PATH=""

# Try different Java version requirements in order of preference
for version in "1.8" "11" "17" "21" ""; do
    if [[ -n "\$version" ]]; then
        JAVA_HOME_PATH=\$(/usr/libexec/java_home -v "\$version" 2>/dev/null)
    else
        # Last resort: try without version requirement
        JAVA_HOME_PATH=\$(/usr/libexec/java_home 2>/dev/null)
    fi
    
    if [[ -n "\$JAVA_HOME_PATH" ]] && [[ -x "\$JAVA_HOME_PATH/bin/java" ]]; then
        echo "Found Java at: \$JAVA_HOME_PATH (version requirement: \${version:-any})" >&2
        break
    fi
done

if [[ -z "\$JAVA_HOME_PATH" ]] || [[ ! -x "\$JAVA_HOME_PATH/bin/java" ]]; then
    osascript -e 'display dialog "Java Runtime Environment (JRE) is required to run DataLoader. Please install Java 8 or newer from https://adoptium.net" buttons {"OK"} default button "OK"' >/dev/null 2>&1 &
    exit 1
fi
JAVA_CMD="\$JAVA_HOME_PATH/bin/java"

# Change to Resources directory where the JAR is located
SCRIPT_DIR="\$(dirname "\$0")"
RESOURCES_DIR="\$SCRIPT_DIR/../Resources"
cd "\$RESOURCES_DIR" || exit 1

# Java compatibility flags for newer Java versions
JAVA_OPTS="-Xmx1024m"
# Essential for avoiding encoding crashes in Swing apps
JAVA_OPTS="\$JAVA_OPTS -Dfile.encoding=UTF-8" 
JAVA_OPTS="\$JAVA_OPTS -Djava.awt.headless=false"
JAVA_OPTS="\$JAVA_OPTS -Dapple.awt.UIElement=false"

# Add compatibility flags for Java 9+ to support older Swing applications
JAVA_VERSION=\$( "\$JAVA_CMD" -version 2>&1 | head -1 | cut -d'"' -f2 | cut -d'.' -f1 )
if [[ "\$JAVA_VERSION" -ge 9 ]]; then
    JAVA_OPTS="\$JAVA_OPTS --add-opens java.base/java.lang=ALL-UNNAMED"
    JAVA_OPTS="\$JAVA_OPTS --add-opens java.base/java.util=ALL-UNNAMED"
    JAVA_OPTS="\$JAVA_OPTS --add-opens java.desktop/javax.swing=ALL-UNNAMED"
    JAVA_OPTS="\$JAVA_OPTS --add-opens java.desktop/java.awt=ALL-UNNAMED"
    JAVA_OPTS="\$JAVA_OPTS --add-opens java.desktop/java.awt.event=ALL-UNNAMED"
fi

# Launch DataLoader with compatibility options
exec "\$JAVA_CMD" \$JAVA_OPTS -jar "$JAR_NAME" "\$@"
EOF
    
    chmod +x "$APP_BUNDLE/Contents/MacOS/DataLoader"
    
    # CRITICAL FIX 1: Enforce Ownership and Permissions
    echo "Setting ownership and permissions for the app bundle..."
    chown -R "${CONSOLE_USER:?}" "$APP_BUNDLE"
    chmod -R u+w,go-w "$APP_BUNDLE"
    
    # Ensure executable has proper permissions
    chmod 755 "$APP_BUNDLE/Contents/MacOS/DataLoader"
    
    # Create PkgInfo file for proper app bundle recognition
    echo "APPLSFDL" > "$APP_BUNDLE/Contents/PkgInfo"
    chown "${CONSOLE_USER:?}" "$APP_BUNDLE/Contents/PkgInfo"
    
    # Bypass Gatekeeper
    xattr -dr com.apple.quarantine "$APP_BUNDLE"
    
    # CRITICAL FIX 2: Re-register with LaunchServices (Run as User)
    echo "Registering DataLoader with LaunchServices and forcing cache update..."
    sudo -u "${CONSOLE_USER:?}" /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP_BUNDLE"
    
    echo "Installed DataLoader to $APP_BUNDLE"
    rm -rf "$TMPDIR"
}

# Pre-configure Salesforce connection (creates config file for OAuth login dialog)
preconfigure_salesforce() {
    mkdir -p "${USER_DATALOADER_CONFIG:?}"
    cat > "${USER_DATALOADER_CONFIG:?}/dataloader.properties" <<EOF
sfdc.endpoint=https://[your-org].my.salesforce.com
sfdc.timeout=60000
sfdc.timeoutSecs=60
sfdc.loadBatchSize=200
EOF
    chown -R "${CONSOLE_USER:?}" "${USER_DATALOADER_CONFIG:?}"
}


# Main logic
echo "Checking for existing DataLoader installations..."
check_all_dataloader_installations

INSTALLED_VERSION=$(get_installed_version)
echo "Highest installed version found: ${INSTALLED_VERSION:-"None"}"
echo "Target version: $DATALOADER_VERSION"

# --- SIMPLIFIED AND ROBUST MAIN LOGIC ---

# Scenario 1: No version found (Initial installation)
if [[ -z "$INSTALLED_VERSION" ]]; then
    echo "No previous version found. Performing clean installation..."
    install_dataloader
    preconfigure_salesforce
    echo "DataLoader $DATALOADER_VERSION installed successfully."
    
# Scenario 2: Correct version found (Repair/Integrity Check)
elif [[ "$INSTALLED_VERSION" == "$DATALOADER_VERSION" ]]; then
    echo "DataLoader $INSTALLED_VERSION found. Forcing clean re-install to ensure integrity and apply icon fix..."
    remove_old_dataloader # <-- Crucial step to clear caches/files
    install_dataloader
    preconfigure_salesforce
    echo "DataLoader $DATALOADER_VERSION repaired successfully."
    
# Scenario 3: Incorrect/Older version found (Upgrade)
else
    echo "Version mismatch detected ($INSTALLED_VERSION found, $DATALOADER_VERSION required). Performing upgrade..."
    remove_old_dataloader # <-- Crucial step for upgrade/cleanup
    install_dataloader
    preconfigure_salesforce
    echo "DataLoader $DATALOADER_VERSION installed successfully (forced upgrade)."
fi

exit 0
