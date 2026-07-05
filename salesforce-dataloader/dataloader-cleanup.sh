#!/bin/bash
# DataLoader Cleanup Script
# Removes all DataLoader installations and clears system caches to resolve version conflicts

set -e

# Get the actual logged-in user
CONSOLE_USER=$(stat -f%Su /dev/console)
USER_HOME=$(eval echo "~${CONSOLE_USER}")

echo "=== DataLoader Complete Cleanup ==="
echo "User: $CONSOLE_USER"
echo "Home: $USER_HOME"
echo

# Function to safely remove directory if it exists
safe_remove() {
    local path="$1"
    if [[ -e "$path" ]]; then
        echo "Removing: $path"
        rm -rf "$path"
    fi
}

# Function to kill any running DataLoader processes
kill_dataloader_processes() {
    echo "Checking for running DataLoader processes..."
    pkill -f "dataloader" 2>/dev/null || true
    pkill -f "DataLoader" 2>/dev/null || true
    pkill -f "Data Loader" 2>/dev/null || true
    sleep 2
}

# Kill any running DataLoader processes first
kill_dataloader_processes

echo "=== Removing DataLoader Applications ==="

# Remove from all possible locations
locations=(
    "/Applications/Data Loader.app"
    "/Applications/DataLoader.app"
    "$USER_HOME/Applications/Data Loader.app"
    "$USER_HOME/Applications/DataLoader.app"
    "/System/Applications/Data Loader.app"
    "/System/Applications/DataLoader.app"
    "$USER_HOME/Desktop/Data Loader.app"
    "$USER_HOME/Desktop/DataLoader.app"
    "$USER_HOME/Downloads/Data Loader.app"
    "$USER_HOME/Downloads/DataLoader.app"
)

for location in "${locations[@]}"; do
    safe_remove "$location"
done

# Use find to catch any other DataLoader apps we might have missed
echo "Searching for additional DataLoader installations..."
find /Applications "$USER_HOME/Applications" "$USER_HOME/Desktop" "$USER_HOME/Downloads" -maxdepth 2 -name "*ataloader*" -type d 2>/dev/null | while read -r app_path; do
    echo "Found additional DataLoader app: $app_path"
    rm -rf "$app_path"
done

echo "=== Removing Configuration Files ==="

# Remove all DataLoader configuration and cache files
config_paths=(
    "$USER_HOME/.dataloader"
    "$USER_HOME/Library/Application Support/dataloader"
    "$USER_HOME/Library/Application Support/DataLoader"
    "$USER_HOME/Library/Application Support/Data Loader"
    "$USER_HOME/Library/Preferences/com.salesforce.dataloader.plist"
    "$USER_HOME/Library/Preferences/com.salesforce.DataLoader.plist"
    "$USER_HOME/Library/Caches/com.salesforce.dataloader"
    "$USER_HOME/Library/Caches/com.salesforce.DataLoader"
    "$USER_HOME/Library/Saved Application State/com.salesforce.dataloader.savedState"
    "$USER_HOME/Library/Saved Application State/com.salesforce.DataLoader.savedState"
)

for config_path in "${config_paths[@]}"; do
    safe_remove "$config_path"
done

echo "=== Clearing System Caches ==="

# Clear LaunchServices database to remove stale app registrations
echo "Clearing LaunchServices database..."
sudo -u "$CONSOLE_USER" /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user

# Clear Spotlight index for DataLoader
echo "Clearing Spotlight metadata..."
sudo mdutil -E / 2>/dev/null || true

# Clear quarantine attributes that might be cached
echo "Clearing quarantine cache..."
xattr -d com.apple.quarantine "$USER_HOME/Applications" 2>/dev/null || true

echo "=== Verification ==="

# Verify cleanup
remaining_apps=$(find /Applications "$USER_HOME/Applications" -maxdepth 2 -name "*ataloader*" -type d 2>/dev/null | wc -l)
if [[ $remaining_apps -eq 0 ]]; then
    echo "✓ All DataLoader applications removed successfully"
else
    echo "⚠️  Warning: $remaining_apps DataLoader applications still found"
    find /Applications "$USER_HOME/Applications" -maxdepth 2 -name "*ataloader*" -type d 2>/dev/null
fi

# Check for remaining config files
remaining_configs=0
for config_path in "${config_paths[@]}"; do
    if [[ -e "$config_path" ]]; then
        echo "⚠️  Warning: Config file still exists: $config_path"
        ((remaining_configs++))
    fi
done

if [[ $remaining_configs -eq 0 ]]; then
    echo "✓ All DataLoader configuration files removed successfully"
fi

echo
echo "=== Cleanup Complete ==="
echo "You can now run the DataLoader installation script to install a fresh copy."
echo "The system caches have been cleared to prevent version conflicts."
echo
echo "Next steps:"
echo "1. Run the DataLoader installation script"
echo "2. Launch DataLoader from ~/Applications/Data Loader.app"
echo "3. Verify the version shows as 64.1.0"

exit 0
