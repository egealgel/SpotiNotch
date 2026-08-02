#!/bin/bash
#
# Builds SpotiNotch from source and installs it to /Applications.
# (Most users can just use the DMG.) The app registers itself to launch at login.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DynamicNotch"
BUNDLE_ID="com.dynamicnotch.app"
APP_DIR="/Applications/$APP_NAME.app"

echo "==> Building release binary…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP_DIR"
pkill -f "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 1
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Code signing (stable ad-hoc identity)…"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"

echo "==> Launching…"
open "$APP_DIR"

echo ""
echo "Done. $APP_NAME now hangs from your notch. Hover it to expand."
echo "It registered itself to open at login. First time it controls your music"
echo "app (Spotify or Apple Music), allow the Automation prompt."
echo ""
echo "To uninstall:  ./uninstall.sh"
