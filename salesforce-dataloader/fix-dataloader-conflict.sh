#!/bin/bash
# Fix DataLoader Version Conflict
# Removes old installations and fixes LaunchServices registration

set -e

# Get the actual logged-in user
CONSOLE_USER=$(stat -f%Su /dev/console)
USER_HOME=$(eval echo "~${CONSOLE_USER}")

echo "=== Fixing DataLoader Version Conflict ==="
echo "User: $CONSOLE_USER"
echo

# Kill any running DataLoader processes
echo "Stopping DataLoader processes..."
pkill -f "dataloader" 2>/dev/null || true
pkill -f "DataLoader" 2>/dev/null || true
sleep 2

# Remove old DataLoader installations from Desktop and Downloads
echo "Removing old DataLoader installations..."
rm -rf "$USER_HOME/Desktop/dataloader_v63.0.0 2" 2>/dev/null || true
rm -rf "$USER_HOME/Desktop/Dataloader" 2>/dev/null || true
rm -rf "$USER_HOME/Downloads/dataloader_v63.0.0 2" 2>/dev/null || true
rm -rf "$USER_HOME/Downloads/dataloader.app" 2>/dev/null || true

# Clear LaunchServices database to remove stale registrations
echo "Clearing LaunchServices database..."
sudo -u "$CONSOLE_USER" /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user

# Re-register the correct DataLoader app
echo "Re-registering DataLoader 64.1.0..."
if [[ -d "$USER_HOME/Applications/Data Loader.app" ]]; then
    sudo -u "$CONSOLE_USER" /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$USER_HOME/Applications/Data Loader.app"
fi

# Clear any quarantine attributes
xattr -dr com.apple.quarantine "$USER_HOME/Applications/Data Loader.app" 2>/dev/null || true

echo "✅ DataLoader conflict resolved!"
echo
echo "Next steps:"
echo "1. Launch DataLoader from ~/Applications/Data Loader.app"
echo "2. Verify it shows version 64.1.0"
echo "3. The app should now open correctly"

exit 0
