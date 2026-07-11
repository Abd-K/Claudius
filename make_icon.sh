#!/bin/zsh
# Render the icon and package it as AppIcon.icns in the project dir.
set -euo pipefail
DIR="${0:A:h}"
WORK="$DIR/.iconbuild"
rm -rf "$WORK"; mkdir -p "$WORK"

swift "$DIR/make_icon.swift" "$WORK/icon_1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
gen() { sips -z "$1" "$1" "$WORK/icon_1024.png" --out "$ICONSET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$DIR/AppIcon.icns"
rm -rf "$WORK"
echo "wrote $DIR/AppIcon.icns"
