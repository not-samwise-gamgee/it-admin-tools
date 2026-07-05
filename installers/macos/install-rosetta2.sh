#!/bin/bash

# Determine the processor brand
processorBrand=$(/usr/sbin/sysctl -n machdep.cpu.brand_string)

if [[ "${processorBrand}" = *"Apple"* ]]; then
    echo "Apple Processor is present..."
else
    echo "Apple Processor is not present... rosetta not needed"
    exit 0
fi

# Rosetta Status
checkRosettaStatus=$(/bin/launchctl list | /usr/bin/grep "com.apple.oahd-root-helper")

# Rosetta Folder location
# Condition to check to see if the Rosetta folder exists. This check was added because the
# Rosetta2 service is already running in macOS versions 11.5 and greater without Rosseta2 actually
# being instaslled.
RosettaFolder="/Library/Apple/usr/share/rosetta"

if [[ -e "${RosettaFolder}" && "${checkRosettaStatus}" != "" ]]; then
    echo "Rosetta Folder exists and Rosetta Service is running... exiting"
    exit 0
else
    echo "Rosetta Folder does not exist or Rosetta service is not running... installing Rosetta"
fi

# Installs Rosetta and checks the outcome of the install
if /usr/sbin/softwareupdate --install-rosetta --agree-to-license; then
    echo "Rosetta installed... exiting"
    exit 0
else
    echo "Rosetta install failed..."
    exit 1
fi
