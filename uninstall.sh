#!/bin/bash
# Remove ratebridge. Leaves the repo alone.
set -euo pipefail

osascript -e 'tell application "Ratebridge" to quit' >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)/com.bns.ratebridge" 2>/dev/null || true
rm -f  "$HOME/Library/LaunchAgents/com.bns.ratebridge.plist"
rm -rf /Applications/Ratebridge.app
rm -f  "$HOME/.local/bin/ratebridge"

echo "removed the app, the CLI and any launch agent."
echo
echo "Left in place on purpose:"
echo "  settings   defaults delete com.bns.ratebridge"
echo "  log        rm ~/Library/Logs/ratebridge.log"
echo "  the Accessibility entry — remove it in System Settings if you are done"
