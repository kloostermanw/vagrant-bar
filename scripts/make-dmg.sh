#!/bin/bash
# Build a release VagrantBar.app and package it into a drag-to-Applications .dmg.
# Usage: scripts/make-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="VagrantBar"
APP_PATH="$APP_NAME.app"
DMG_OUT="$APP_NAME.dmg"

echo "==> Running tests"
swift test >/dev/null

scripts/build-app.sh release >/dev/null
[ -d "$APP_PATH" ] || { echo "build failed: $APP_PATH missing" >&2; exit 1; }

# Ad hoc is enough, but an unsigned bundle is treated as damaged by Gatekeeper
# on Apple Silicon, so refuse to ship one.
echo "==> Checking the signature"
codesign --verify --deep --strict "$APP_PATH" \
  || { echo "refusing to package an unsigned app: check scripts/build-app.sh" >&2; exit 1; }

echo "==> Staging disk-image contents"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-target for the user

echo "==> Creating $DMG_OUT"
rm -f "$DMG_OUT"
# `hdiutil create -volname -format` is deprecated in favour of `diskutil image`,
# which only exists on recent macOS; fall back to hdiutil on older systems.
if diskutil image create from --help >/dev/null 2>&1; then
  # diskutil writes progress to stderr; only show its output if it fails.
  out="$(diskutil image create from \
    --format UDZO \
    --volumeName "$APP_NAME" \
    "$STAGING" \
    "$DMG_OUT" 2>&1)" || { echo "$out" >&2; exit 1; }
else
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_OUT" >/dev/null
fi

echo "==> Done: $(pwd)/$DMG_OUT"
