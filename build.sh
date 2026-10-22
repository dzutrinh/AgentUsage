#!/bin/bash
# Builds build/AgentUsage.app with the Command Line Tools (no Xcode needed).
#   ./build.sh            build only
#   ./build.sh install    build, copy to ~/Applications and launch
#   ARCHS="arm64 x86_64" ./build.sh    universal build (package.sh does this)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AgentUsage.app
ARCHS="${ARCHS:-$(uname -m)}"
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

SLICES=()
for arch in $ARCHS; do
    swiftc -O -swift-version 5 -parse-as-library \
        -target "$arch-apple-macos14.0" \
        Sources/*.swift -lsqlite3 \
        -o "build/obj/AgentUsage-$arch"
    SLICES+=("build/obj/AgentUsage-$arch")
done
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/AgentUsage"
rm -rf build/obj
cp Info.plist "$APP/Contents/"
[ -f Design/AppIcon.icns ] || Design/make_icon.sh
cp Design/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x AgentUsage 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/AgentUsage.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/AgentUsage.app
    echo "Installed ~/Applications/AgentUsage.app"
fi
