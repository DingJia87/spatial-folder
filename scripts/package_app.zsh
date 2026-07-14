#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
RELEASE_DIR="$ROOT/Release"
APP_NAME="空间文件夹 2.0"
APP="$RELEASE_DIR/$APP_NAME.app"
cd "$ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SpatialFolder" "$APP/Contents/MacOS/空间文件夹"
cp -R "$BIN_DIR/SpatialFolder_SpatialFolder.bundle" "$APP/Contents/Resources/"
cp "$ROOT/Assets/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

rm -f "$RELEASE_DIR/空间文件夹-v2.0.0.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE_DIR/空间文件夹-v2.0.0.zip"
echo "$APP"
