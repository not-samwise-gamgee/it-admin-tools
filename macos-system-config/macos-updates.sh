#!/bin/bash

################################################################################################
# macOS in-place updater (full-installer based) — generic
################################################################################################
# Originally a Big Sur 11.x point-release updater; generalized to drive an in-place
# update/upgrade to ANY target macOS version using the full "Install macOS <name>.app"
# installer and `startosinstall`.
#
# What it does:
#   * Prompts the logged-in user (with deferral) via osascript dialogs.
#   * Ensures the machine is on AC power and has enough free disk space.
#   * Locates an existing "Install macOS *.app", or acquires one via
#     `softwareupdate --fetch-full-installer` (preferred, no hardcoded URL), or via an
#     optional pinned InstallAssistant.pkg download (URL + SHA256) for locked builds.
#   * Runs `startosinstall` — on Apple Silicon it collects a Secure Token user's password
#     and passes it with --stdinpass; on Intel it runs without a password.
#
# Designed to be run periodically (e.g. every 15-30 min) from your MDM; MDM-agnostic.
#
# Configure the CONFIG block below (or override any value via the environment).
################################################################################################
# License Information
################################################################################################
# Provided as-is under the MIT License.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
# to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
# FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
################################################################################################

# EXIT CODES
# exit 1 = installer could not be acquired (download/fetch failed)
# exit 2 = Apple Silicon: current user is not a Secure Token user
# exit 3 = Apple Silicon: too many password attempts
# exit 4 = not enough disk space
# exit 5 = pinned download failed verification multiple times
# exit 6 = update failed, unknown
# exit 7 = unknown power error
# exit 8 = configuration error (e.g. TARGET_OS_VERSION not set)

################################# CONFIG (override via environment) #################################

# Org/Dept name shown to users in dialogs.
orgAndDeptName="${ORG_AND_DEPT_NAME:-IT}"

# REQUIRED: the macOS version you are updating/upgrading TO (e.g. "14.6.1" or "15.5").
# Used for eligibility checks, the softwareupdate fetch, and dialog messaging.
targetOsVersion="${TARGET_OS_VERSION:-}"

# Minimum current macOS version eligible to run this script (skips anything older).
minOsVersion="${MIN_OS_VERSION:-11.0}"

# Free disk space (in GB) required before attempting the update.
requiredFreeGB="${REQUIRED_FREE_GB:-30}"

# Deferral window in hours (how long before the user is re-prompted after deferring).
deferralWindow="${DEFERRAL_WINDOW:-24}"

# If "1", only OPEN the installer app for the user instead of running startosinstall.
LaunchInstallerOnly="${LAUNCH_INSTALLER_ONLY:-0}"

# Optional: explicit path to the installer app. If empty, the script auto-discovers
# "/Applications/Install macOS *.app".
installerAppPath="${INSTALLER_APP_PATH:-}"

# Optional: expected installer bundle version (CFBundleShortVersionString). If set, a
# present installer whose version differs is deleted and re-acquired.
expectedInstallerVersion="${EXPECTED_INSTALLER_VERSION:-}"

# Acquisition controls:
#   fetchWithSoftwareUpdate=1 -> try `softwareupdate --fetch-full-installer` (preferred).
#   installerPkgUrl/Sha256    -> optional pinned InstallAssistant.pkg fallback for locked builds.
fetchWithSoftwareUpdate="${FETCH_WITH_SOFTWAREUPDATE:-1}"
installerPkgUrl="${INSTALLER_PKG_URL:-}"
installerPkgSha256="${INSTALLER_PKG_SHA256:-}"

# osascript dialog timeouts (seconds).
osagiveup="${OSA_GIVEUP:-180}"
osatimeout="${OSA_TIMEOUT:-180}"

################################# Dont modify the contents below this line #################################

if [ -z "${targetOsVersion}" ]; then
	/bin/echo "TARGET_OS_VERSION is not set. Set it to the macOS version to update to (e.g. 15.5)."
	exit 8
