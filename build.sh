#!/bin/bash
# Build Edge Recycler.app into ./build from the Swift source.
# Produces a signed, self-contained .app bundle (no Xcode project needed).
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Edge Recycler"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Cleaning previous build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Writing bundle metadata"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Compiling (Swift, arm64/x86_64 as supported by this Mac)"
swiftc -O -swift-version 5 \
    -framework AppKit -framework UserNotifications \
    -o "$APP/Contents/MacOS/EdgeRecycler" \
    Sources/main.swift

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" >/dev/null && echo "    signature OK"

echo "==> Built: $APP"
