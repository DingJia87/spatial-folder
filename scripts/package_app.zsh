#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/config/release.env"
RELEASE_DIR="$ROOT/Release/$MARKETING_VERSION"
APP_NAME="$PRODUCT_NAME"
APP="$RELEASE_DIR/$APP_NAME.app"
ZIP="$RELEASE_DIR/$PRODUCT_NAME.zip"
SDK="$("$ROOT/scripts/select_macos_sdk.zsh")"
CACHE="$ROOT/.build/module-cache"
SCRATCH="$ROOT/.build/$MARKETING_VERSION-release"

# 打包前校验唯一版本源与 Info.plist，防止产物名称与内部版本不一致。
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Assets/Info.plist")"
PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Assets/Info.plist")"
[[ "$PLIST_VERSION" == "$MARKETING_VERSION" ]] || {
    echo "Info.plist 版本 $PLIST_VERSION 与 release.env $MARKETING_VERSION 不一致" >&2
    exit 1
}
[[ "$PLIST_BUILD" == "$BUILD_NUMBER" ]] || {
    echo "Info.plist 构建号 $PLIST_BUILD 与 release.env $BUILD_NUMBER 不一致" >&2
    exit 1
}

mkdir -p "$RELEASE_DIR" "$CACHE"
cd "$ROOT"
SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$CACHE" \
    swift build -c release --disable-sandbox --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors
BIN_DIR="$(SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$CACHE" \
    swift build -c release --disable-sandbox --scratch-path "$SCRATCH" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SpatialFolder" "$APP/Contents/MacOS/$APP_NAME"
cp -R "$BIN_DIR/SpatialFolder_SpatialFolder.bundle" "$APP/Contents/Resources/"
cp "$ROOT/Assets/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/$APP_NAME"
xattr -cr "$APP"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

VERIFY_DIR="$(mktemp -d /tmp/spatial-folder-$MARKETING_VERSION-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ZIP" "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/$APP_NAME.app"

echo "$APP"
echo "$ZIP"
