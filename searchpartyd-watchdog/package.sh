#!/bin/bash
# Packages the app as a single .dmg you can hand to someone: they open it and
# drag one icon into Applications, like any other Mac app.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SearchParty Watchdog"
DIST="$PWD/dist"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Build a fresh copy into the staging area rather than packaging whatever
# happens to be installed.
echo "Building a clean copy…"
INSTALL_DIR="${STAGE}/built" ./build.sh > /dev/null
APP="${STAGE}/built/${APP_NAME}.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"

ROOT="${STAGE}/dmg"
mkdir -p "$ROOT"
ditto "$APP" "${ROOT}/${APP_NAME}.app"
ln -s /Applications "${ROOT}/Applications"

# macOS will refuse the first launch, because the app is signed ad-hoc rather
# than with a paid Developer ID, so say up front how to get past it.
cat > "${ROOT}/Read Me First.txt" <<TXT
${APP_NAME} ${VERSION}

Watches the Find My daemon (searchpartyd) from the menu bar and kills it when it
runs away with your CPU or memory. No dock icon, no window.

INSTALL
  Drag ${APP_NAME} onto the Applications folder in this window.

FIRST LAUNCH
  macOS will block it the first time, with a message about not being able to
  check it for malware. That is because this app is not signed with a paid Apple
  Developer ID, not because anything is wrong with it. To allow it:

    1. Double-click the app. Dismiss the warning.
    2. Open System Settings > Privacy & Security.
    3. Scroll to Security. Next to "${APP_NAME}" was blocked, click Open Anyway.
    4. Confirm. It launches, and never asks again.

  It runs in the menu bar only - look for the radar icon in the top right.

WHAT IT CAN DO TO YOUR SYSTEM
  Nothing, until you ask. The killswitch needs an admin password each time,
  unless you turn on "Kill Without Password" in the menu, which adds one line to
  /etc/sudoers.d permitting exactly one command:

    /usr/bin/pkill -9 -xf /usr/libexec/searchpartyd

  No wildcards - that rule cannot be used against any other process. The app
  shows you the exact rule before it installs anything, and unticking the menu
  item removes it.

  Killing searchpartyd is safe: launchd restarts it within seconds, which is the
  whole point - it comes back with a normal memory footprint.

Public domain. No warranty.
TXT

# Give the mounted volume the app's own icon instead of the generic disk.
cp "${APP}/Contents/Resources/AppIcon.icns" "${ROOT}/.VolumeIcon.icns"
SetFile -a C "$ROOT" 2>/dev/null || true

mkdir -p "$DIST"
DMG="${DIST}/${APP_NAME} ${VERSION}.dmg"
rm -f "$DMG"

hdiutil create -volname "$APP_NAME" -srcfolder "$ROOT" \
    -ov -format UDZO -quiet "$DMG"

echo
echo "Ready to share:  ${DMG}"
echo "                 $(du -h "$DMG" | cut -f1)"
