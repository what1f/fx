#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/Sources/Consumer"
cat > "$task_tmp/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
import Foundation
let package = Package(
    name: "Consumer", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "LibFx", path: ProcessInfo.processInfo.environment["LIBFX_SWIFT_PACKAGE"]!)],
    targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "LibFx", package: "LibFx")])]
)
SWIFT
cat > "$task_tmp/Sources/Consumer/Consumer.swift" <<'SWIFT'
import Foundation
import LibFx
struct MockHTTP: FxHTTPClient {
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text = "data: {\"type\":\"text-delta\",\"delta\":\"consumer ok\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8)); continuation.finish()
        })
    }
}
@main struct Consumer {
    static func main() async throws {
        let engine = try await FxEngine.open(configuration: FxConfiguration(
            apiKey: "consumer-test-key", model: "swift/consumer", httpClient: MockHTTP()
        ))
        let turn = try await engine.prompt("hello")
        var text = ""
        for try await event in turn { if case .text(let delta) = event { text += delta } }
        guard text == "consumer ok", try await turn.result.stopReason == .endTurn else {
            throw FxError.protocolViolation("Unexpected consumer response")
        }
        try await engine.close()
        print("Swift package consumer passed")
    }
}
SWIFT
LIBFX_SWIFT_PACKAGE="$repo_root/swift" swift run --package-path "$task_tmp" -c release Consumer
