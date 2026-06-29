#!/bin/bash
set -e

APP="ThermalMonitor"
VERSION="1.0"
VOL="Thermal Monitor"
DMG_FINAL="$HOME/Downloads/${APP}-${VERSION}.dmg"
DMG_TEMP="/tmp/${APP}-rw.dmg"
STAGING="/tmp/${APP}-staging"
BG_PNG="/tmp/${APP}-bg.png"

# ── 1. Create background image ───────────────────────────────────────────────
echo "→ Generating background image..."
python3 - "$BG_PNG" << 'PYEOF'
import struct, zlib, sys

OUT = sys.argv[1]
W, H = 600, 380

def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xffffffff
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)

# ── pixel buffer (flat list of [r,g,b]) ─────────────────────────────────────
pixels = []
for y in range(H):
    t = y / (H - 1)
    for x in range(W):
        # Slightly darker blue-grey gradient: top(195,197,208) → bottom(212,215,222)
        pixels.append([int(195 + t*17), int(197 + t*18), int(208 + t*14)])

# ── arrow ────────────────────────────────────────────────────────────────────
# Verified from Finder bounds query — position = icon CENTRE (logical pts):
#   App:          bounds {136,168,200,232}  centre=(168,200)  right=200
#   Applications: bounds {400,168,464,232}  centre=(432,200)  left=400
ARROW   = [72, 76, 100]   # dark slate — contrasts with light background
AY      = 200             # icon centre y (confirmed)
X_START = 244             # app icon right edge (200) + 44px margin
X_SHAFT = 342             # shaft end / arrowhead base
X_TIP   = 362             # arrowhead tip — 38px before Applications left (400)
THICK   = 6               # shaft height in pixels
HEAD_H  = 14              # arrowhead half-height at its base

def set_px(x, y, col):
    if 0 <= x < W and 0 <= y < H:
        pixels[y * W + x] = col

# Shaft
for dy in range(-(THICK // 2), THICK // 2 + 1):
    for px in range(X_START, X_SHAFT):
        set_px(px, AY + dy, ARROW)

# Arrowhead — filled triangle pointing right
head_len = X_TIP - X_SHAFT
for dx in range(head_len + 1):
    px   = X_TIP - dx
    span = int(HEAD_H * dx / head_len)
    for dy in range(-span, span + 1):
        set_px(px, AY + dy, ARROW)

# ── encode PNG ───────────────────────────────────────────────────────────────
rows = []
for y in range(H):
    row = bytearray([0])
    for x in range(W):
        row += bytes(pixels[y * W + x])
    rows.append(bytes(row))

raw = b''.join(rows)
png = (b'\x89PNG\r\n\x1a\n'
    + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
    + chunk(b'IDAT', zlib.compress(raw, 9))
    + chunk(b'IEND', b''))

with open(OUT, 'wb') as f:
    f.write(png)
print(f'  Background: {W}x{H}px ({len(png)//1024}KB)')
PYEOF

# ── 2. Stage files ────────────────────────────────────────────────────────────
echo "→ Staging files..."
rm -rf "$STAGING" && mkdir -p "$STAGING"
cp -r "build/${APP}.app" "$STAGING/${APP}.app"
ln -s /Applications "$STAGING/Applications"

# Hidden background folder
mkdir -p "$STAGING/.background"
cp "$BG_PNG" "$STAGING/.background/bg.png"

# ── 3. Create writable DMG ────────────────────────────────────────────────────
echo "→ Creating disk image..."
rm -f "$DMG_TEMP"
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOL" \
    -fs HFS+ \
    -fsargs "-c c=2,a=2,b=2" \
    -format UDRW \
    -size 40m \
    "$DMG_TEMP" >/dev/null

# ── 4. Mount ──────────────────────────────────────────────────────────────────
echo "→ Mounting..."
MOUNT_PATH=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TEMP" \
    | grep '/Volumes' | awk '{print substr($0, index($0,$3))}')
echo "  Mounted at: $MOUNT_PATH"

# Hide .background folder
SetFile -a V "${MOUNT_PATH}/.background" 2>/dev/null || \
    chflags hidden "${MOUNT_PATH}/.background" 2>/dev/null || true

# ── 5. Apply Finder layout via AppleScript ────────────────────────────────────
echo "→ Applying Finder layout..."
BG_ABS="${MOUNT_PATH}/.background/bg.png"
osascript - "$MOUNT_PATH" "$APP" "$BG_ABS" << 'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set appName  to item 2 of argv
    set bgPath   to item 3 of argv

    tell application "Finder"
        set theDisk to disk (POSIX file mountPath as alias)
        tell theDisk
            open

            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {300, 100, 900, 480}

            set opts to icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 128
            set text size of opts to 14
            set background picture of opts to POSIX file bgPath

            set position of item (appName & ".app") of container window to {168, 200}
            set position of item "Applications"      of container window to {432, 200}

            update without registering applications
            delay 5
            close
        end tell
    end tell
end run
APPLESCRIPT

sync

# ── 6. Finalise ───────────────────────────────────────────────────────────────
echo "→ Unmounting..."
hdiutil detach "$MOUNT_PATH" -quiet
sync

echo "→ Converting to compressed read-only DMG..."
rm -f "$DMG_FINAL"
hdiutil convert "$DMG_TEMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_FINAL" >/dev/null

echo "→ Cleaning up..."
rm -f "$DMG_TEMP" "$BG_PNG"
rm -rf "$STAGING"

echo "→ Setting DMG file icon..."
ICNS="$(pwd)/Resources/AppIcon.icns"
osascript - "$DMG_FINAL" "$ICNS" << 'APPLESCRIPT'
use framework "AppKit"
on run argv
    set dmgPath  to item 1 of argv
    set icnsPath to item 2 of argv
    set img to current application's NSImage's alloc()'s initWithContentsOfFile_(icnsPath)
    current application's NSWorkspace's sharedWorkspace()'s setIcon_forFile_options_(img, dmgPath, 0)
end run
APPLESCRIPT

SIZE=$(du -sh "$DMG_FINAL" | cut -f1)
echo ""
echo "✅ Done: $DMG_FINAL ($SIZE)"
