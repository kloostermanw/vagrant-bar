#!/usr/bin/env bash
#
# build-and-start.sh
#
# Stops VagrantBar if it is running, builds the app from the current
# checkout, then launches it. Handy for testing local changes.
#
# Usage: scripts/build-and-start.sh [configuration]
#   configuration defaults to debug (pass release to build the release config).

set -euo pipefail

APP_NAME="VagrantBar"
CONFIGURATION="${1:-debug}"
CONFIGURATION="$(echo "$CONFIGURATION" | tr '[:upper:]' '[:lower:]')"

# Run from the repository root regardless of where the script is invoked.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# 1. Stop the app if it is currently running.
if pgrep -x "${APP_NAME}" >/dev/null; then
  echo "Stopping running ${APP_NAME}..."
  osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
  # Wait up to ~5s for a graceful quit, then force kill if still alive.
  for _ in $(seq 1 10); do
    pgrep -x "${APP_NAME}" >/dev/null || break
    sleep 0.5
  done
  if pgrep -x "${APP_NAME}" >/dev/null; then
    echo "Force killing ${APP_NAME}..."
    killall "${APP_NAME}" 2>/dev/null || true
  fi
fi

# 2. Build and bundle.
scripts/build-app.sh "${CONFIGURATION}"

# 3. Launch.
echo "Starting ${REPO_ROOT}/${APP_NAME}.app..."
open "${APP_NAME}.app"
