#!/bin/zsh

# Uninstall Claude Desktop application without removing user's Claude project, cowork, or code files

# Define paths to remove
APP_PATH="/Applications/Claude.app"
PLIST_PATH="/Library/LaunchDaemons/com.claude.launchd.plist"

# Remove the application
rm -rf "$APP_PATH"

# Remove the associated plist file
rm -f "$PLIST_PATH"

echo "Claude Desktop application has been uninstalled."
