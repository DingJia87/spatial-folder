#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SDK="$("$ROOT/scripts/select_macos_sdk.zsh")"
CACHE="$ROOT/.build/standard-test-module-cache"

mkdir -p "$CACHE"
cd "$ROOT"
SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$CACHE" SWIFTPM_MODULECACHE_OVERRIDE="$CACHE" \
    swift test \
    --disable-sandbox \
    -Xswiftc -warnings-as-errors
