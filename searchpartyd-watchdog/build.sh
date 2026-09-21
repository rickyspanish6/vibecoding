#!/bin/bash
# Builds SearchParty Watchdog.app. Requires only the Xcode Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SearchParty Watchdog"
VERSION="1.1"
BUILD="$(date +%Y%m%d)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
DEST="${INSTALL_DIR}/${APP_NAME}.app"

# Stage outside the project: this repo may sit in an iCloud-synced folder, and the
# file provider stamps com.apple.FinderInfo on the bundle, which codesign rejects.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="${STAGE}/${APP_NAME}.app"

mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

cat > "${BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>      <string>SearchPartyWatchdog</string>
    <key>CFBundleIdentifier</key>      <string>com.local.searchpartyd-watchdog</string>
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>NSHumanReadableCopyright</key><string>Public domain. No warranty.</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "Compiling…"
swiftc -O -target "$(uname -m)-apple-macos13.0" \
    -o "${BUNDLE}/Contents/MacOS/SearchPartyWatchdog" \
    Sources/*.swift

echo "Building icon…"
ICONSET="${STAGE}/AppIcon.iconset"
mkdir -p "$ICONSET"
swiftc -O -target "$(uname -m)-apple-macos13.0" -o "${STAGE}/make-icon" Tools/make-icon.swift
"${STAGE}/make-icon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "${BUNDLE}/Contents/Resources/AppIcon.icns"

# Shipped inside the bundle so the Read Me window works from the installed copy,
# with no dependency on wherever this repo happens to live.
cp README.md "${BUNDLE}/Contents/Resources/README.md"

xattr -cr "$BUNDLE"
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE"

mkdir -p "$INSTALL_DIR"
WAS_RUNNING=0
if pgrep -f "${DEST}/Contents/MacOS/SearchPartyWatchdog" > /dev/null 2>&1; then
    WAS_RUNNING=1
fi
if [ -d "$DEST" ]; then
    # Quit the running copy so the replacement takes effect. Match the full
    # destination path, so packaging into a temp dir can't kill the installed app.
    pkill -f "${DEST}/Contents/MacOS/SearchPartyWatchdog" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
fi
ditto "$BUNDLE" "$DEST"

# Put it back in the menu bar if it was there before, so a rebuild isn't a
# silent uninstall.
if [ "$WAS_RUNNING" = "1" ]; then
    open -a "$DEST"
    echo "Installed and relaunched ${DEST}"
else
    echo "Installed ${DEST}"
fi
