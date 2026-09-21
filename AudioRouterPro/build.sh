#!/bin/sh
# Build, ad-hoc sign, and launch AudioRouter Pro.
#
# Build products go outside ~/Documents on purpose: this folder is
# iCloud-synced, and the file provider stamps extended attributes onto a
# freshly built .app faster than codesign can sign it ("resource fork,
# Finder information, or similar detritus not allowed"). Xcode's GUI is
# unaffected because DerivedData already lives under ~/Library.
set -eu
cd "$(dirname "$0")"

BUILD_DIR="${BUILD_DIR:-$HOME/Library/Developer/AudioRouterPro-build}"
APP="$BUILD_DIR/sym/Release/AudioRouterPro.app"

# Sign with the persistent self-signed identity when present: ad-hoc
# signatures change every build, which resets the Local Network TCC grant
# (macOS treats each build as a new app). A stable identity keeps
# permissions across rebuilds.
IDENTITY="AudioRouterPro Dev"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    IDENTITY="-"
    echo "warning: '$IDENTITY' signing identity not found — ad-hoc signing (Local Network permission will reset)"
fi

xcodebuild -project AudioRouterPro.xcodeproj \
    -target AudioRouterPro \
    -configuration Release \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    SYMROOT="$BUILD_DIR/sym" \
    OBJROOT="$BUILD_DIR/obj" \
    build

# Install a clickable copy in /Applications, then relaunch it (quit any
# running copy first so the old one doesn't hold the tap).
INSTALL="/Applications/AudioRouterPro.app"
pkill -x AudioRouterPro 2>/dev/null && sleep 1 || true
rm -rf "$INSTALL"
ditto "$APP" "$INSTALL"
open "$INSTALL"
echo "Installed and launched $INSTALL"