fi

passwordTry="0"

# Robust console-user detection (survives fast user switching / loginwindow).
currentUser=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')

# Determine the processor brand (Apple vs Intel).
processorBrand=$(/usr/sbin/sysctl -n machdep.cpu.brand_string)

# Collect the current macOS version. SYSTEM_VERSION_COMPAT=0 prevents "10.16" being
# reported on very early macOS 11 builds; harmless on newer releases.
currentmacOSVersion=$(SYSTEM_VERSION_COMPAT=0 /usr/bin/sw_vers -productVersion)

# version_ge A B -> returns 0 (true) if version A >= version B (dotted numeric, e.g. 15.10 > 15.9).
version_ge() {
	[ "$(/usr/bin/printf '%s\n%s\n' "$1" "$2" | /usr/bin/sort -V | /usr/bin/tail -n1)" = "$1" ]
}

# Skip machines older than the minimum supported version.
if ! version_ge "${currentmacOSVersion}" "${minOsVersion}"; then
	/bin/echo "Current macOS ${currentmacOSVersion} is below the minimum (${minOsVersion}); this script does not apply."
	exit 0
fi

# Skip machines already at (or beyond) the target version.
if version_ge "${currentmacOSVersion}" "${targetOsVersion}"; then
	/bin/echo "macOS Version is ${currentmacOSVersion} and already meets the target ${targetOsVersion}."
	exit 0
else
	/bin/echo "Current macOS Version is: ${currentmacOSVersion}... Mac is eligible for update to ${targetOsVersion}..."
fi

# MDM self-service app used to source a branded dialog icon (genericized).
# Override MDM_AGENT_BIN / MDM_SELF_SERVICE_APP for your MDM; otherwise the
# generic macOS system icon is used.
MDM_AGENT_BIN="${MDM_AGENT_BIN:-/usr/local/bin/mdm-agent}"
MDM_SELF_SERVICE_APP="${MDM_SELF_SERVICE_APP:-Self Service.app}"
if [ ! -e "${MDM_AGENT_BIN}" ]; then
	iconFile="System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:ToolbarInfo.icns"
else
	iconFile="Applications:${MDM_SELF_SERVICE_APP}:Contents:Resources:AppIcon.icns"
fi

availableSpace=$(/bin/df -g / | /usr/bin/awk 'FNR==2{print $4}')

if [ "${availableSpace}" -lt "${requiredFreeGB}" ]; then
	echo "Not enough free space (need ${requiredFreeGB}GB, have ${availableSpace}GB)"
	exit 4
fi

currentTime=$(date +%s)

deferralTimeInSeconds=$((deferralWindow * 3600))

deferralFile="/var/tmp/.dft.macos-update"
deferralCountFile="/var/tmp/.dfc.macos-update"
if [ -e "${deferralFile}" ]; then
	lastDeferralTime=$(/bin/cat "${deferralFile}")

	timeDiff=$((currentTime - lastDeferralTime))

	/bin/echo "Current Time: $currentTime, Last Deferral Time: $lastDeferralTime, Time Diff: $timeDiff"

	if [ "${timeDiff}" -gt "${deferralTimeInSeconds}" ]; then
		/bin/echo "${deferralWindow} hours since deferral"
	else
		/bin/echo "Deferred too recently"
		exit 0
	fi

fi

# Locate the installer app: explicit override, else first "/Applications/Install macOS *.app".
# Echoes the path and returns 0 if found; returns 1 otherwise.
fFindInstaller ()
{
	if [ -n "${installerAppPath}" ] && [ -d "${installerAppPath}" ]; then
		/bin/echo "${installerAppPath}"
		return 0
	fi
	local app
	for app in /Applications/Install\ macOS*.app; do
		if [ -d "${app}" ]; then
			/bin/echo "${app}"
			return 0
		fi
	done
	return 1
}

