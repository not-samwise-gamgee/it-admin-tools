#!/bin/bash

# Removes legacy slack.dmg install from ~/Applications
# Installs slack.pkg in /Applications and assigns permissions for standard users to update Slack & Slack Helper
# Creates plist files to enforce auto updates [your-org].slack.com org login
# Exit on non-zero status and variable errors, report back individual pipefails


# Strict error handling
set -euo pipefail
IFS=$'\n\t'

# Constants
readonly ARCH="universal"  # Use universal for Slack installer compatibility
readonly BASE_URL="https://slack.com/api/desktop.latestRelease?redirect=1&variant=pkg&arch=${ARCH}"
TEMP_FOLDER=$(mktemp -d)
readonly TEMP_FOLDER
readonly CURL_OPTS=(
    --silent
    --location
    --fail
    --retry 3
    --retry-delay 2
)
readonly REQUIRED_SPACE=$((1024 * 1024 * 1024))  # 1GB

# Cleanup function
cleanup() {
    rm -rf "${TEMP_FOLDER:?}"
}

trap cleanup EXIT INT TERM

# Logging function
logger() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Check available disk space
check_disk_space() {
    local target_dir="$1"
    local available_space
    
    logger "DEBUG" "Checking available disk space in '$target_dir'"
    available_space=$(df -k "$target_dir" | awk 'NR==2 {print $4 * 1024}')
    
    if [ "$available_space" -lt "$REQUIRED_SPACE" ]; then
        logger "ERROR" "Insufficient disk space. Required: $(numfmt --to=iec-i --suffix=B "${REQUIRED_SPACE}"), Available: $(numfmt --to=iec-i --suffix=B "${available_space}")"
        return 1
    fi
    
    return 0
}

# Get current user
get_current_user() {
    local current_user=""
    
    # First try console user (works when user is logged in)
    current_user=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')
    
    # If no console user, try who command
    if [ -z "$current_user" ] || [ "$current_user" = "loginwindow" ]; then
        current_user=$(who | awk '/console/ { print $1 }' | head -n1)
    fi
    
    # If still empty or setup user, check for real users
    if [ -z "$current_user" ] || [ "$current_user" = "_mbsetupuser" ] || [ "$current_user" = "root" ]; then
        logger "WARN" "Running in setup/enrollment context, installing to system Applications"
        # In setup context, install to system Applications for all users
        current_user="system"
    fi
    
    if [ -z "$current_user" ]; then
        logger "ERROR" "Could not determine current user"
        return 1
    fi
    
    echo "$current_user"
}

