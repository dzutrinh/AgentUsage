#!/bin/bash
# Renders the README screenshots into docs/screenshots from made-up demo data.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p docs/screenshots

# All app sources except the app's own entry point, plus the screenshot entry point.
SRC=$(ls Sources/*.swift | grep -v '/App.swift$')
swiftc -swift-version 5 -parse-as-library $SRC Design/Screenshots.swift -lsqlite3 -o "$TMP/shots"
"$TMP/shots" docs/screenshots 2>/dev/null

sips -z 256 256 Design/AppIcon-1024.png --out docs/screenshots/icon.png >/dev/null
echo "Wrote docs/screenshots/icon.png"