# Validate an installer app against expectedInstallerVersion (if set). Returns 0 if OK.
fInstallerVersionOK ()
{
	local app="$1"
	if [ -z "${expectedInstallerVersion}" ]; then
		return 0
	fi
	local ver
	ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${app}/Contents/Info.plist" 2>/dev/null)
	if [ "${ver}" = "${expectedInstallerVersion}" ]; then
		return 0
	fi
	/bin/echo "Installer version '${ver}' does not match expected '${expectedInstallerVersion}'."
	return 1
}

fPowerCheck ()
{
	powerSource=$(/usr/bin/pmset -g ps | /usr/bin/awk -F"'" '{print $2}' )

	/bin/echo "Connected Power source is currently: $powerSource"

	if [ "${powerSource}" = "Battery Power" ]; then
		/bin/echo "Computer is NOT connected to AC power..."

	elif [ "${powerSource}" = "AC Power" ]; then
		/bin/echo "Computer IS connected to AC power..."
		fInstall
	else
		/bin/echo "Unknown error"
		fErrorOut
		# shellcheck disable=SC2317  # defensive fallback; fErrorOut normally exits first
		exit 7
	fi

	title="macOS ${targetOsVersion} Update - Connect to power"
	message="Your Mac is not yet connected to power.\n\nPlease connect to power and click Try Again."
	powerInput=$(/usr/bin/osascript<<END
	with timeout of ${osatimeout} seconds
set the answer to button returned of (display dialog "${message}" with icon file "${iconFile}" with title "${title}" buttons {"Defer ${deferralWindow} hour(s)", "Try Again"} default button 2 giving up after ${osagiveup})
	end timeout
END
)

	if [ "${powerInput}" = "Defer ${deferralWindow} hour(s)" ]; then
		/bin/echo "User chose to defer"
		fDefer
	elif [ "${powerInput}" = "Try Again" ]; then
		fPowerCheck
	else
		/bin/echo "Window timed out... will try again later..."
		exit 0
	fi
}

fDefer ()
{
	/usr/bin/killall caffeinate 2>/dev/null

	if [ -e "${deferralCountFile}" ]; then
		currentDefferalCount=$(/bin/cat "${deferralCountFile}")
	else
		currentDefferalCount="0"
	fi

	deferalCount=$((currentDefferalCount+1))

	/bin/echo "${deferalCount}" > "${deferralCountFile}"
	/bin/echo "${currentTime}" > "${deferralFile}"

	/bin/echo "User has chosen to defer, this is their ${deferalCount} defferal..."

	exit 0
}

# Preferred, URL-free acquisition: ask Apple's software update catalog for the full installer.
# Populates "/Applications/Install macOS *.app". Returns 0 on success.
fFetchFullInstaller ()
{
	if [ "${fetchWithSoftwareUpdate}" != "1" ]; then
		return 1
	fi
	/bin/echo "Fetching full installer for ${targetOsVersion} via softwareupdate..."
	/usr/bin/caffeinate -disu &
	local cafPid=$!
	/usr/sbin/softwareupdate --fetch-full-installer --full-installer-version "${targetOsVersion}"
	local rc=$?
	/bin/kill "${cafPid}" 2>/dev/null
	if [ "${rc}" -ne 0 ]; then
		/bin/echo "softwareupdate --fetch-full-installer failed (rc=${rc})."
		return 1
	fi
	return 0
}

