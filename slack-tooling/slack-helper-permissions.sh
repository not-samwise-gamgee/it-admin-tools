#!/bin/bash

# Strict error handling
set -euo pipefail
IFS=$'\n\t'

# Logging function
logger() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
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
        return 1
    fi
    
    # Reset permissions using tccutil
    logger "DEBUG" "Resetting permissions for Slack Helper"
    tccutil reset All "com.tinyspeck.slackmacgap" || logger "WARN" "Failed to reset main app permissions"
    
    # Check if helper bundle exists before trying to reset it
    local helper_bundle_id="com.tinyspeck.slackmacgap.helper"
    if [ -f "$helper_path/Contents/Info.plist" ]; then
        # Try to get actual bundle ID from helper app
        local actual_helper_id
        actual_helper_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$helper_path/Contents/Info.plist" 2>/dev/null) || {
            logger "DEBUG" "Could not read helper bundle ID from Info.plist"
        }
        if [ -n "${actual_helper_id:-}" ]; then
            helper_bundle_id="$actual_helper_id"
            logger "DEBUG" "Found helper bundle ID: $helper_bundle_id"
        fi
    fi
    
    # Only try to reset if bundle ID exists
    if tccutil reset All "$helper_bundle_id" 2>/dev/null; then
        logger "DEBUG" "Successfully reset permissions for $helper_bundle_id"
    else
        logger "DEBUG" "Helper bundle ID '$helper_bundle_id' not found in TCC database (this is normal for newer Slack versions)"
    fi
    
    # Set proper ownership and permissions for Slack Helper
    logger "DEBUG" "Setting ownership and permissions for Slack Helper"
    chown -R "$current_user:staff" "$helper_path"
    chmod -R 755 "$helper_path"
    
    # NOTE: TCC (Full Disk Access / Accessibility) grants are applied via the
    # MDM-deployed configuration profile generated below — NOT by writing to the
    # system TCC.db directly. Direct TCC.db writes were removed: they bypass
    # macOS TCC enforcement, only succeed on SIP-disabled hosts, and would grant
    # access to a bundle ID derived from a caller-supplied path (least-privilege
    # violation). The MDM profile is the supported, signed mechanism.

    # Create TCC profile for MDM installation
    logger "DEBUG" "Creating TCC profile for MDM"
    local profile_path="/Library/Management/Profiles/com.tinyspeck.slackmacgap.tcc.mobileconfig"
    
    # Ensure directory exists
    mkdir -p "$(dirname "$profile_path")"
    
    # Use the detected helper bundle ID for the profile
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
            <string>$(uuidgen)</string>
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
                        <string>identifier "$helper_bundle_id" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>$helper_bundle_id</string>
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
                        <string>identifier "$helper_bundle_id" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>$helper_bundle_id</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                    </dict>
                </array>
                <key>SystemPolicyDesktopFolder</key>
                <array>
                    <dict>
                        <key>Allowed</key>
                        <true/>
                        <key>CodeRequirement</key>
                        <string>identifier "$helper_bundle_id" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>$helper_bundle_id</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                    </dict>
                </array>
                <key>SystemPolicyDocumentsFolder</key>
                <array>
                    <dict>
                        <key>Allowed</key>
                        <true/>
                        <key>CodeRequirement</key>
                        <string>identifier "$helper_bundle_id" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>$helper_bundle_id</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                    </dict>
                </array>
                <key>SystemPolicyDownloadsFolder</key>
                <array>
                    <dict>
                        <key>Allowed</key>
                        <true/>
                        <key>CodeRequirement</key>
                        <string>identifier "$helper_bundle_id" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>$helper_bundle_id</string>
                        <key>IdentifierType</key>
                        <string>bundleID</string>
                    </dict>
                </array>
                <key>PostEvent</key>
                <array>
                    <dict>
                        <key>Allowed</key>
                        <true/>
                        <key>CodeRequirement</key>
                        <string>identifier "$helper_bundle_id" and anchor apple generic</string>
                        <key>Identifier</key>
                        <string>$helper_bundle_id</string>
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
    <string>$(uuidgen)</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF
    
    # Set proper permissions on profile
    chown root:wheel "$profile_path"
    chmod 644 "$profile_path"
    
    # Try to install the profile directly (works if MDM allows it)
    logger "DEBUG" "Attempting to install TCC profile directly"
    if profiles -I -F "$profile_path" 2>/dev/null; then
        logger "INFO" "Successfully installed TCC profile"
    else
        logger "WARN" "Could not install profile directly - deploy via MDM instead"
    fi
    
    # NOTE: A NOPASSWD sudoers entry for the Slack Helper binary was removed.
    # Granting passwordless root to a user-writable application binary is a
    # least-privilege violation (SOC2 CC6.3 / PCI DSS Req 7.1) — replacing the
    # binary would yield root execution. The required permissions are provided
    # via the MDM-deployed TCC profile above; no sudoers change is needed.

    # Diagnostic information
    logger "INFO" "Slack Helper configuration completed"
    logger "INFO" "Helper Bundle ID: $helper_bundle_id"
    logger "INFO" "Helper Path: $helper_path"
    logger "INFO" "TCC profile created at: $profile_path"
    logger "INFO" "If issues persist, ensure the TCC profile is deployed via MDM"
    
    return 0
}

# Main execution
main() {
    local slack_path
    local current_user
    
    # We expect to be running as root via MDM
    if [ "$EUID" -ne 0 ]; then
        logger "ERROR" "This script must be run as root via MDM"
        exit 1
    fi
    
    # Get current console user
    current_user=$(scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ { print $3 }')
    if [ -z "$current_user" ]; then
        current_user=$(who | awk '/console/ { print $1 }' | head -n1)
    fi
    
    if [ -z "$current_user" ]; then
        logger "ERROR" "Could not determine current user"
        exit 1
    fi
    
    # Find Slack.app location (check system Applications first since this is MDM)
    for path in \
        "/Applications/Slack.app" \
        "/Users/$current_user/Applications/Slack.app"; do
        if [ -d "$path" ]; then
            slack_path="$path"
            break
        fi
    done
    
    if [ -z "${slack_path:-}" ]; then
        logger "ERROR" "Could not find Slack.app"
        exit 1
    fi
    
    # Configure permissions
    if ! configure_slack_helper "$slack_path" "$current_user"; then
        logger "ERROR" "Failed to configure Slack Helper permissions"
        exit 1
    fi
}

# Run main function
main