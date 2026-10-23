#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/Sources/Consumer"
cat > "$task_tmp/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import Foundation
import PackageDescription
let package = Package(
    name: "CompactionConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "LibFx", path: ProcessInfo.processInfo.environment["LIBFX_SWIFT_PACKAGE"]!)],
    targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "LibFx", package: "LibFx")])]
)
SWIFT
cp "$repo_root/swift/Tests/LibFxTests/CompactionProbe.swift" "$task_tmp/Sources/Consumer/CompactionProbe.swift"
cat > "$task_tmp/Sources/Consumer/Consumer.swift" <<'SWIFT'
import Foundation
import LibFx

@main struct Consumer {
    static func main() async throws {
        let proof = try await runCompactionProbe()
        print("Compaction model requests: \(proof.summaryRequests)")
        print("Conversation model requests: \(proof.conversationRequests)")
        print("Persisted history replacements: \(proof.replacementRecords)")
        print("Model context text bytes: \(proof.beforeBytes) -> \(proof.afterBytes)")
        print("Kernel checkpoint bytes: \(proof.checkpointBytes)")
        print("Continued after compaction and SQLite reopen")
    }
}
SWIFT
LIBFX_SWIFT_PACKAGE="$repo_root/swift" swift build --package-path "$task_tmp" -c release
binary_directory="$(LIBFX_SWIFT_PACKAGE="$repo_root/swift" swift build --package-path "$task_tmp" -c release --show-bin-path)"
if ! "$binary_directory/Consumer" 2> "$task_tmp/consumer.stderr"; then
    cat "$task_tmp/consumer.stderr" >&2
    exit 1
fi
if [[ -s "$task_tmp/consumer.stderr" ]]; then
    cat "$task_tmp/consumer.stderr" >&2
    exit 1
fi
