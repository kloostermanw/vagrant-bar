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
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_OUT" >/dev/null

echo "==> Done: $(pwd)/$DMG_OUT"
