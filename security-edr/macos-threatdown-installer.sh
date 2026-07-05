#!/bin/bash

# Exit immediately if a command exits with a non-zero status, and on unset variables.
set -euo pipefail

# Malwarebytes account registration token. Must be provided via the environment so it is
# never committed to source. Fails loudly if unset.
: "${MALWAREBYTES_ACCOUNT_TOKEN:?set MALWAREBYTES_ACCOUNT_TOKEN to the ThreatDown account token}"

# Specify the full path where the downloaded file should be saved and name of the file being downloaded.
downloaded_file="/tmp/MBBRNebulaAgent.pkg"

# Specify the URL of the file being downloaded.
url="https://ark.mwbsys.com/epa.mac.installer/release"

echo "Downloading Malwarebytes Threatdown installation package..."
# Use curl to download the file to the specified directory.
sudo curl -o "$downloaded_file" -L "$url"

echo "Applying account token to installation package..."
# Apply the account token to the pkg file for account registration.
sudo xattr -w ACCOUNTTOKEN "$MALWAREBYTES_ACCOUNT_TOKEN" "$downloaded_file"

echo "Installing Malwarebytes Threatdown..."
# Install the package
sudo /usr/sbin/installer -pkg "$downloaded_file" -target /

echo "Installation complete."
# Clean up downloaded installer
rm -f "$downloaded_file"