# Optional pinned fallback: download a specific InstallAssistant.pkg and verify its SHA256.
# Only used when INSTALLER_PKG_URL is set. Installs the pkg (which lays down the installer app).
fInitManualSusDownload ()
{
	if [ -z "${installerPkgUrl}" ]; then
		/bin/echo "No pinned INSTALLER_PKG_URL set; skipping manual download."
		return 1
	fi

	local dlURL="${installerPkgUrl}"
	local fileChecksum="${installerPkgSha256}"

	## Other Variables ##
	finalURL=$(/usr/bin/curl "$dlURL" -s -L -I -o /dev/null -w '%{url_effective}')
	fileName="${finalURL##*/}"
	tmpDir="/private/tmp/download"
	pathToFile="$tmpDir/$fileName"
	dlTries=1
	vfTries=0
	percent=0

	downloadFile() {
		/usr/bin/curl -Ls "$finalURL" -o "$pathToFile"
		# shellcheck disable=SC2181  # loop re-runs curl at its end; $? reflects that retry intentionally
		while [[ "$?" -ne 0 ]]; do
			/bin/echo "Download Failed, retrying.  This is attempt $dlTries"
			/bin/sleep 5
			(( dlTries++ ))
			if [ "$dlTries" == 11 ]; then
				/bin/echo "Download has failed 10 times, exiting"
				/usr/bin/killall caffeinate 2>/dev/null
				exit 1
			fi
			/usr/bin/curl -Ls "$finalURL" -o "$pathToFile"
		done
	}

	getDownloadSize() {
		/usr/bin/curl -sI "$finalURL" | /usr/bin/grep -i "^Content-Length" | /usr/bin/awk '{print $2}' | /usr/bin/tr -d '\r'
	}

	dlPercent() {
		fSize=$(/bin/ls -nl "$pathToFile" | /usr/bin/awk '{print $5}')
		percent=$(/bin/echo "scale=2;($fSize/$dlSize)*100" | bc)
		percent=${percent%.*}
	}

	installPKG() {
		/bin/echo "PKG to install: $pathToFile"
		/usr/sbin/installer -pkg "$pathToFile" -target /
		if [ $? -ne 0 ]; then
			/bin/echo "Something went wrong during install..."
			/usr/bin/killall caffeinate 2>/dev/null
			exit 1
		fi
		/bin/echo "Install completed successfully..."
	}

	## Execute ##

	# Create temp directory for download
	if [ -d "$tmpDir" ]; then
		/bin/rm -rf "$tmpDir"
		/bin/mkdir "$tmpDir"
	else
		/bin/mkdir "$tmpDir"
	fi

	# Keep machine awake, as if user is active.
	/usr/bin/caffeinate -disu &

	# Download & Validate File
	dlSize=$(getDownloadSize)
	dlSUM=""
	while [ "$fileChecksum" != "$dlSUM" ]; do
		/bin/echo "Attempting to download and verify $fileName..."
		(( vfTries++ ))
		if [ $vfTries == 4 ]; then
			/bin/echo "Download and Verification has failed 3 times, exiting..."
			/usr/bin/killall caffeinate 2>/dev/null
			exit 5
		fi
		downloadFile &
		pid=$!
		# If this script is killed, kill the download.
		# shellcheck disable=SC2064  # $pid must expand now (this download's PID), not at signal time
		trap "kill $pid 2> /dev/null" EXIT
		# Track download progress
		while kill -0 "$pid" 2> /dev/null; do
			if [ -f "$pathToFile" ]; then
				dlPercent
				/bin/echo "Download at $percent%"
				/bin/sleep 10
			fi
		done
		# Disable the trap on a normal exit.
		trap - EXIT
		/bin/echo "Download complete. Verifying file..."
		dlSUM=$(/usr/bin/shasum -a 256 "$pathToFile" | /usr/bin/cut -d ' ' -f1)
	done

	# Perform Installation (lays down the "Install macOS *.app")
	installPKG

	# Cleanup
	/bin/echo "Cleaning up files and processes..."
	/usr/bin/killall caffeinate 2>/dev/null
	/bin/sleep 10
	/bin/rm -R "$tmpDir"
	return 0
}

