#!/bin/bash
# Renders Design/Icon.swift and packs every macOS icon size into Design/AppIcon.icns.
# Needs only the Command Line Tools (swiftc) and the built-in sips/iconutil.
set -euo pipefail
cd "$(dirname "$0")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -parse-as-library -O Icon.swift -o "$TMP/draw"
"$TMP/draw" "$TMP/icon_1024.png"

SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$TMP/icon_1024.png" AppIcon-1024.png
echo "Wrote Design/AppIcon.icns and Design/AppIcon-1024.png"
