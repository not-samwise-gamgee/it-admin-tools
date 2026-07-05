#!/bin/sh

# Resolve the actual console user (not the inherited $USER env var, which is
# caller-controlled and would allow targeting an arbitrary account).
logged_in_user=$(stat -f '%Su' /dev/console)

# Guard: must be a real, non-root user with a safe username.
if [ -z "$logged_in_user" ] || [ "$logged_in_user" = "root" ] ||
	! printf '%s' "$logged_in_user" | grep -qE '^[A-Za-z0-9._-]+$'; then
	echo "Could not determine a valid console user; aborting." >&2
	exit 1
fi

#add logged in user to admin group
sudo dseditgroup -o edit -a "$logged_in_user" -t user admin

#verify that the user has been added to the admin group then finish
if dseditgroup -o checkmember -m "$logged_in_user" admin | grep -q "yes"; then
	#finish
	echo "$logged_in_user is a member of the admin group."
fi
