#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/Sources/Consumer"
cp "$repo_root/swift/scripts/workspace-tools-consumer/Consumer.swift" "$task_tmp/Sources/Consumer/Consumer.swift"
cat > "$task_tmp/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
import Foundation
let package = Package(name: "WorkspaceConsumer", platforms: [.macOS(.v14)],
    dependencies: [.package(path: ProcessInfo.processInfo.environment["FX_SWIFT_PACKAGE"]!)],
    targets: [.executableTarget(name: "Consumer", dependencies: [
        .product(name: "FxAgentKit", package: "swift"), .product(name: "LibFx", package: "swift"),
    ])])
SWIFT
FX_SWIFT_PACKAGE="$repo_root" swift run --package-path "$task_tmp" -c release Consumer
