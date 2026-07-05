#!/usr/bin/env bash

# Change the two variable lines below to make this script work.

# Make sure the path has NO '/' at the end, and the image has a '/' at the beginning.
# Both are overridable via the environment.
pathToImage="${pathToImage:-$HOME/Downloads}"
imageName="${imageName:-/Logo Stacked.png}"

# sips command with -z flag is used here to adjust the size, file name is then adjusted to use the proper naming convention for later conversion using the iconutil command.

# not every sips command here is necessary, you would only need the one for the size(s) you desire, the rest may be omitted.

mkdir -p "${pathToImage}/MyIcon.iconset"

sips -z 25 25 "${pathToImage}${imageName}" --out "${pathToImage}/MyIcon.iconset/icon_25x25@2x.png"
cp "${pathToImage}${imageName}" "${pathToImage}/MyIcon.iconset/icon_512x512@2x.png"
iconutil -c icns "${pathToImage}/MyIcon.iconset"
rm -R "${pathToImage}/MyIcon.iconset"
