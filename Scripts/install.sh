#!/usr/bin/env bash
# Build the .app and install it to ~/Applications. Launch-at-login is opt-in from the
# app's Settings window (Launch at login), handled by SMAppService - this script no
# longer registers a launchd agent. Re-run any time to update.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="kiwi.ap.squeak"
DEST="$HOME/Applications"

"$HERE/Scripts/build_app.sh"

# Stop any running instance (terminal-launched, or a previously installed copy).
pkill -f "Squeak.app/Contents/MacOS/Squeak" 2>/dev/null || true

mkdir -p "$DEST"
rm -rf "$DEST/Squeak.app"
cp -R "$HERE/Squeak.app" "$DEST/"

# Launch once now. SMAppService registers this bundle for login when the user enables
# "Launch at login" in Settings.
open "$DEST/Squeak.app"

echo "Installed $DEST/Squeak.app and launched it."
echo "Enable 'Launch at login' in the app's Settings if you want it to start automatically."
echo "To remove: Scripts/uninstall.sh"
