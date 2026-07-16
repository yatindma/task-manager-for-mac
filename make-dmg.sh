#!/bin/bash
# Packages Task Manager.app into a distributable DMG with an /Applications shortcut.
# Run build.sh first, or pass --build to do both.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Task Manager.app"
DMG="$ROOT/TaskManager.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ "${1:-}" = "--build" ]; then
    "$ROOT/build.sh" release
fi

if [ ! -d "$APP" ]; then
    echo "error: $APP not found. Run ./build.sh first." >&2
    exit 1
fi

# The window the user sees on mount: the app on the left, Applications on the right,
# so the install is one drag.
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "Task Manager" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "Built: $DMG ($SIZE)"
echo
echo "NOTE: this DMG is ad-hoc signed, not notarized — shipping a notarized build"
echo "needs a paid Apple Developer ID. On first launch macOS will show"
echo "\"Apple could not verify...\"; the user opens it via right-click > Open, or"
echo "System Settings > Privacy & Security > Open Anyway. The README must say so."
