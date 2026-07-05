#!/bin/zsh

###################################################################################################
#
#   Created - 2020-08-14
#   Updated - 2020-08-18
#   Updated - 2022-04-26
#
###################################################################################################
# Tested macOS Versions
###################################################################################################
#
#   - 12.3.1
#   - 11.6.5
#
###################################################################################################
# Software Information
###################################################################################################
#
#   This script is designed determine if the device hardware supports a firmware password and if
#   so remove the firmware password and force a restart.
#
###################################################################################################
# License Information
###################################################################################################
# Provided under the MIT License.
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
###################################################################################################

###################################################################################################
###################################### VARIABLES ##################################################
###################################################################################################

# Current firmware password, supplied via the environment so it is never committed to source.
# Fails loudly if unset.
: "${FIRMWARE_PASSWORD:?set FIRMWARE_PASSWORD to the current firmware password}"

# Specify the number of seconds before the end user will be forced to restart (This interaction
# occurs via the MDM menu bar app similar to other forced restarts)
REBOOT_DELAY_SECONDS="1800"

###################################################################################################
########################### MAIN LOGIC - DO NOT MODIFY ############################################
###################################################################################################

# Determine the processor brand
processor_brand=$(/usr/sbin/sysctl -n machdep.cpu.brand_string)

# How to find manufacturer information - https://evasions.checkpoint.com/techniques/macos.html
manufacturer=$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice |
    /usr/bin/awk -F\" '/manufacturer/{print $(NF-1)}')

if [[ "$processor_brand" == *"Apple"* ]]; then
    echo "Apple Silicon Mac detected ..."
    echo "Firmware password is not compatible ..."
    exit 0

# Check to see if macOS is running on a virtual device
elif [[ "$manufacturer" != *"Apple"* ]]; then
    echo "Virtual device detected ..."
    echo "Firmware password is not compatible ..."
    exit 0

else
    echo "Intel-based Mac hardware detected ..."
fi

firmware_password_status=$(/usr/sbin/firmwarepasswd -check | /usr/bin/awk '{print $NF}')

if [ "${firmware_password_status}" = "No" ]; then
    echo "Firmware password is already disabled..."
    exit 0
fi

# this is to get the password ready for the expect block below
# will prepend a \ to all specials omitting \ if it exists in the original password
escaped_firmware_passwd=$(echo ${FIRMWARE_PASSWORD} | /usr/bin/sed -e 's/\([^[:alnum:]]\)/\\\1/g')

echo "Password formatted successfully."

remove_command=$(
                /usr/bin/expect <<EOF
spawn /usr/sbin/firmwarepasswd -delete
expect {
	"Enter password:" {
		send "${escaped_firmware_passwd}\r"
		exp_continue
	}
}
EOF
)

if [[ "${remove_command}" = *"Must restart before changes will take effect"* ]]; then
    echo "Firmware Password Removed... changes will take affect after reboot"
    # MDM-agent delayed-reboot command. Set MDM_REBOOT_CMD to your MDM's reboot binary (e.g. /usr/local/bin/<mdm-agent>).
    : "${MDM_REBOOT_CMD:?set MDM_REBOOT_CMD to the MDM agent reboot binary}"
    "${MDM_REBOOT_CMD}" reboot --delaySeconds ${REBOOT_DELAY_SECONDS}
    exit 0
else
    echo "Firmware password was not removed... an unknown error occured"
    exit 1
fi