fWelcomeB ()
{
	if [ "${currentUser}" == "root" ] || [ "${currentUser}" == "_mbsetupuser" ] || [ "${currentUser}" == "wtmp" ] || [ -z "${currentUser}" ]; then
		/bin/echo "No user is logged in... exiting..."
		exit 0
	fi

	if [[ "${LaunchInstallerOnly}" = "1" ]]; then
		# shellcheck disable=SC2009  # matching on full ps arg line by design; pgrep pattern differs
		if ps aux | grep "Install macOS" | grep -v "grep"; then
			/bin/echo "Installer already open"
			exit 0
		fi
	fi

	title="macOS ${targetOsVersion} Update"
	message="Your Mac is pending the install of a critical macOS update. This update has been approved by ${orgAndDeptName}.\n\nThis update will take approximately 60 minutes to install.\n\nYou may defer this update for ${deferralWindow} hour(s) or update now.\n\nPlease ensure your Mac is connected to a power source."
	welcomeInput=$(/usr/bin/osascript<<END
	with timeout of ${osatimeout} seconds
set the answer to button returned of (display dialog "${message}" with icon file "${iconFile}" with title "${title}" buttons {"Defer ${deferralWindow} hour(s)", "Update Now"} default button 2 giving up after ${osagiveup})
	end timeout
END
)

	if [ "${welcomeInput}" = "Defer ${deferralWindow} hour(s)" ]; then
		/bin/echo "User chose to defer"
		fDefer
	elif [ "${welcomeInput}" = "Update Now" ]; then
		fPowerCheck
	else
		/bin/echo "Window timed out... will try again later..."
		exit 0
	fi
}

fDownloadInstaller ()
{
	# Acquire/validate the installer, then hand off to the user prompt.
	try="0"

	until [ "${try}" -ge 5 ]
	do
		installerApp=$(fFindInstaller) || installerApp=""

		if [ -z "${installerApp}" ]; then
			/bin/echo "No installer present. Acquiring (attempt ${try})..."
			# Preferred URL-free path first, then optional pinned pkg fallback.
			fFetchFullInstaller || fInitManualSusDownload || true
			try=$((try+1))
			/bin/sleep 2
		elif ! fInstallerVersionOK "${installerApp}"; then
			/bin/echo "Invalid installer version found... deleting...."
			/bin/rm -rf "${installerApp}"
			try=$((try+1))
		else
			/bin/echo "Correct installer is present: ${installerApp}"
			break
		fi
	done

	installerApp=$(fFindInstaller) || installerApp=""
	if [ -z "${installerApp}" ]; then
		/bin/echo "Installer could not be acquired..."
		exit 1
	fi
	fWelcomeB
}

fInstallPrompt ()
{
	title="macOS ${targetOsVersion} Update - Install In Progress"
	message="The update is now installing... Please do not use the computer...\n\nIt may take up to 35 minutes before the computer restarts."
	/usr/bin/osascript<<END &
	with timeout of 10800 seconds
	display dialog "${message}" with icon file "${iconFile}" with title "${title}" buttons {"Close"} default button 1
	end timeout
END
}

fErrorOut ()
{
	/usr/bin/killall caffeinate 2>/dev/null
	/usr/bin/killall osascript 2>/dev/null

	title="macOS ${targetOsVersion} Update - Install Failed"
	message="The update failed to install.\n\nPlease contact ${orgAndDeptName}"
	/usr/bin/osascript<<END &
	display dialog "${message}" with icon file "${iconFile}" with title "${title}" buttons {"Close"} default button 1
END
	exit 6
}

fInstall ()
{
	installerApp=$(fFindInstaller) || installerApp=""
	if [ -z "${installerApp}" ]; then
		/bin/echo "Installer disappeared before install could start..."
		exit 1
	fi
	startOsInstall="${installerApp}/Contents/Resources/startosinstall"

	if [[ "${LaunchInstallerOnly}" = "1" ]]; then
		/bin/echo "Configured to only launch the installer... opening now..."
		/usr/bin/sudo -u "${currentUser}" /usr/bin/open -a "${installerApp}" &
		exit 0
	fi

	/usr/bin/caffeinate -disu &

	if [[ "${processorBrand}" = *"Apple"* ]]; then
		/bin/echo "Apple Processor is present..."
		fRunASInstall
	else
		/bin/echo "Apple Processor is not present..."
		fInstallPrompt &
		fRunIntelInstall
	fi
}

