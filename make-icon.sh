#!/bin/bash
#
# Regenerates Resources/AppIcon.icns from a single source PNG and reinstalls
# the app. The source should be a full-bleed 1024x1024 square (see README /
# explanation of the "small icon" / "background showing" problem).
#
# Usage: ./make-icon.sh /path/to/your-icon-1024x1024.png
#
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-}"
if [[ -z "$SRC" || ! -f "$SRC" ]]; then
    echo "Usage: $0 /path/to/icon-1024x1024.png" >&2
    echo "The source must be a 1024x1024 PNG." >&2
    exit 1
fi

# Verify it's square.
W="$(sips -g pixelWidth  "$SRC"  | awk '/pixelWidth/  {print $2}')"
H="$(sips -g pixelHeight "$SRC"  | awk '/pixelHeight/ {print $2}')"
echo "==> Source: ${W}x${H}"
if [[ "$W" != "$H" ]]; then
    echo "Error: source must be square (1024x1024), got ${W}x${H}." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# Generate every size macOS can ask for, so nothing is scaled up awkwardly.
while read -r px name; do
    sips -z "$px" "$px" -s format png "$SRC" --out "$ICONSET/$name" >/dev/null
done <<'EOF'
16  icon_16x16.png
32  icon_16x16@2x.png
32  icon_32x32.png
64  icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
EOF

echo "==> Building AppIcon.icns…"
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

echo "==> Reinstalling app…"
./install.sh

echo ""
echo "Done. New icon is live."
