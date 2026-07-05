#!/bin/bash

# Function to safely remove files and directories
remove_item() {
    if [[ -e "$1" ]]; then
        echo "Removing: $1"
        rm -rf "$1"
    fi
}

# Define the paths to be removed
onedrive_app="/Applications/OneDrive.app"
onedrive_support_dir="$HOME/Library/Application Support/OneDrive"
onedrive_cache_dir="$HOME/Library/Caches/com.microsoft.OneDrive"
onedrive_preferences="$HOME/Library/Preferences/com.microsoft.OneDrive.plist"
onedrive_sandbox_dir="$HOME/Library/Containers/com.microsoft.OneDrive"
onedrive_logs_dir="$HOME/Library/Logs/OneDrive"
onedrive_keychains="$HOME/Library/Keychains/OneDrive.keychain-db"

# Remove the OneDrive application
remove_item "$onedrive_app"

# Remove associated files and directories
remove_item "$onedrive_support_dir"
remove_item "$onedrive_cache_dir"
remove_item "$onedrive_preferences"
remove_item "$onedrive_sandbox_dir"
remove_item "$onedrive_logs_dir"
remove_item "$onedrive_keychains"

# Remove LaunchAgents and LaunchDaemons if they exist
launch_agents_dir="$HOME/Library/LaunchAgents/com.microsoft.OneDriveStandaloneUpdater.plist"
launch_daemons_dir="/Library/LaunchDaemons/com.microsoft.OneDriveStandaloneUpdaterDaemon.plist"
launch_agent_files=("com.microsoft.OneDrive.launcher.plist" "com.microsoft.OneDriveUpdater.plist")
launch_daemon_files=("com.microsoft.OneDriveUpdater.plist")

for file in "${launch_agent_files[@]}"; do
    remove_item "$launch_agents_dir/$file"
done

for file in "${launch_daemon_files[@]}"; do
    remove_item "$launch_daemons_dir/$file"
done

# Inform the user (if needed)
echo "Microsoft OneDrive and all associated files have been removed."

# Exit script
exit 0
