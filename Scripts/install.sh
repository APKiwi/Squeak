#!/usr/bin/env bash
# Build the .app, install it to ~/Applications, and register a login agent so it
# starts automatically and runs in the menu bar. Re-run any time to update.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="kiwi.ap.Squeak"
DEST="$HOME/Applications"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

"$HERE/Scripts/build_app.sh"

# Stop any running instance (terminal-launched or a previous agent).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "Squeak.app/Contents/MacOS/Squeak" 2>/dev/null || true

mkdir -p "$DEST"
rm -rf "$DEST/Squeak.app"
cp -R "$HERE/Squeak.app" "$DEST/"

# Launch via `open`, not by exec'ing the binary: a SwiftUI MenuBarExtra app started
# directly by launchd doesn't get an Aqua/WindowServer session and exits immediately
# with no menu-bar item. `open -W` hands it to LaunchServices (proper GUI session) and
# waits, so launchd tracks the app's real lifetime.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-W</string>
        <string>$DEST/Squeak.app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart "gui/$(id -u)/$LABEL"

echo "Installed $DEST/Squeak.app and registered login agent $LABEL."
echo "Running now and on every login. To stop/remove: Scripts/uninstall.sh"
