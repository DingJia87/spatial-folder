#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
ARCH="$(uname -m)"
CACHE="$ROOT/.build/self-tests-module-cache"
OUTPUT="$ROOT/.build/SpatialFolderSelfTests"

mkdir -p "$CACHE"

SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$CACHE" \
    "$SWIFTC" \
    -sdk "$SDK" \
    -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$CACHE" \
    -parse-as-library \
    "$ROOT/Sources/SpatialFolder/CanvasLayoutStore.swift" \
    "$ROOT/Sources/SpatialFolder/CanvasSessionLock.swift" \
    "$ROOT/Sources/SpatialFolder/CanvasViewport.swift" \
    "$ROOT/Sources/SpatialFolder/FileIconCache.swift" \
    "$ROOT/Sources/SpatialFolder/FileOperationCoordinator.swift" \
    "$ROOT/Sources/SpatialFolder/FolderScanService.swift" \
    "$ROOT/Sources/SpatialFolder/WindowAspectRatioController.swift" \
    "$ROOT/Sources/SpatialFolder/OperationHistoryStore.swift" \
    "$ROOT/Sources/SpatialFolder/PreferencesMigrator.swift" \
    "$ROOT/Sources/SpatialFolder/FolderCanvasModel.swift" \
    "$ROOT/Tests/SelfTests/SelfTestMain.swift" \
    -o "$OUTPUT"

"$OUTPUT"
