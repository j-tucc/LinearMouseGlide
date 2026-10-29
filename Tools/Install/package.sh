#!/bin/bash -e
# Builds a Release LinearMouse Glide for this Mac's architecture and zips it
# with install.sh and this Mac's Glide config:
#
#   Tools/Install/package.sh    -> build/LinearMouseGlide-Install.zip

cd "$(dirname "$0")/../.."
OUT=build/LinearMouseGlide-Install
APP=build/DerivedData/Build/Products/Release/LinearMouse.app

# The production bundle identifier and icon, as Scripts/configure-release
# sets them, without leaving Release.xcconfig behind for Debug builds.
printf 'PRODUCT_BUNDLE_IDENTIFIER = app.linearmouseglide.LinearMouseGlide\nASSETCATALOG_COMPILER_APPICON_NAME = AppIcon\n' > Release.xcconfig
trap 'rm -f Release.xcconfig' EXIT
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcodebuild \
    -project LinearMouse.xcodeproj -scheme LinearMouse -configuration Release \
    -derivedDataPath build/DerivedData ONLY_ACTIVE_ARCH=YES build > build/release.log 2>&1 ||
    { tail -20 build/release.log; exit 1; }

rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT"
ditto "$APP" "$OUT/LinearMouse Glide.app"
cp Tools/Install/install.sh "$OUT/install.sh"
chmod +x "$OUT/install.sh"
if [[ -f ~/.config/linearmouseglide/linearmouse.json ]]; then
    cp ~/.config/linearmouseglide/linearmouse.json "$OUT/linearmouse.json"
fi
ditto -c -k --keepParent "$OUT" "$OUT.zip"
echo "$OUT.zip"
