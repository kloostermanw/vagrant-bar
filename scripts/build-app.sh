#!/bin/bash
# Build VagrantBar with SwiftPM and wrap the binary into VagrantBar.app
# (menu-bar only, ad-hoc signed). The version comes from the VERSION file.
# Usage: scripts/build-app.sh [debug|release]   (defaults to release)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="VagrantBar"
CONFIGURATION="${1:-release}"
APP="$APP_NAME.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Building $APP_NAME $VERSION ($CONFIGURATION)"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_PATH/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>dev.local.vagrantbar</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>VagrantBar opens Terminal to run vagrant ssh.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad hoc)"
codesign --force -s - "$APP"
echo "==> Done: $(pwd)/$APP"
