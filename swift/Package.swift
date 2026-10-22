// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LibFx",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LibFx", targets: ["LibFx"]), .library(name: "LibFxMCP", targets: ["LibFxMCP"])],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
    ],
    targets: [
        .binaryTarget(name: "CFx", path: "Artifacts/CFx.xcframework"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "LibFx", dependencies: ["CFx", "CSQLite", .product(name: "Yams", package: "Yams")]),
        .target(name: "LibFxMCP", dependencies: ["LibFx", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
        .executableTarget(name: "FxSwiftDriver", dependencies: ["LibFx", "LibFxMCP", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "LibFxTests", dependencies: ["LibFx"]),
        .testTarget(name: "LibFxMCPTests", dependencies: ["LibFx", "LibFxMCP", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
    ]
)
