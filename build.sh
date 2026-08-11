#!/bin/bash
# Build Edge Recycler.app from the Swift source into a temp directory that
# LaunchServices does NOT auto-scan. Building inside the repo (which lives under
# ~/Documents) would get the artifact auto-registered and collide with the copy
# installed in ~/Applications — a duplicate bundle ID silently breaks
# notification routing. So we build outside any scanned tree.
#
# Prints the built .app path on the last stdout line (install.sh consumes it);
# all progress goes to stderr.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Edge Recycler"
BUILD_DIR="${TMPDIR:-/tmp}/EdgeRecycler-build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building in $BUILD_DIR" >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Writing bundle metadata" >&2
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Compiling" >&2
swiftc -O -swift-version 5 \
    -framework AppKit -framework UserNotifications \
    -o "$APP/Contents/MacOS/EdgeRecycler" \
    Sources/main.swift

echo "==> Ad-hoc code signing" >&2
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" >/dev/null 2>&1 && echo "    signature OK" >&2

echo "==> Built: $APP" >&2
# machine-readable result on stdout
echo "$APP"
