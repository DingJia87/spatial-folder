#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
RELEASE_DIR="$ROOT/Release"
APP_NAME="空间文件夹 2.3.2 测试版"
APP="$RELEASE_DIR/$APP_NAME.app"
ZIP="$RELEASE_DIR/空间文件夹-v2.3.2-测试版.zip"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
CACHE="$ROOT/.build/module-cache"
SCRATCH="$ROOT/.build/2.3.2-release"

if [[ ! -d "$SDK" ]]; then
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$RELEASE_DIR" "$CACHE"
cd "$ROOT"
SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$CACHE" \
    swift build -c release --disable-sandbox --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
BIN_DIR="$(SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$CACHE" \
    swift build -c release --disable-sandbox --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SpatialFolder" "$APP/Contents/MacOS/空间文件夹"
cp -R "$BIN_DIR/SpatialFolder_SpatialFolder.bundle" "$APP/Contents/Resources/"
cp "$ROOT/Assets/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/空间文件夹"
xattr -cr "$APP"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

VERIFY_DIR="$(mktemp -d /tmp/spatial-folder-2.3.2-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ZIP" "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/$APP_NAME.app"

echo "$APP"
echo "$ZIP"
