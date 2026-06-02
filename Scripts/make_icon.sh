#!/usr/bin/env bash
# Regenerate AppIcon.icns from Scripts/make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="$(mktemp -d)/Squeak.iconset"
mkdir -p "$ICONSET"
swift Scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote AppIcon.icns"
