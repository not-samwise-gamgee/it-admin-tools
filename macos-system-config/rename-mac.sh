#!/bin/bash
getUser=$(stat -f%Su /dev/console)
hwIdentifier=$(sysctl -n hw.model)
loggedInUser="$(dscl . -read "/Users/$getUser" RealName | grep -v RealName | xargs)"
# shellcheck disable=SC2034  # placeholder for callers to fold into their naming convention (see note below)
company="COMPANYNAME"

#variables $loggeInUser $company $hwIdentifier can be removed or changed to suit your device naming convention

	if [[ $hwIdentifier =~ "MacBookPro" ]] ; then
		echo "set name to: $loggedInUser-MBP"
		scutil --set ComputerName "$loggedInUser-MBP"
		scutil --set LocalHostName "$loggedInUser-MBP"
		scutil --set HostName "$loggedInUser-MBP"
	elif [[ $hwIdentifier =~ "MacBookAir" ]] ; then
		echo "set name to: $loggedInUser-MBA"
		scutil --set ComputerName "$loggedInUser-MBA"
		scutil --set LocalHostName "$loggedInUser-MBA"
		scutil --set HostName "$loggedInUser-MBA"
	elif [[ $hwIdentifier =~ "Macmini" ]] ; then
		echo "set name to: $loggedInUser-MM"
		scutil --set ComputerName "$loggedInUser-MM"
		scutil --set LocalHostName "$loggedInUser-MM"
		scutil --set HostName "$loggedInUser-MM"

	fi
