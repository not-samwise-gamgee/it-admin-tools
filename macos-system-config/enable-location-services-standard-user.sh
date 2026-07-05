#!/bin/bash

# Enable the macOS Location Services MASTER switch at the system level.
#
# IMPORTANT: The Location Services master toggle is NOT a per-user preference. It lives in
# the _locationd domain:
#   /private/var/db/locationd/Library/Preferences/ByHost/com.apple.locationd.<HardwareUUID>.plist
# owned by _locationd:_locationd. Setting it requires: running as root, writing the value AS
# the _locationd user, and restarting the locationd daemon.
#
# Apple does not provide a fully supported way to script this, so treat it as BEST-EFFORT:
# it works on current macOS in most cases, but a reboot may be required for it to take
# effect, and some releases may reset or ignore it. Per-app location authorization remains
# user-driven (TCC) and is intentionally not touched here.
#
# Run as root (e.g. from your MDM). This is a system-wide setting; the previous per-user
# approach (writing ~/Library/Preferences/com.apple.locationd.plist) had no effect.

set -euo pipefail

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  echo "Error: this script must be run as root." >&2
  exit 1
fi

locationd_user="_locationd"
locationd_dir="/private/var/db/locationd"
byhost_dir="${locationd_dir}/Library/Preferences/ByHost"

# The ByHost plist is keyed by the machine's hardware UUID.
hardware_uuid=$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice \
  | /usr/bin/awk -F'"' '/IOPlatformUUID/{print $4}')

if [ -z "$hardware_uuid" ]; then
  echo "Error: could not determine the hardware UUID." >&2
  exit 1
fi

# `defaults` takes the domain path WITHOUT the trailing .plist extension.
plist_domain="${byhost_dir}/com.apple.locationd.${hardware_uuid}"

echo "Enabling Location Services master switch (hardware UUID: ${hardware_uuid})..."

# Ensure the ByHost directory exists and is owned by _locationd so the daemon trusts it.
/bin/mkdir -p "$byhost_dir"
/usr/sbin/chown -R "${locationd_user}:${locationd_user}" "$locationd_dir"

# Write the master switch AS _locationd so the value is accepted by the daemon.
if ! /usr/bin/sudo -u "$locationd_user" /usr/bin/defaults write "$plist_domain" LocationServicesEnabled -int 1; then
  echo "Error: failed to write LocationServicesEnabled to the _locationd domain." >&2
  exit 1
fi

# Re-assert ownership after the write.
/usr/sbin/chown -R "${locationd_user}:${locationd_user}" "$locationd_dir"

# Restart locationd so it reloads the setting.
echo "Restarting locationd to apply the change..."
if ! /bin/launchctl kickstart -k system/com.apple.locationd; then
  echo "Warning: could not restart locationd; a reboot may be required for the change to apply." >&2
fi

echo "Location Services enablement attempt complete. A reboot is recommended if it is not reflected immediately."
exit 0
