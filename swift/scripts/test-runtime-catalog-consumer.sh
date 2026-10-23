#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/Sources/Consumer"
cp "$repo_root/swift/Tests/LibFxTests/RuntimeCatalogProbe.swift" "$task_tmp/Sources/Consumer/RuntimeCatalogProbe.swift"
cat > "$task_tmp/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
import Foundation
let package = Package(name: "Consumer", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "LibFx", path: ProcessInfo.processInfo.environment["LIBFX_SWIFT_PACKAGE"]!)],
    targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "LibFx", package: "LibFx")])])
SWIFT
cat > "$task_tmp/Sources/Consumer/Main.swift" <<'SWIFT'
@main struct Consumer {
    static func main() async throws {
        let summaries = try await runRuntimeCatalogProbe()
        print("Runtime catalog consumer passed: \(summaries) automatic compaction requests")
    }
}
SWIFT
export LIBFX_SWIFT_PACKAGE="$repo_root/swift"
swift build --package-path "$task_tmp" -c release
consumer_bin="$(swift build --package-path "$task_tmp" -c release --show-bin-path)/Consumer"
"$consumer_bin" 2> "$task_tmp/consumer.stderr"
if [[ -s "$task_tmp/consumer.stderr" ]]; then
    cat "$task_tmp/consumer.stderr" >&2
    exit 1
fi
