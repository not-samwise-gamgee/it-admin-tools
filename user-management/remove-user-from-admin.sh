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

# Check if the user is in the admin group
if dseditgroup -o checkmember -m "$logged_in_user" admin | grep -q "yes"; then

  # Remove the user from the admin group
  sudo dseditgroup -o edit -d "$logged_in_user" -t user admin

  # check to make sure user is removed from the admin group
  if dseditgroup -o checkmember -m "$logged_in_user" admin | grep -q "no"; then
    #finish it up
    echo "$logged_in_user has been removed from the admin group."
  fi
fi
