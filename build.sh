#!/bin/bash
# Builds Kalina Print Studio and installs it to ~/Applications/Kalina Print Studio.app
# The build folder lives outside Dropbox so Dropbox does not sync thousands of build files.
set -euo pipefail
cd "$(dirname "$0")"

SCRATCH="$HOME/Library/Caches/P900Print-build"
APP="$HOME/Applications/Kalina Print Studio.app"
OLD_APP="$HOME/Applications/P900Print.app"

echo "Building (the first build compiles the color engine, give it a minute)..."
swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/P900Print"

mkdir -p "$HOME/Applications"
rm -rf "$APP" "$OLD_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/P900Print"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"

echo ""
echo "Installed: $APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
