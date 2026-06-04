#!/usr/bin/env bash
# Build a release binary and wrap it in a proper .app bundle (menu-bar agent, no Dock icon).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Squeak.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Squeak" "$APP/Contents/MacOS/Squeak"
cp "Info.plist" "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp "AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign with the shared self-signed identity when present (stable across rebuilds, so any
# TCC/login grants persist), else ad-hoc. Create it once with Scripts/make_signing_cert.sh.
SIGN_ID="AP Kiwi Local Signing"
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" "$APP" >/dev/null
else
    codesign --force --sign - "$APP" >/dev/null
fi

echo "Built $APP"
