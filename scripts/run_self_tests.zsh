#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
CACHE="$ROOT/.build/self-tests-module-cache"
OUTPUT="$ROOT/.build/SpatialFolderSelfTests"

mkdir -p "$CACHE"

SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$CACHE" \
    /usr/bin/swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macosx14.0 \
    -module-cache-path "$CACHE" \
    -parse-as-library \
    "$ROOT/Sources/SpatialFolder/CanvasLayoutStore.swift" \
    "$ROOT/Sources/SpatialFolder/CanvasSessionLock.swift" \
    "$ROOT/Sources/SpatialFolder/CanvasViewport.swift" \
    "$ROOT/Sources/SpatialFolder/WindowAspectRatioController.swift" \
    "$ROOT/Sources/SpatialFolder/OperationHistoryStore.swift" \
    "$ROOT/Sources/SpatialFolder/PreferencesMigrator.swift" \
    "$ROOT/Sources/SpatialFolder/FolderCanvasModel.swift" \
    "$ROOT/Tests/SelfTests/SelfTestMain.swift" \
    -o "$OUTPUT"

"$OUTPUT"
