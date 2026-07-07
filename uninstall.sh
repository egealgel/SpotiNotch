#!/bin/bash
#
# Quits SpotiNotch and removes the app.
#
set -euo pipefail

APP_NAME="SpotiNotch"
APP_DIR="/Applications/$APP_NAME.app"

echo "==> Quitting app…"
pkill -f "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> Removing app…"
rm -rf "$APP_DIR"

echo "Done. SpotiNotch uninstalled."
echo "Remove its Login Items entry (if shown) in System Settings › General › Login Items."
