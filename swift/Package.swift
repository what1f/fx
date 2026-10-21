// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibFx",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LibFx", targets: ["LibFx"])],
    targets: [
        .binaryTarget(name: "CFx", path: "Artifacts/CFx.xcframework"),
        .target(name: "LibFx", dependencies: ["CFx"]),
        .executableTarget(name: "FxSwiftDriver", dependencies: ["LibFx"]),
        .testTarget(name: "LibFxTests", dependencies: ["LibFx"]),
    ]
)
