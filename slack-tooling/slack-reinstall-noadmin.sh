#!/bin/bash
# Removes and Updates Slack w Latest without prompt for Admin
# DMG Download URL
DownloadUrl="https://slack.com/ssb/download-osx"

#Kill Old Version
killall Slack

#Remove Old Version of Slack
sudo rm -rf /Applications/Slack.app/

# Locate DMG Download Link From URL

regex='^https.*.dmg$'
if [[ $DownloadUrl =~ $regex ]]; then
    echo "URL points to direct DMG download"
    # shellcheck disable=SC2034  # legacy flag retained; kept to preserve original behavior
    validLink="True"
else
    echo "Searching headers for download links"
    urlHead=$(curl -s --head "$DownloadUrl")

    locationSearch=$(echo "$urlHead" | grep https:)

    if [ -n "$locationSearch" ]; then

        locationRaw=$(echo "$locationSearch" | cut -d' ' -f2)

        locationFormatted="$(echo "${locationRaw}" | tr -d '[:space:]')"

        regex='^https.*'
        if [[ $locationFormatted =~ $regex ]]; then
            echo "Download link found"
            DownloadUrl="$locationFormatted"
        else
            echo "No https location download link found in headers"
            exit 1
        fi

    else

        echo "No location download link found in headers"
        exit 1
    fi

fi

#Create Temp Folder
DATE=$(date '+%Y-%m-%d-%H-%M-%S')

TempFolder="Download-$DATE"

mkdir "/tmp/$TempFolder"

# Navigate to Temp Folder
cd "/tmp/$TempFolder" || exit 1

# Download File into Temp Folder
curl -s -O "$DownloadUrl"

# Capture name of Download File
DownloadFile="$(ls)"

echo "Downloaded $DownloadFile to /tmp/$TempFolder"

# Verifies DMG File
regex='\.dmg$'
if [[ $DownloadFile =~ $regex ]]; then
    DMGFile="$DownloadFile"
    echo "DMG File Found: $DMGFile"
else
    echo "File: $DownloadFile is not a DMG"
    rm -r "/tmp/$TempFolder"
    echo "Deleted /tmp/$TempFolder"
    exit 1
fi

# Mount DMG File -nobrowse prevents the volume from popping up in Finder

hdiutilAttach=$(hdiutil attach "/tmp/$TempFolder/$DMGFile" -nobrowse)
err=$?

echo "Used hdiutil to mount $DMGFile "

if [ "${err}" -ne 0 ]; then
    echo "Could not mount $DMGFile Error: ${err}"
    rm -r "/tmp/$TempFolder"
    echo "Deleted /tmp/$TempFolder"
    exit 1
fi

regex='\/Volumes\/.*'
if [[ $hdiutilAttach =~ $regex ]]; then
    DMGVolume="${BASH_REMATCH[*]}"
    echo "Located DMG Volume: $DMGVolume"
else
    echo "DMG Volume not found"
    rm -r "/tmp/$TempFolder"
    echo "Deleted /tmp/$TempFolder"
    exit 1
fi

# Identify the mount point for the DMG file
DMGMountPoint="$(hdiutil info | grep "$DMGVolume" | awk '{ print $1 }')"

echo "Located DMG Mount Point: $DMGMountPoint"

# Capture name of App file

cd "$DMGVolume" || exit 1

# shellcheck disable=SC2010  # substring match on mounted DMG contents; behavior preserved from original
AppName="$(ls | grep .app)"

cd ~ || exit 1

echo "Located App: $AppName"

# Test to ensure App is not already installed

ExistingSearch=$(find "/Applications/" -name "$AppName" -depth 1)

if [ -n "$ExistingSearch" ]; then

    echo "$AppName already present in /Applications folder"
    hdiutil detach "$DMGMountPoint"
    echo "Used hdiutil to detach $DMGFile from $DMGMountPoint"
    rm -r "/tmp/$TempFolder"
    echo "Deleted /tmp/$TempFolder"
    exit 1

else

    echo "$AppName not present in /Applications folder"
fi

DMGAppPath=$(find "$DMGVolume" -name "*.app" -depth 1)

# Copy the contents of the DMG file to /Applications/
# Preserves all file attributes and ACLs
cp -pPR "$DMGAppPath" /Applications/
err=$?

if [ "${err}" -ne 0 ]; then
    echo "Could not copy $DMGAppPath Error: ${err}"
    hdiutil detach "$DMGMountPoint"
    echo "Used hdiutil to detach $DMGFile from $DMGMountPoint"
    rm -r "/tmp/$TempFolder"
    echo "Deleted /tmp/$TempFolder"
    exit 1
fi

echo "Copied $DMGAppPath to /Applications"

#Open Slack
open -n ./Slack.app --args -AppCommandLineArg

# Unmount the DMG file
hdiutil detach "$DMGMountPoint"
err=$?

echo "Used hdiutil to detach $DMGFile from $DMGMountPoint"

if [ "${err}" -ne 0 ]; then
    echo "Could not detach DMG: $DMGMountPoint Error: ${err}" >&2
    exit 1
fi

# Remove Temp Folder and download
rm -r "/tmp/$TempFolder"

echo "Deleted /tmp/$TempFolder"
