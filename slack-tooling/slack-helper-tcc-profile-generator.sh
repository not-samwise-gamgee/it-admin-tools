#!/bin/bash

# Generate Slack Helper TCC Profile for MDM Deployment
# This creates a configuration profile that grants necessary permissions to Slack Helper

set -euo pipefail

# Logging function
logger() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

# Generate TCC profile
generate_tcc_profile() {
    local output_path="${1:-./slack_helper_tcc.mobileconfig}"

    logger "INFO" "Generating Slack Helper TCC profile..."
    
    cat > "$output_path" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadDescription</key>
            <string>Grants TCC permissions for Slack Helper to prevent admin authentication prompts</string>
            <key>PayloadDisplayName</key>
            <string>Slack Helper TCC Permissions</string>
            <key>PayloadIdentifier</key>
            <string>com.tinyspeck.slackmacgap.tcc</string>
            <key>PayloadType</key>
            <string>com.apple.TCC.configuration-profile-policy</string>
            <key>PayloadUUID</key>
            <string>A1B2C3D4-E5F6-7890-ABCD-EF1234567890</string>
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
                <key>SystemPolicyDesktopFolder</key>
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
                <key>SystemPolicyDocumentsFolder</key>
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
                <key>SystemPolicyDownloadsFolder</key>
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
                <key>PostEvent</key>
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
    <string>B2C3D4E5-F6G7-8901-BCDE-F23456789012</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

    logger "INFO" "TCC profile generated at: $output_path"
    logger "INFO" "Deploy this profile via your MDM system to resolve Slack Helper admin prompts"
    
    return 0
}

# Main execution
main() {
    local output_file="${1:-slack_helper_tcc.mobileconfig}"
    
    if ! generate_tcc_profile "$output_file"; then
        logger "ERROR" "Failed to generate TCC profile"
        exit 1
    fi
    
    logger "INFO" "Profile generation completed successfully"
    logger "INFO" "Next steps:"
    logger "INFO" "1. Upload $output_file to your MDM system"
    logger "INFO" "2. Deploy as a configuration profile to affected users"
    logger "INFO" "3. Users should no longer see Slack Helper admin prompts"
}

# Run with optional output path argument
main "$@"
