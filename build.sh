#!/bin/bash
# Assembles Task Manager.app from the SwiftPM executables.
# Xcode is not required — only the Command Line Tools.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Task Manager.app"

# SwiftUI's @State/@Binding are macros, and their plugin (libSwiftUIMacros.dylib) ships
# only inside Xcode — a Command Line Tools toolchain fails with "plugin for module
# 'SwiftUIMacros' not found". Point at Xcode without needing `sudo xcode-select -s`.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TaskManager" "$APP/Contents/MacOS/TaskManager"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Icon.icns" "$APP/Contents/Resources/Icon.icns"

# Shipped unprivileged. The app installs it setuid-root on demand, behind one
# authorisation prompt — see PrivilegedHelper.install().
cp "$BIN/tmhelper" "$APP/Contents/Resources/tmhelper"

# Ad-hoc signing so the Apple Events prompt (Startup apps tab) has a stable identity
# to attach the TCC grant to. Without it macOS re-prompts on every launch.
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
echo "Run:   open '$APP'"