fRunIntelInstall ()
{
	TriggerInstall=$("${startOsInstall}" --agreetolicense --forcequitapps)

	cmdStat=$?

	/bin/echo "${TriggerInstall}"
	/bin/echo "${cmdStat}"

	if [ "${cmdStat}" != "0" ]; then
		/bin/echo "Unexpected Error Occurred... Failing and notifying user..."
		fErrorOut
	else
		exit 0
	fi
}

fGetPassword()
{
	/bin/echo "Password Attempt number ${passwordTry}"
	until [ "${passwordTry}" -ge 5 ]
	do

	title="macOS ${targetOsVersion} Update - Authentication Required"
	message="Please enter your macOS login password."
	passwordInput=$(/usr/bin/osascript<<END
	with timeout of ${osatimeout} seconds
	display dialog "${message}\n\n${WARN}" with icon file "${iconFile}" buttons {"Defer ${deferralWindow} hour(s)", "Continue"} default answer "" with hidden answer default button 2 with title "${title}" giving up after ${osagiveup}
	copy the result as list to {text_returned, button_pressed}
	end timeout
END
)

	password=$(/bin/echo "${passwordInput}" | /usr/bin/awk -F, '{ print $2 }' | /usr/bin/xargs /bin/echo -n)

	passwordinput_button=$(/bin/echo "${passwordInput}" | /usr/bin/awk -F, '{ print $1 }')

	if [ "${passwordinput_button}" = "Defer ${deferralWindow} hour(s)" ]; then
		/bin/echo "User chose to be defer 1 day... will try again...."
		fDefer
	elif [ "${passwordinput_button}" = "Continue" ]; then
		/bin/echo "User supplied a password..."
		passwordTry=$((passwordTry+1))
	else
		/usr/bin/killall caffeinate 2>/dev/null
		/bin/echo "Window timed out.. will try again later..."
		exit 0
	fi

		# Password is validated directly by startosinstall --stdinpass (no python/expect
		# pre-check needed). An auth failure returns us here to re-prompt.
		fTriggerASInstall

done
/bin/echo "Too many password attempts..."
/usr/bin/killall caffeinate 2>/dev/null
exit 3
}

# Starts the install on Apple Silicon devices
fRunASInstall ()
{
	secureTokenCheck=$(/usr/sbin/sysadminctl -secureTokenStatus "${currentUser}" 2>&1)

	if [[ "${secureTokenCheck}" = *"ENABLED"* ]]; then
		/bin/echo "${currentUser} is a ST user and can proceed..."
	else
		/bin/echo "${currentUser} is NOT A ST user and CANNOT authorize the update."
		exit 2
	fi

	fGetPassword
}

fTriggerASInstall ()
{
	fInstallPrompt &

	TriggerInstall=$(
	( /bin/cat <<EOF
${password}
EOF
	) | "${startOsInstall}" --agreetolicense --forcequitapps --user "${currentUser}" --stdinpass 2>&1)

	cmdStat=$?

	password=""

	/bin/echo "${TriggerInstall}"
	/bin/echo "${cmdStat}"

	if [[ "${TriggerInstall}" = *"Error: could not get authorization..."* ]]; then
		/bin/echo "Password incorrect or another issue, unable to get auth..prompting for password attempt"
		WARN="Incorrect Password or other failure... if repeated issues please contact ${orgAndDeptName}\n\nPassword Attempt: ${passwordTry}"
		fGetPassword
	elif [ "${cmdStat}" != "0" ]; then
		echo "Unexpected Error Occurred... Failing and notifying user..."
		fErrorOut
	fi
}

fDownloadInstaller
