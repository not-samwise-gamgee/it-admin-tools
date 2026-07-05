#!/bin/bash

# -------------------------------------------------------------------------
# Allow Standard Users to Manage Printers
# Modifies macOS groups to allow standard non-admin users to install and manage printers.
# -------------------------------------------------------------------------

if [[ ${EUID:-0} -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo)."
    exit 1
fi

echo "Configuring macOS to allow standard users to manage printers..."

# 1. Unlock the "Printers & Scanners" preference pane in System Settings
/usr/bin/security authorizationdb write system.preferences.printing authenticate-session-owner

# 2. Grant permission for standard users to perform printer administration tasks
/usr/bin/security authorizationdb write system.print.admin authenticate-session-owner

# 3. Grant permission for standard users to manage print jobs 
/usr/bin/security authorizationdb write system.print.operator authenticate-session-owner

# 4. Add the 'everyone' group to the hidden '_lpadmin' group (CUPS requirement)
USER_LIST=$(/usr/bin/dscl . -list /Users UniqueID | /usr/bin/awk '$2 >= 501 && $2 < 1000 {print $1}')
for u in $USER_LIST; do
    /usr/sbin/dseditgroup -o edit -n /Local/Default -a "$u" -t user _lpadmin 2>/dev/null || true
done

echo "Printer management permissions have been updated successfully."
exit 0