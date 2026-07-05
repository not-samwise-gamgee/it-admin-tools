#!/bin/bash

#Download large .pkg files over curl and run checksum

# Download URL
dlURL="DOWNLOAD_URL"

# SHA256 checksum of the ZIP file for verification Example: shasum -a 256 PATH/TO/FILE
fileChecksum="FILE_CHECKSUM"

################################################################################################

## Other Variables ##
finalURL=$(/usr/bin/curl "$dlURL" -s -L -I -o /dev/null -w '%{url_effective}')
fileName="${finalURL##*/}"
fileExt=$(echo "${fileName##*.}" | /usr/bin/awk '{print tolower($0)}')
tmpDir="/private/tmp/download"
pathToFile="$tmpDir/$fileName"
dlTries=1
vfTries=0
percent=0

## Create Functions ##
successTest() {
	# Test if last run command was successful
	if [ $? -ne 0 ]; then
    echo "$1"
    killall caffeinate
		exit 1
	fi
}

downloadFile() {
  /usr/bin/curl -Ls "$finalURL" -o "$pathToFile"
  while ! /usr/bin/curl -Ls "$finalURL" -o "$pathToFile"; do
    echo "Download Failed, retrying.  This is attempt $dlTries"
    sleep 5
    (( dlTries++ ))
    if [ "$dlTries" == 11 ]; then
      echo "Download has failed 10 times, exiting"
      killall caffeinate
      exit 1
    fi
  done
}

getDownloadSize() {
	/usr/bin/curl -sI "$finalURL" | /usr/bin/grep -i Content-Length | /usr/bin/awk '{print $2}' | /usr/bin/tr -d '\r'
}

dlPercent() {
	fSize=$(/bin/ls -nl "$pathToFile" | /usr/bin/awk '{print $5}')
	percent=$(echo "scale=2;($fSize/$dlSize)*100" | bc)
	percent=${percent%.*}
}

processZIP() {
  echo "Unzipping $pathToFile..."
	/usr/bin/unzip -oqd "$tmpDir" "$pathToFile"
	successTest "Unzip failed. Exiting..."
  pkgName=$(/usr/bin/find "$tmpDir" -maxdepth 1 -iname '*.pkg')
  successTest "No PKG file found in $tmpDir. Exiting..."
  rm -rf "$pathToFile"
  echo "PKG to install: $pkgName"
}

installPKG() {
  processZIP
  echo "PKG to install: $pkgName"
  /usr/sbin/installer -pkg "$pkgName" -target /
  successTest "Something went wrong during install..."
  echo "Install completed successfully..."
}

## Execute ##

# Check that the file to download is a ZIP
if [[ "$fileExt" != "zip" ]]; then
  echo "A ZIP file was not detected. Please check the download URL and try again..."
  exit 1
fi

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
  echo "Attempting to download and verify $fileName..."
  (( vfTries++ ))
  if [ $vfTries == 4 ]; then
  echo "Download and Verification has failed 3 times, exiting..."
  killall caffeinate
  exit 1
  fi
  downloadFile &
  pid=$!
  # If this script is killed, kill the download.
  trap 'kill $pid 2> /dev/null' EXIT
  # Track download progress
  while kill -0 $pid 2> /dev/null; do
    if [ -f "$pathToFile" ]; then
      dlPercent
      echo "Download at $percent%"
      sleep 10
    fi
  done 
  # Disable the trap on a normal exit.
  trap - EXIT
  echo "Download complete. Verifying file..."
  dlSUM=$(/usr/bin/shasum -a 256 "$pathToFile" | /usr/bin/cut -d ' ' -f1)
done

# Perform Installation
installPKG

# Cleanup
echo "Cleaning up files and processes..."
killall caffeinate
sleep 10
/bin/rm -R "$tmpDir"

exit 0
