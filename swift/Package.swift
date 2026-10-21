// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibFx",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LibFx", targets: ["LibFx"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2")],
    targets: [
        .binaryTarget(name: "CFx", path: "Artifacts/CFx.xcframework"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "LibFx", dependencies: ["CFx", "CSQLite", .product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "FxSwiftDriver", dependencies: ["LibFx"]),
        .testTarget(name: "LibFxTests", dependencies: ["LibFx"]),
    ]
)
