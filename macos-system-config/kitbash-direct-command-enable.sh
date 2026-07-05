#!/bin/bash

#Direct Command variation, enable silicon worklet

# MDM agent binary used to create the service account and pass the SecureToken.
# Genericized from a vendor-specific agent; override via environment if needed.
MDM_AGENT="${MDM_AGENT:-/usr/local/bin/mdm-agent}"

# Name of the MDM-managed service account that must hold the SecureToken.
# Defaults to the value present on the managed fleet; override via environment.
MDM_SERVICE_ACCOUNT="${MDM_SERVICE_ACCOUNT:-_mdmserviceaccount}"

# Service account credentials must be supplied by the environment (never hardcode).
: "${ADMINUSERNAME:?set ADMINUSERNAME}"
: "${ADMINPASSWORD:?set ADMINPASSWORD}"

# Function to run through a series of checks to make sure the SecureToken can be passed if needed.
function BeginChecks () {
# Check if Mac device is Apple Silicon or not.
AppleM1=$(uname -m)
if [[ "${AppleM1}" != "arm64" ]]; then
    echo "Device is not M1 so the Remediation code is not needed."
    exit 0
fi

# Check if SecureToken is already passed. If so, the script will not need to continue.
AXServiceAcountName="${MDM_SERVICE_ACCOUNT}"
AXServiceAccount=$(dscl . list /Users 2>&1 | grep -o "${AXServiceAcountName}")
AXSecureToken=$(sysadminctl -secureTokenStatus "${AXServiceAcountName}" 2>&1 | grep -o "ENABLED")
if [[ "${AXServiceAccount}" = "${AXServiceAcountName}" ]] && [[ "${AXSecureToken}" = "ENABLED" ]]; then
    echo "Both the service account and token exist, no action is needed."
    exit 0
fi

# Check if the MDM service account exists. If not, it will be created here.
if [[ "${AXServiceAccount}" != "${AXServiceAcountName}" ]]; then
    sudo "${MDM_AGENT}" --service-account enable
    sleep 2
fi

# Check if logged-in user is root. This can happen if the device is on the login screen.
CurrentUser=$(stat -f %Su /dev/console)
if [[ "${CurrentUser}" == "root" ]]; then
    echo "User root is logged in, stopping script" >&2
    exit 1
fi
}


# Function to pass SecureToken.
function PassSecureToken() {
echo "Direct Enable invocation with ${ADMINUSERNAME}"
sudo "${MDM_AGENT}" --adminuser "${ADMINUSERNAME}" --adminpass "${ADMINPASSWORD}"
}


# Function to check if SecureToken was passed.
function CheckSecureToken() {
AXSecureToken=$(sysadminctl -secureTokenStatus "${MDM_SERVICE_ACCOUNT}" 2>&1 | grep -o "ENABLED")
if [[ "${AXSecureToken}" = "ENABLED" ]]; then
    echo "SUCCESS: The MDM service account has a secure token enabled. No further action is required."
    exit 0
else
    echo "ERROR: The MDM service account was created but was not granted a secure token. The user likely exited the prompt or entered the wrong password." >&2
    exit 1
fi
}

# Worklet trap in case the script fails.
# shellcheck disable=SC2154  # rc and axPromptPID are assigned inside this trap body
trap '
    rc=$?
    if [ $rc -eq 1 ]; then
        echo "An error has encountered. Worklet cleaning up and stopping Secure Token prompt." >&2
        axPromptPID=$(pgrep -f "osascript")
        if [ -n "$axPromptPID" ]; then
            kill -9 "$axPromptPID" &> /dev/null
        fi
    fi
' EXIT

#================================================================
# START OF SCRIPT
#================================================================

BeginChecks
PassSecureToken
CheckSecureToken
