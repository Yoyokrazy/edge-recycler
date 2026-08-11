#!/bin/bash
# Build, install to ~/Applications, and register the login agent so Edge
# Recycler starts automatically and runs the daily 8 AM check.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Edge Recycler"
LABEL="com.edgerecycler.agent"              # launchd label (login agent)
DEST="$HOME/Applications/$APP_NAME.app"
PLIST_SRC="LaunchAgents/$LABEL.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_OUT="$HOME/Library/Logs/edge-recycle.out.log"
LOG_ERR="$HOME/Library/Logs/edge-recycle.err.log"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 1. Build (into $TMPDIR, outside any LaunchServices-scanned tree)
APP_SRC="$(./build.sh | tail -n 1)"
[ -d "$APP_SRC" ] || { echo "Build failed: '$APP_SRC' not found"; exit 1; }

# 2. Stop any running instance / previously loaded agent
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
/usr/bin/pkill -x EdgeRecycler 2>/dev/null || true
sleep 1

# 3. Install the app
echo "==> Installing to $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP_SRC" "$DEST"

# 3a. Force the installed copy to be the canonical registration for its bundle ID.
"$LSREGISTER" -f "$DEST" 2>/dev/null || true

# 4. Generate the LaunchAgent with absolute paths (launchd does not expand ~)
echo "==> Writing $PLIST_DEST"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed -e "s#__APP_PATH__#$DEST#g" \
    -e "s#__LOG_OUT__#$LOG_OUT#g" \
    -e "s#__LOG_ERR__#$LOG_ERR#g" \
    "$PLIST_SRC" > "$PLIST_DEST"
plutil -lint "$PLIST_DEST" >/dev/null

# 5. Load it (also launches the app now via RunAtLoad)
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo ""
echo "Installed. Look for the recycle icon in your menu bar."
echo "  * A macOS Notifications permission prompt should appear - click Allow."
echo "  * Click the icon for current Edge memory + history and 'Recycle Edge Now'."
echo "  * Daily prompt fires at 8:00 AM (or next wake) while Edge is running."
