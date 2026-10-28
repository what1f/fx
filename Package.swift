// swift-tools-version: 6.2
import Foundation
import PackageDescription

// CFx 由 zig 编译，产物不进 Git。本地跑过 swift/scripts/build-xcframework.sh 就用本地产物；
// 作为远程依赖拉取时没有本地产物，从 GitHub Release 下载。发版用 swift/scripts/release.sh，它会改写下面两行。
let cfxReleaseURL = "https://github.com/what1f/fx/releases/download/v0.4.5-swift.1/CFx.xcframework.zip"
let cfxReleaseChecksum = "f322bd481578f24b89c786477c89759e67402bdb24a968b74ff2201d8768d82b"
let localCFx = "swift/Artifacts/CFx.xcframework"
let cfx: Target = FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + localCFx)
    ? .binaryTarget(name: "CFx", path: localCFx)
    : .binaryTarget(name: "CFx", url: cfxReleaseURL, checksum: cfxReleaseChecksum)

let package = Package(
    name: "LibFx",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FxAgentKit", targets: ["FxAgentKit"]), .library(name: "LibFx", targets: ["LibFx"]), .library(name: "LibFxMCP", targets: ["LibFxMCP"]), .library(name: "LibFxHTTP", targets: ["LibFxHTTP"])],
    dependencies: [
        .package(url: "https://github.com/kylef/JSONSchema.swift.git", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.8.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
    ],
    targets: [
        cfx,
        .systemLibrary(name: "CSQLite", path: "swift/Sources/CSQLite"),
        .target(name: "LibFx", dependencies: [.product(name: "JSONSchema", package: "JSONSchema.swift"), "CFx", "CSQLite", .product(name: "Yams", package: "Yams")], path: "swift/Sources/LibFx"),
        .target(name: "FxAgentKit", dependencies: ["LibFx", .product(name: "Yams", package: "Yams")], path: "swift/Sources/FxAgentKit"),
        .testTarget(name: "FxAgentKitTests", dependencies: ["FxAgentKit", "LibFx"], path: "swift/Tests/FxAgentKitTests"),
        .target(name: "LibFxHTTP", dependencies: ["LibFx", .product(name: "HTTPTypes", package: "swift-http-types")], path: "swift/Sources/LibFxHTTP"),
        .testTarget(name: "LibFxHTTPTests", dependencies: ["LibFx", "LibFxHTTP", .product(name: "HTTPTypes", package: "swift-http-types")], path: "swift/Tests/LibFxHTTPTests"),
        .target(name: "LibFxMCP", dependencies: ["LibFx", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")], path: "swift/Sources/LibFxMCP"),
        .executableTarget(name: "FxSwiftDriver", dependencies: ["LibFx", "LibFxMCP", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")], path: "swift/Sources/FxSwiftDriver"),
        .testTarget(name: "LibFxTests", dependencies: ["LibFx"], path: "swift/Tests/LibFxTests"),
        .testTarget(name: "LibFxMCPTests", dependencies: ["LibFx", "LibFxMCP", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")], path: "swift/Tests/LibFxMCPTests"),
    ]
)
