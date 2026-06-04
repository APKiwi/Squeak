#!/usr/bin/env bash
# Remove the installed app. Also tears down the legacy launchd login agent if a previous
# (pre-SMAppService) install left one behind. The modern SMAppService login item is pruned
# by macOS once the app bundle is gone.
set -euo pipefail
LABEL="kiwi.ap.squeak"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Legacy cleanup: older installs registered a launchd agent. Harmless if absent.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

pkill -f "Squeak.app/Contents/MacOS/Squeak" 2>/dev/null || true
rm -rf "$HOME/Applications/Squeak.app"
echo "Removed ~/Applications/Squeak.app (and any legacy login agent)."
echo "If 'Launch at login' was on, the login item clears once the app is gone; you can"
echo "also remove it under System Settings > General > Login Items."
