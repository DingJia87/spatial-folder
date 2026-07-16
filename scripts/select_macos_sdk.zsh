#!/bin/zsh
set -euo pipefail

if [[ -n "${SPATIAL_FOLDER_SDK:-}" ]]; then
    print -r -- "$SPATIAL_FOLDER_SDK"
    exit 0
fi

DEVELOPER_ROOT="$(xcode-select -p)"
FALLBACK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ "$DEVELOPER_ROOT" == "/Library/Developer/CommandLineTools" && -d "$FALLBACK" ]]; then
    # 当前机器的默认 26.5 SDK 来自 Swift 6.3.2，而编译器已更新到 6.3.3。
    # 15.4 SDK 与当前编译器可以严格构建；安装完整 Xcode 后自动回到 Xcode 默认 SDK。
    print -r -- "$FALLBACK"
else
    xcrun --sdk macosx --show-sdk-path
fi
