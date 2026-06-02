#!/usr/bin/env bash
# Build a release binary and wrap it in a proper .app bundle (menu-bar agent, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Squeak.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/Squeak" "$APP/Contents/MacOS/Squeak"
cp "Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign so macOS will run it and remember any Input Monitoring grant.
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
