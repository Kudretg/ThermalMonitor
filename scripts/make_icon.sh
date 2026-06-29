#!/bin/bash
set -e

SRC="$1"
DEST="$2"   # path to write AppIcon.icns

if [[ -z "$SRC" || -z "$DEST" ]]; then
    echo "Usage: make_icon.sh <source.png> <output.icns>"
    exit 1
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "→ Generating icon sizes from $SRC..."

sips -z 16   16   "$SRC" --out "$ICONSET/icon_16x16.png"       -s format png >/dev/null
sips -z 32   32   "$SRC" --out "$ICONSET/icon_16x16@2x.png"    -s format png >/dev/null
sips -z 32   32   "$SRC" --out "$ICONSET/icon_32x32.png"       -s format png >/dev/null
sips -z 64   64   "$SRC" --out "$ICONSET/icon_32x32@2x.png"    -s format png >/dev/null
sips -z 128  128  "$SRC" --out "$ICONSET/icon_128x128.png"     -s format png >/dev/null
sips -z 256  256  "$SRC" --out "$ICONSET/icon_128x128@2x.png"  -s format png >/dev/null
sips -z 256  256  "$SRC" --out "$ICONSET/icon_256x256.png"     -s format png >/dev/null
sips -z 512  512  "$SRC" --out "$ICONSET/icon_256x256@2x.png"  -s format png >/dev/null
sips -z 512  512  "$SRC" --out "$ICONSET/icon_512x512.png"     -s format png >/dev/null
sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png"  -s format png >/dev/null

echo "→ Converting iconset to ICNS..."
iconutil -c icns "$ICONSET" -o "$DEST"

rm -rf "$(dirname "$ICONSET")"
echo "✅ Icon written to $DEST"