# Get user home directory
get_user_home() {
    local username="$1"
    local home_dir
    
    # Handle system installation case
    if [ "$username" = "system" ]; then
        echo "/Applications"
        return 0
    fi
    
    home_dir=$(dscl . -read "/Users/$username" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    if [ -z "$home_dir" ]; then
        logger "ERROR" "Could not determine home directory for $username"
        return 1
    fi
    
    echo "$home_dir"
}

# Verify package integrity
verify_package() {
    local pkg_file="$1"
    local pkg_size
    
    logger "DEBUG" "Verifying package integrity"
    
    # Check file exists and is not empty
    if [ ! -f "$pkg_file" ] || [ ! -s "$pkg_file" ]; then
        logger "ERROR" "Package file is missing or empty"
        return 1
    fi
    
    # Check file size
    pkg_size=$(stat -f "%z" "$pkg_file")
    if [ "$pkg_size" -lt 1000000 ]; then  # At least 1MB
        logger "ERROR" "Package file is too small: $(numfmt --to=iec-i --suffix=B "${pkg_size}")"
        return 1
    fi
    
    # Verify package structure
    if ! pkgutil --check-signature "$pkg_file" >/dev/null 2>&1; then
        logger "ERROR" "Package signature verification failed"
        return 1
    fi
    
    return 0
}

# Download package
download_pkg() {
    local pkg_file="$1"
    local attempts=3
    local attempt=1
    local success=false
    
    logger "INFO" "Downloading Slack package..."
    while [ "$attempt" -le "$attempts" ] && [ "$success" = false ]; do
        if curl "${CURL_OPTS[@]}" -o "$pkg_file" "$BASE_URL"; then
            success=true
        else
            logger "WARN" "Download failed (attempt $attempt/$attempts)"
            sleep 2
            ((attempt++))
        fi
    done
    
    if ! $success; then
        logger "ERROR" "Failed to download package after $attempts attempts"
        return 1
    fi
    
    # Verify package integrity
    if ! verify_package "$pkg_file"; then
        return 1
    fi
    
    return 0
}

# Configure Slack Helper permissions
configure_slack_helper() {
    local slack_path="$1"
    local current_user="$2"
    
    logger "INFO" "Configuring Slack Helper permissions..."
    
    # Find Slack Helper app
    local helper_path="$slack_path/Contents/Frameworks/Slack Helper.app"
    if [ ! -d "$helper_path" ]; then
        logger "WARN" "Could not find Slack Helper.app at expected location"
        return 0
    fi
    
    # Reset existing permissions first
    logger "DEBUG" "Resetting existing permissions"
    tccutil reset All "Slack Helper" 2>/dev/null || true
    
    # Set ownership and permissions
    logger "DEBUG" "Setting ownership and permissions for Slack Helper"
    chown -R "$current_user" "$helper_path"
    chmod -R 755 "$helper_path"
    
    # Configure authorization system for root access
    local auth_db="/etc/authorization"
    if [ -f "$auth_db" ]; then
        logger "DEBUG" "Configuring authorization system for Slack Helper"
        security authorizationdb write system.privilege.admin allow 2>/dev/null || true
    fi
    
    # Add security exception for signed software
    logger "DEBUG" "Adding security exception for signed software"
    spctl --add --label "Slack Helper" "$helper_path" 2>/dev/null || true
    
    # Create TCC profile for MDM installation
    logger "DEBUG" "Creating TCC profile for MDM"
    local profile_path="/Library/Management/Profiles/com.tinyspeck.slackmacgap.tcc.mobileconfig"
    
    # Ensure directory exists
    mkdir -p "$(dirname "$profile_path")"

    # Pre-generate the payload UUIDs. The heredoc below is intentionally
    # unquoted so these expand; it contains no other shell-special sequences.
    local payload_content_uuid profile_uuid
    payload_content_uuid=$(uuidgen)
    profile_uuid=$(uuidgen)

    cat > "$profile_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadDescription</key>
            <string>Configures TCC access for Slack Helper</string>
            <key>PayloadDisplayName</key>
            <string>TCC Permissions</string>
            <key>PayloadIdentifier</key>
            <string>com.tinyspeck.slackmacgap.tcc</string>
            <key>PayloadType</key>
            <string>com.apple.TCC.configuration-profile-policy</string>
            <key>PayloadUUID</key>
            <string>${payload_content_uuid}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>Services</key>
            <dict>
                <key>Accessibility</key>
                <array>
                    <dict>
                        <key>Allowed</key>
                        <true/>
                        <key>CodeRequirement</key>
                        <string>identifier "com.tinyspeck.slackmacgap.helper" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>com.tinyspeck.slackmacgap.helper</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                    </dict>
                </array>
                <key>SystemPolicyAllFiles</key>
                <array>
                    <dict>
                        <key>Allowed</key>
                        <true/>
                        <key>CodeRequirement</key>
                        <string>identifier "com.tinyspeck.slackmacgap.helper" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>com.tinyspeck.slackmacgap.helper</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                    </dict>
                </array>
            </dict>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>Slack Helper TCC Permissions</string>
    <key>PayloadIdentifier</key>
    <string>com.tinyspeck.slackmacgap.tcc</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>${profile_uuid}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF
    
    # Set proper permissions on profile
    chown root:wheel "$profile_path"
    chmod 644 "$profile_path"
    
    # Verify permissions
    if [ "$(stat -f %u "$helper_path")" != "$(id -u "$current_user")" ]; then
        logger "WARN" "Failed to set ownership for Slack Helper"
        return 1
    fi
    
    logger "INFO" "Successfully configured Slack Helper permissions"
    logger "INFO" "TCC profile created at: $profile_path"
    logger "INFO" "Deploy this profile via MDM to grant TCC permissions"
    return 0
}

# Install package
install_pkg() {
    local pkg_file="$1"
    local target_dir
    
    # Set target directory based on user type
    if [ "$TARGET_USER" = "system" ]; then
        target_dir="/Applications"
    else
        target_dir="$TARGET_HOME/Applications"
    fi
    
    # Ensure target directory exists
    if ! mkdir -p "$target_dir"; then
        logger "ERROR" "Failed to create target directory: $target_dir"
        return 1
    fi
    
    # Check for existing installations
    logger "DEBUG" "Checking for existing Slack installations..."
    find /Applications -name "Slack.app" -ls || true
    find "$target_dir" -name "Slack.app" -ls || true
    
    # Install package
    logger "INFO" "Installing Slack package..."
    if ! installer -pkg "$pkg_file" -target /; then
        logger "ERROR" "Failed to install package"
        return 1
    fi
    
    # Wait for installer to complete
    logger "DEBUG" "Waiting for installer to complete..."
    sleep 8
    
    # Use the robust find_slack_app function to locate the installation
    logger "DEBUG" "Checking installation locations..."
    local installed_path=""
    
    # Use the comprehensive search function
    if installed_path=$(find_slack_app 2>/dev/null); then
        logger "DEBUG" "Found Slack.app at: $installed_path"
    else
        logger "WARN" "Comprehensive search failed, trying fallback search..."
        # Fallback: check common locations manually
        local fallback_paths=(
            "/Applications/Slack.app"
            "/var/root/Applications/Slack.app"
            "/private/var/root/Applications/Slack.app"
            "$target_dir/Slack.app"
            "/System/Applications/Slack.app"
            "/usr/local/Applications/Slack.app"
        )
        
        for path in "${fallback_paths[@]}"; do
            if [ -d "$path" ]; then
                installed_path="$path"
                logger "DEBUG" "Found Slack.app via fallback at: $path"
                break
            fi
        done
        
        if [ -z "$installed_path" ]; then
            logger "ERROR" "Could not find installed Slack.app even with fallback search"
            return 1
        fi
    fi
    
    # Move to user's Applications if not already there
    if [ "$installed_path" != "$target_dir/Slack.app" ]; then
        logger "DEBUG" "Moving Slack.app to user's Applications directory"
        if [ -d "$target_dir/Slack.app" ]; then
            logger "DEBUG" "Removing existing Slack.app in target directory"
            rm -rf "$target_dir/Slack.app"
        fi
        
        if ! mv "$installed_path" "$target_dir/"; then
            logger "ERROR" "Failed to move Slack.app to target directory"
            return 1
        fi
    fi
    
    # Configure Slack Helper permissions
    if ! configure_slack_helper "$target_dir/Slack.app" "$TARGET_USER"; then
        logger "WARN" "Failed to configure Slack Helper permissions"
        # Continue anyway as this is not critical
    fi
    
    # Set proper ownership regardless of whether we moved it or not
    if [ "$TARGET_USER" = "system" ]; then
        logger "DEBUG" "Setting system ownership to root:admin"
        if ! chown -R "root:admin" "$target_dir/Slack.app"; then
            logger "ERROR" "Failed to set ownership on $target_dir/Slack.app"
            return 1
        fi
    else
        logger "DEBUG" "Setting ownership to $TARGET_USER:staff"
        if ! chown -R "$TARGET_USER:staff" "$target_dir/Slack.app"; then
            logger "ERROR" "Failed to set ownership on $target_dir/Slack.app"
            return 1
        fi
    fi
    
    # Set SLACK_APP to the correct path
    SLACK_APP="$target_dir/Slack.app"
    return 0
}

# Verify installation
verify_installation() {
    local slack_path
    slack_path=$(find_slack_app) || {
        logger "ERROR" "Slack.app could not be found for verification."
        return 1
    }
    logger "INFO" "Verifying Slack installation at $slack_path"
    if [ ! -d "$slack_path" ]; then
        logger "ERROR" "Slack.app not found at $slack_path after install"
        return 1
    fi
    # Check version
    local version
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$slack_path/Contents/Info.plist" 2>/dev/null || true)
    if [ -z "$version" ]; then
        logger "ERROR" "Could not read Slack version from $slack_path"
        return 1
    fi
    logger "INFO" "Installed Slack version: $version"
    # Validate key bundle files, allowing for different Electron layouts
    local core_bin="$slack_path/Contents/MacOS/Slack"
    local info_plist="$slack_path/Contents/Info.plist"
    local app_asar="$slack_path/Contents/Resources/app.asar"
    local app_asar_unpacked="$slack_path/Contents/Resources/app.asar.unpacked"
    local app_dir="$slack_path/Contents/Resources/app"

    if [ ! -x "$core_bin" ]; then
        logger "ERROR" "Missing or non-executable Slack binary at: $core_bin"
        return 1
    fi
    if [ ! -f "$info_plist" ]; then
        logger "ERROR" "Missing Info.plist at: $info_plist"
        return 1
    fi
    if [ -f "$app_asar" ]; then
        logger "DEBUG" "Found app.asar at: $app_asar"
    elif [ -d "$app_asar_unpacked" ]; then
        logger "DEBUG" "Found app.asar.unpacked at: $app_asar_unpacked"
    elif [ -d "$app_dir" ]; then
        logger "DEBUG" "Found unpacked app resources at: $app_dir"
    else
        logger "ERROR" "Missing application resources (expected one of: $app_asar, $app_asar_unpacked, or $app_dir)"
        return 1
    fi

    # Set SLACK_APP to detected path for downstream use
    SLACK_APP="$slack_path"
    return 0
}


# Launch Slack
launch_slack() {
    local attempts=3
    local success=false
    
    # Skip launching in setup/system context
    if [ "$TARGET_USER" = "system" ]; then
        logger "INFO" "Skipping Slack launch in setup/system context"
        return 0
    fi
    
    logger "INFO" "Launching Slack..."
    for ((i=1; i<=attempts; i++)); do
        if sudo -u "$TARGET_USER" open "$SLACK_APP"; then
            success=true
            break
        fi
        logger "WARN" "Failed to launch Slack (attempt $i/$attempts)"
        sleep 2
    done
    
    if ! $success; then
        logger "WARN" "Could not launch Slack - please try launching manually"
        return 1
    fi
    
    # Verify process is running
    local check_attempts=5
    success=false
    
    logger "DEBUG" "Verifying Slack process..."
    for ((i=1; i<=check_attempts; i++)); do
        if pgrep -u "$TARGET_USER" -f "Slack.app" >/dev/null 2>&1; then
            success=true
            break
        fi
        sleep 1
    done
    
    if ! $success; then
        logger "WARN" "Could not verify Slack process"
        return 1
    fi
    
    return 0
}

# Find Slack.app in all common locations
find_slack_app() {
    logger "DEBUG" "Checking for Slack.app in all possible locations..." >&2
    local checked=()
    # 1. System-wide
    if [ -d "/Applications/Slack.app" ]; then
        logger "DEBUG" "Found Slack.app at /Applications/Slack.app" >&2
        echo "/Applications/Slack.app"
        return 0
    else
        checked+=("/Applications/Slack.app:notfound")
    fi
    # 2. User home Applications for all users
    for userdir in /Users/*; do
        if [ -d "$userdir/Applications/Slack.app" ]; then
            logger "DEBUG" "Found Slack.app at $userdir/Applications/Slack.app" >&2
            echo "$userdir/Applications/Slack.app"
            return 0
        else
            checked+=("$userdir/Applications/Slack.app:notfound")
        fi
    done
    # 3. Shared Applications
    if [ -d "/Users/Shared/Applications/Slack.app" ]; then
        logger "DEBUG" "Found Slack.app at /Users/Shared/Applications/Slack.app" >&2
        echo "/Users/Shared/Applications/Slack.app"
        return 0
    else
        checked+=("/Users/Shared/Applications/Slack.app:notfound")
    fi
    # 4. mdfind (Spotlight)
    local found
    found=$(mdfind "kMDItemCFBundleIdentifier == 'com.tinyspeck.slackmacgap'" 2>/dev/null | head -n1)
    if [ -n "$found" ] && [ -d "$found" ]; then
        logger "DEBUG" "Found Slack.app via mdfind at $found" >&2
        echo "$found"
        return 0
    else
        checked+=("mdfind:nonefound")
    fi
    # 5. Fallback: targeted find in common locations (avoid full filesystem scan)
    local fallback_search_paths=(
        "/var/root/Applications"
        "/private/var/root/Applications"
        "/Library/Application Support"
        "/usr/local/Applications"
    )
    
    for search_path in "${fallback_search_paths[@]}"; do
        if [ -d "$search_path" ]; then
            found=$(find "$search_path" -maxdepth 2 -type d -name "Slack.app" 2>/dev/null | head -n1)
            if [ -n "$found" ] && [ -d "$found" ]; then
                logger "DEBUG" "Found Slack.app via targeted find at $found" >&2
                echo "$found"
                return 0
            fi
        fi
    done
    checked+=("targeted_find:nonefound")
    logger "ERROR" "Slack.app not found in any expected location. Checks: ${checked[*]}. TARGET_USER='$TARGET_USER', TARGET_HOME='$TARGET_HOME'" >&2
    return 1
}

wait_for_slack_app() {
    local max_attempts=10
    local attempt=1
    local slack_path=""
    while [ $attempt -le $max_attempts ]; do
        # Use the robust finder to locate Slack anywhere it may be installed
        if slack_path=$(find_slack_app 2>/dev/null); then
            logger "DEBUG" "Slack.app appeared at $slack_path after $attempt attempt(s)"
            return 0
        fi
        sleep 2
        attempt=$((attempt+1))
    done
    logger "ERROR" "Slack.app did not appear after $max_attempts attempts in any expected location"
    return 1
}


# Main function
main() {
    # Get user context
    TARGET_USER=$(get_current_user) || exit 1
    TARGET_HOME=$(get_user_home "$TARGET_USER") || exit 1

    # Set up paths
    local pkg_file="$TEMP_FOLDER/slack.pkg"
    if [ "$TARGET_USER" = "system" ]; then
        SLACK_APP="/Applications/Slack.app"
    else
        SLACK_APP="$TARGET_HOME/Applications/Slack.app"
    fi

    # Robust cleanup of all old Slack installs
    logger "INFO" "Removing any old Slack installations..."
    if [ "$TARGET_USER" = "system" ]; then
        rm -rf "/Applications/Slack.app" "/Users/Shared/Applications/Slack.app"
    else
        rm -rf "/Applications/Slack.app" "$TARGET_HOME/Applications/Slack.app" "/Users/Shared/Applications/Slack.app"
    fi
    logger "DEBUG" "rm -rf completed"

    # Check disk space
    local check_path
    if [ "$TARGET_USER" = "system" ]; then
        check_path="/Applications"
    else
        check_path="$TARGET_HOME"
    fi
    
    if ! check_disk_space "$check_path"; then
        logger "DEBUG" "check_disk_space failed, exiting"
        exit 1
    fi
    logger "DEBUG" "check_disk_space succeeded"

    # Download and install
    if ! download_pkg "$pkg_file"; then
        logger "ERROR" "Failed to download package"
        exit 1
    fi
    logger "DEBUG" "download_pkg succeeded"

    if ! install_pkg "$pkg_file"; then
        logger "ERROR" "Failed to install package"
        exit 1
    fi
    logger "DEBUG" "install_pkg succeeded"

    # Deep diagnostics: where did Slack.app go?
    logger "DEBUG" "Listing contents of /Applications and user's Applications directory:"
    found_slack=0
    # Check system Applications
    for app in /Applications/*Slack*; do
        if [ -e "$app" ]; then
            ls -ld "$app"
            found_slack=1
        fi
    done
    # Check user's Applications
    for app in "$TARGET_HOME"/Applications/*Slack*; do
        if [ -e "$app" ]; then
            ls -ld "$app"
            found_slack=1
        fi
    done
    if [ "$found_slack" -eq 0 ]; then
        logger "DEBUG" "No Slack found in /Applications or $TARGET_HOME/Applications"
    fi
    logger "DEBUG" "Slack.app diagnostic listing complete"

    logger "DEBUG" "Searching common locations for Slack.app after install..."
    # Quick diagnostic: check only common locations (avoid full-disk search which causes timeout)
    for location in "/Applications/Slack.app" "$TARGET_HOME/Applications/Slack.app" "/Users/Shared/Applications/Slack.app"; do
        if [ -d "$location" ]; then
            logger "DEBUG" "Found Slack.app at: $location"
        fi
    done
    logger "DEBUG" "Slack.app location check complete"

    logger "DEBUG" "Last 50 lines of /var/log/install.log:"
    tail -50 /var/log/install.log || logger "DEBUG" "tail failed, continuing"
    logger "DEBUG" "tail of install.log complete"

    # Wait for Slack.app to appear after install (MDM timing issue workaround)
    logger "DEBUG" "Waiting for Slack.app to appear using find_slack_app..."
    if ! wait_for_slack_app; then
        logger "ERROR" "Slack.app did not appear after install"
        exit 1
    fi
    logger "DEBUG" "wait_for_slack_app succeeded"

    logger "DEBUG" "Starting verify_installation..."
    if ! verify_installation; then
        logger "ERROR" "Installation verification failed"
        exit 1
    fi
    logger "DEBUG" "verify_installation succeeded"

    if ! launch_slack; then
        logger "WARN" "Failed to launch Slack"
    fi

    logger "INFO" "Installation completed successfully"
}


# Run main function
main
