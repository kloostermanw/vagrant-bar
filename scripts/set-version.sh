#!/bin/bash
# Write the release version into the VERSION file (read by scripts/build-app.sh).
# Called by git-release as cmd1 (before the tag is created), so the version
# bump is baked into the tagged commit. git-release stages and commits
# VERSION afterwards.
# Usage: scripts/set-version.sh --release v1.2.3
set -euo pipefail

cd "$(dirname "$0")/.."

TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) TAG="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$TAG" ] || { echo "set-version: --release <tag> is required" >&2; exit 2; }

# Strip a leading v/V; the bundle version is a plain dotted number.
VERSION="${TAG#[vV]}"

case "$VERSION" in
  *[!0-9.]*|"") echo "set-version: '$TAG' is not a numeric version" >&2; exit 2 ;;
esac

echo "$VERSION" > VERSION

echo "set-version: VERSION -> ${VERSION}"
