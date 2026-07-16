#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SDK="$("$ROOT/scripts/select_macos_sdk.zsh")"
SWIFTC="$(xcrun --find swiftc)"
ARCH="$(uname -m)"
CACHE="$ROOT/.build/performance-module-cache"
OUTPUT="$ROOT/.build/SpatialFolderPerformanceBaseline"

mkdir -p "$CACHE"
SDKROOT="$SDK" CLANG_MODULE_CACHE_PATH="$CACHE" \
    "$SWIFTC" \
    -sdk "$SDK" \
    -target "$ARCH-apple-macosx14.0" \
    -module-cache-path "$CACHE" \
    -parse-as-library \
    "$ROOT/Sources/SpatialFolder/CanvasLayoutStore.swift" \
    "$ROOT/Sources/SpatialFolder/FolderScanService.swift" \
    "$ROOT/Sources/SpatialFolder/OperationHistoryStore.swift" \
    "$ROOT/Sources/SpatialFolder/OperationJournalStore.swift" \
    "$ROOT/Tests/Performance/PerformanceMain.swift" \
    -o "$OUTPUT"

"$OUTPUT"
