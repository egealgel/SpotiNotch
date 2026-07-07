#!/bin/bash
#
# Builds a distributable SpotiNotch.dmg (app + /Applications shortcut).
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SpotiNotch"
BUNDLE_ID="com.spotinotch.app"
DMG="$APP_NAME.dmg"

echo "==> Building release binary…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
APP_DIR="$STAGING/$APP_NAME.app"

echo "==> Assembling app bundle…"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"

echo "==> Building DMG…"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo ""
echo "Done: $(pwd)/$DMG"
echo "Open it, drag SpotiNotch into Applications, then launch it once."
