// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibFx",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LibFx", targets: ["LibFx"])],
    targets: [
        .binaryTarget(name: "CFx", path: "Artifacts/CFx.xcframework"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "LibFx", dependencies: ["CFx", "CSQLite"]),
        .executableTarget(name: "FxSwiftDriver", dependencies: ["LibFx"]),
        .testTarget(name: "LibFxTests", dependencies: ["LibFx"]),
    ]
)
