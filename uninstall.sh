#!/bin/bash
# Remove the login agent and the installed app.
set -euo pipefail

APP_NAME="Edge Recycler"
LABEL="com.edgerecycler.agent"
DEST="$HOME/Applications/$APP_NAME.app"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Unloading login agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo "==> Stopping app"
for p in $(pgrep -x EdgeRecycler 2>/dev/null || true); do kill "$p" 2>/dev/null || true; done

echo "==> Removing files"
rm -f "$PLIST_DEST"
rm -rf "$DEST"
rm -f "$HOME/Library/Logs/edge-recycle."*.log 2>/dev/null || true

echo "Done. (Your Edge and its settings are untouched.)"
echo "Note: Edge Recycler may still appear under System Settings > General >"
echo "Login Items & Extensions until next login; that entry clears itself."
echo "Learned baseline data (if any) remains at:"
echo "  ~/Library/Application Support/EdgeRecycler/  (delete to fully reset)"
