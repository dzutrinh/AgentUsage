#!/bin/bash
# Builds a universal (Apple silicon + Intel) app and packs it into a
# drag-to-install disk image: dist/AgentUsage-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
VOLNAME="Agent Usage"
DMG="dist/AgentUsage-$VERSION.dmg"

ARCHS="arm64 x86_64" ./build.sh

TMP=$(mktemp -d)
MNT=""
cleanup() {
    [ -n "$MNT" ] && hdiutil detach "$MNT" -quiet -force 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# Contents: the app, an Applications shortcut, and a hidden background folder.
STAGE="$TMP/stage"
mkdir -p "$STAGE/.background"
cp -R build/AgentUsage.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swiftc -parse-as-library -O Design/DMGBackground.swift -o "$TMP/drawbg"
"$TMP/drawbg" "$TMP"
tiffutil -cathidpicheck "$TMP/bg.png" "$TMP/bg@2x.png" -out "$STAGE/.background/bg.tiff" >/dev/null

# Writable image first, so Finder can save the window layout into it.
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -size 40m "$TMP/rw.dmg"
MNT=$(hdiutil attach "$TMP/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\//{print $NF}')
DISK=$(basename "$MNT")

# Window layout: 640x400 icon view, background, icons over the arrow's ends.
if ! osascript <<EOF
tell application "Finder"
    tell disk "$DISK"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 13
        set background picture of opts to file ".background:bg.tiff"
        set position of item "AgentUsage.app" of container window to {160, 190}
        set position of item "Applications" of container window to {480, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
then
    echo "Note: Finder layout skipped (no permission to control Finder); the image still works."
fi

rm -rf "$MNT/.fseventsd"
sync
hdiutil detach "$MNT" -quiet
MNT=""

mkdir -p dist
rm -f "$DMG"
hdiutil convert -quiet "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
