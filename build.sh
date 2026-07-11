#!/bin/zsh
# Build Claudius.app into ~/Applications and ad-hoc sign it.
set -euo pipefail
SRC_DIR="${0:A:h}"
APP="/Applications/Claudius.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"
[ -f "$SRC_DIR/AppIcon.icns" ] && cp "$SRC_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/Claudius" \
    "$SRC_DIR/ClaudiusApp.swift" "$SRC_DIR/SessionsFeature.swift"
codesign --force --sign - "$APP"
# Register with Launch Services so Spotlight / Finder search can find it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
echo "Relaunch with: pkill -x Claudius; open $APP"
