// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "DeepSeekAcceptance", platforms: [.macOS(.v15)],
    dependencies: [.package(name: "LibFx", path: "../..")],
    targets: [.executableTarget(name: "Acceptance", dependencies: [.product(name: "FxAgentKit", package: "LibFx")])])
