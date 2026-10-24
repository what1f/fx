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
        let proof = try await runCompactionProbe(trigger: .tokens(3000))
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
if ! FX_TRACE_LOG="$task_tmp/compaction.trace" FX_TRACE_SCOPES=context_compaction "$binary_directory/Consumer" 2> "$task_tmp/consumer.stderr"; then
    cat "$task_tmp/consumer.stderr" >&2
    exit 1
fi
if [[ -s "$task_tmp/consumer.stderr" ]]; then
    cat "$task_tmp/consumer.stderr" >&2
    exit 1
fi

python3 - "$task_tmp/compaction.trace" <<'PYTHON'
import re
import sys
from pathlib import Path
trace = Path(sys.argv[1]).read_text()
decisions = re.findall(r'event=decision .*?decision=compact .*?estimated_tokens=(\d+).*?compact_at_tokens=(\d+)', trace)
assert decisions, 'No native compaction decision'
assert all(int(limit) == 3000 and int(size) >= 3000 for size, limit in decisions), decisions
print('Native compaction request tokens / threshold:', decisions)
after = re.findall(r'request after compaction estimated_tokens=(\d+)', trace)
assert after and all(int(size) < 3000 for size in after), after
print('Native context tokens after compaction:', after)
PYTHON
