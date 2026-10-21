#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tmp="$(mktemp -d)"
provider_pid=""
cleanup() {
    if [[ -n "$provider_pid" ]]; then
        kill "$provider_pid" 2>/dev/null || true
        wait "$provider_pid" 2>/dev/null || true
    fi
    rm -rf "$task_tmp"
}
trap cleanup EXIT
node - "$task_tmp" <<'JS' &
const http = require('node:http');
const fs = require('node:fs');
const directory = process.argv[2];
const server = http.createServer((request, response) => {
    fs.appendFileSync(`${directory}/requests.jsonl`, JSON.stringify({url: request.url, auth: request.headers.authorization}) + '\n');
    request.resume();
    if (request.url === '/redirect/chat/completions' || request.url === '/token') {
        response.writeHead(307, {location: '/other/chat/completions'}); response.end(); return;
    }
    response.writeHead(200, {'content-type': 'text/event-stream'});
    response.end('data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"HTTP consumer ok"},"finish_reason":null}]}\n\ndata: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
server.listen(0, '127.0.0.1', () => fs.writeFileSync(`${directory}/port`, String(server.address().port)));
JS
provider_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ -f "$task_tmp/port" ]] && break
    sleep 0.05
done
[[ -f "$task_tmp/port" ]]
provider_port="$(cat "$task_tmp/port")"
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
struct SubscriptionHTTP: FxHTTPClient {
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        switch request.url!.path {
        case "/cli/stable": text = "1.0.50"
        case "/v1/models":
            text = #"{"data":[{"id":"grok-4.5","model":"grok-4.5","api_backend":"responses","context_window":500000,"supports_reasoning_effort":false,"reasoning_efforts":[]}]}"#
        case "/v1/language-models":
            text = #"{"models":[{"id":"grok-4.5","input_modalities":["text"],"output_modalities":["text"]}]}"#
        case "/v1/responses":
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer consumer-subscription-key",
                  request.value(forHTTPHeaderField: "x-grok-user-id") == "consumer-account" else {
                throw FxError.protocolViolation("Missing subscription authorization")
            }
            text = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\"}}\n\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"subscription consumer ok\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        default: throw FxError.protocolViolation("Unexpected subscription endpoint")
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
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
        let subscription = FxSubscription(provider: .grok, credentials: { _ in
            try FxSubscriptionCredentials(accessToken: "consumer-subscription-key", accountID: "consumer-account")
        })
        let subscribed = try await FxEngine.open(configuration: FxConfiguration(
            provider: .subscription(subscription), model: "grok-4.5", httpClient: SubscriptionHTTP()))
        let subscriptionTurn = try await subscribed.prompt("hello")
        var subscriptionText = ""
        for try await event in subscriptionTurn { if case .text(let delta) = event { subscriptionText += delta } }
        guard subscriptionText == "subscription consumer ok", try await subscriptionTurn.result.stopReason == .endTurn else {
            throw FxError.protocolViolation("Unexpected subscription response")
        }
        try await subscribed.close()
        let port = ProcessInfo.processInfo.environment["LIBFX_PROVIDER_PORT"]!
        for prefix in ["v1", "redirect"] {
            let provider = try FxCustomProvider(name: "local", baseURL: URL(string: "http://127.0.0.1:\(port)/\(prefix)")!,
                                                models: ["local-model": .init(contextWindow: 32768, maxOutputTokens: 4096)])
            let native = try await FxEngine.open(configuration: FxConfiguration(
                provider: .custom(provider, credentials: { _ in "consumer-provider-key" }), model: "local-model"))
            let response = try await native.prompt("hello")
            var content = ""
            for try await event in response { if case .text(let delta) = event { content += delta } }
            let result = try await response.result
            guard prefix == "v1" ? (content == "HTTP consumer ok" && result.stopReason == .endTurn) : result.stopReason != .endTurn else {
                throw FxError.protocolViolation("Unexpected provider HTTP response")
            }
            try await native.close()
        }
        var tokenRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/token")!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.httpBody = Data("refresh_token=consumer-refresh-token".utf8)
        let tokenResponse = try await FxURLSessionHTTPClient().send(tokenRequest)
        guard tokenResponse.statusCode == 307 else { throw FxError.protocolViolation("Token redirect was followed") }
        tokenResponse.cancel()
        print("Swift package consumer passed")
    }
}
SWIFT
LIBFX_PROVIDER_PORT="$provider_port" LIBFX_SWIFT_PACKAGE="$repo_root/swift" swift run --package-path "$task_tmp" -c release Consumer

node - "$task_tmp/requests.jsonl" <<'JS'
const assert = require('node:assert/strict');
const requests = require('node:fs').readFileSync(process.argv[2], 'utf8').trim().split('\n').map(JSON.parse);
assert.deepEqual(requests.map(request => request.url), ['/v1/chat/completions', '/redirect/chat/completions', '/token']);
assert.ok(requests.slice(0, 2).every(request => request.auth === 'Bearer consumer-provider-key'));
console.log('Foundation HTTP consumer and credential redirect isolation passed');
JS
