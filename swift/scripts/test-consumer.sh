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
        let text = request.httpMethod == "GET" ? #"{"data":[{"id":"swift/consumer","type":"language"}]}"# : "data: {\"type\":\"text-delta\",\"delta\":\"consumer ok\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8)); continuation.finish()
        })
    }
}
@main struct Consumer {
    static func main() async throws {
        let models = try await FxModel.available(apiKey: "consumer-test-key", httpClient: MockHTTP())
        guard models.map(\.id) == ["swift/consumer"] else { throw FxModelCatalogError.malformedResponse }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FxSQLitePersistence(url: directory.appendingPathComponent("conversation.sqlite"))
        let engine = try await FxEngine.open(configuration: FxConfiguration(
            apiKey: "consumer-test-key", model: "swift/consumer", httpClient: MockHTTP(), checkpointAfterBytes: 0
        ), persistence: store)
        let turn = try await engine.prompt("hello", id: "consumer-turn")
        var text = ""
        for try await event in turn { if case .text(let delta) = event { text += delta } }
        guard turn.id == "consumer-turn", text == "consumer ok", try await turn.result.stopReason == .endTurn else {
            throw FxError.protocolViolation("Unexpected consumer response")
        }
        let queued = try await engine.followUp("continue")
        try await queued.accepted
        let followUp = try await queued.turn
        for try await _ in followUp {}
        guard followUp.id == queued.id, try await followUp.result.stopReason == .endTurn else {
            throw FxError.protocolViolation("Unexpected follow-up response")
        }
        try await engine.close()
        let saved = try await store.load()
        guard saved.checkpoint != nil, saved.journal.isEmpty else { throw FxPersistenceError.invalidJournal }
        let restored = try await FxEngine.open(configuration: FxConfiguration(
            apiKey: "consumer-test-key", model: "swift/consumer", httpClient: MockHTTP()
        ), persistence: store)
        let duplicate = try await restored.prompt("ignored retry", id: followUp.id)
        for try await _ in duplicate { throw FxPersistenceError.invalidJournal }
        guard try await duplicate.result.stopReason == .endTurn else { throw FxPersistenceError.invalidJournal }
        try await restored.close()
        try await store.close()
        print("Swift package consumer passed")
    }
}
SWIFT
LIBFX_SWIFT_PACKAGE="$repo_root/swift" swift run --package-path "$task_tmp" -c release Consumer
