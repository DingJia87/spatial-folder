// swift-tools-version: 6.0
import PackageDescription
import Foundation

// 完整 Xcode 会自动提供 Testing 互操作库；只有纯 Command Line Tools 环境需要补搜索路径。
let commandLineToolsLibrary = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let testingLinkerSettings: [LinkerSetting] = FileManager.default.fileExists(
    atPath: "\(commandLineToolsLibrary)/lib_TestingInterop.dylib"
) ? [
    .unsafeFlags([
        "-L", commandLineToolsLibrary,
        "-Xlinker", "-rpath",
        "-Xlinker", commandLineToolsLibrary
    ])
] : []

let package = Package(
    name: "SpatialFolder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpatialFolder", targets: ["SpatialFolder"])
    ],
    dependencies: [
        // 固定到与当前 Swift 6.3 工具链匹配的官方测试运行时；仅测试目标使用，不进入 App。
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.3.2-RELEASE"
        )
    ],
    targets: [
        .executableTarget(name: "SpatialFolder", resources: [.process("Resources")]),
        // 标准测试目标让本地与 CI 都能直接使用 `swift test`，不依赖人工记忆脚本参数。
        .testTarget(
            name: "SpatialFolderTests",
            dependencies: [
                "SpatialFolder",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/SpatialFolderTests",
            // 纯 Command Line Tools 把 Testing 的 C 互操作库放在 Developer/usr/lib。
            linkerSettings: testingLinkerSettings
        )
    ]
)
