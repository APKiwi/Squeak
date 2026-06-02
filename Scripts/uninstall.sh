#!/usr/bin/env bash
# Stop the login agent and remove the installed app.
set -euo pipefail
LABEL="kiwi.ap.Squeak"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/Squeak.app"
echo "Removed login agent and ~/Applications/Squeak.app."
