#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
CACHE="$ROOT/.build/module-cache"
SCRATCH="$ROOT/.build/2.2"

mkdir -p "$CACHE"
cd "$ROOT"

SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$CACHE" \
    swift build --disable-sandbox --scratch-path "$SCRATCH"

exec "$SCRATCH/arm64-apple-macosx/debug/SpatialFolder"
