// swift-tools-version: 6.0
import PackageDescription
import Foundation

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
        // 6.1.3 使用 SwiftSyntax 601，可兼容本机备用 macOS 15.4 SDK；测试 API
        // 对本项目足够，且不影响使用 Swift 6.3 构建正式 App。
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.1.3-RELEASE"
        )
    ],
    targets: [
        .executableTarget(name: "SpatialFolder", resources: [.process("Resources")]),
        .testTarget(
            name: "SpatialFolderTests",
            dependencies: [
                "SpatialFolder",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/SpatialFolderTests",
            linkerSettings: testingLinkerSettings
        )
    ]
)
