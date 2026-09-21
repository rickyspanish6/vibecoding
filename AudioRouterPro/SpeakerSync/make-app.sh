#!/bin/zsh
# Builds SpeakerSync.app — a proper menu bar app bundle (LSUIElement) — from
# the Swift package. Output lands in ./dist/SpeakerSync.app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=dist/SpeakerSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/SpeakerSync "$APP/Contents/MacOS/SpeakerSync"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SpeakerSync</string>
    <key>CFBundleIdentifier</key>
    <string>ca.umamy.speakersync</string>
    <key>CFBundleName</key>
    <string>SpeakerSync</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string></string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
