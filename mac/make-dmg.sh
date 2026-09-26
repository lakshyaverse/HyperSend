#!/usr/bin/env bash
# Packages a styled HyperSend.dmg: background image, Finder icon layout, and a
# correctly sized window — what the user sees on mount, not a bare folder.
#
#   ./make-dmg.sh            (expects build/HyperSend.app and dmg-bg.png)
#
# The staging volume must mount at /Volumes/HyperSend: Finder resolves the
# background-picture reference relative to the volume, and a custom mountpoint
# breaks that. Re-runs are safe: they detach and rebuild.

set -euo pipefail
cd "$(dirname "$0")"

APP="build/HyperSend.app"
BG="dmg-bg.png"
DMG="HyperSend.dmg"
VOL="HyperSend"
MOUNT="/Volumes/$VOL"

[[ -d "$APP" ]] || { echo "missing $APP — run ./build.sh first" >&2; exit 1; }
[[ -f "$BG" ]] || { echo "missing $BG — run: xcrun swift ../tools/make-dmg-bg.swift mac/dmg-bg.png" >&2; exit 1; }

# The window is 1280x800 pt; on a retina Mac the PNG would render at 2x and
# icons would sit off the shelf. Ship the image at exactly window size.
sips -z 800 1280 "$BG" --out "$BG" >/dev/null

STAGING=$(mktemp -d)
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$STAGING"' EXIT

echo "staging…"
hdiutil create -quiet -volname "$VOL" -size 64m -fs APFS -ov "$STAGING/$VOL.dmg"
hdiutil attach -quiet -mountpoint "$MOUNT" "$STAGING/$VOL.dmg"

cp -R "$APP" "$MOUNT/"
ln -s /Applications "$MOUNT/Applications"
mkdir "$MOUNT/.background"
cp "$BG" "$MOUNT/.background/bg.png"

echo "laying out the window…"
osascript >/dev/null <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {0, 0, 1280, 800}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 110
        set text size of viewOptions to 16
        set background picture of viewOptions to file ".background:bg.png"
        set position of item "HyperSend.app" of container window to {340, 300}
        set position of item "Applications" of container window to {830, 300}
        set position of item ".background" of container window to {1200, 700}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

sync
sleep 2
# Finder often keeps the volume busy right after update; force after a beat.
hdiutil detach "$MOUNT" >/dev/null 2>&1 || {
    sleep 3
    hdiutil detach -force "$MOUNT" >/dev/null 2>&1 || true
}

echo "compressing…"
rm -f "$DMG"
hdiutil convert -quiet -format UDZO -o "$DMG" "$STAGING/$VOL.dmg"

echo "packaged $DMG ($(du -h "$DMG" | cut -f1))"
