// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpatialFolder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpatialFolder", targets: ["SpatialFolder"])
    ],
    targets: [
        .executableTarget(name: "SpatialFolder", resources: [.process("Resources")])
    ]
)
