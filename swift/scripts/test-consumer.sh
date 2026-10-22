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
    if (request.url === '/mcp') {
        let body = '';
        request.setEncoding('utf8');
        request.on('data', chunk => { body += chunk; });
        request.on('end', () => {
            const message = JSON.parse(body);
            if (message.id === undefined) { response.writeHead(202); response.end(); return; }
            let result;
            if (message.method === 'initialize') result = {protocolVersion: message.params.protocolVersion,
                capabilities: {tools: {}, resources: {}, prompts: {}}, serverInfo: {name: 'consumer', version: '1'}};
            else if (message.method === 'tools/list') result = {tools: [{name: 'echo', description: 'Echo', inputSchema: {type: 'object'}}]};
            else if (message.method === 'tools/call') result = {content: [{type: 'text', text: `MCP_CONSUMER:${message.params.arguments.value}`}]};
            else if (message.method === 'resources/read') result = {contents: [{uri: message.params.uri, text: 'MCP_RESOURCE'}]};
            else if (message.method === 'prompts/get') result = {messages: [{role: 'user', content: {type: 'text', text: 'MCP_PROMPT'}}]};
            else throw new Error(`Unexpected MCP method: ${message.method}`);
            response.writeHead(200, {'content-type': 'application/json'});
            response.end(JSON.stringify({jsonrpc: '2.0', id: message.id, result}));
        });
        return;
    }
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
// swift-tools-version: 6.2
import PackageDescription
import Foundation
let package = Package(
    name: "Consumer", platforms: [.macOS(.v14)],
    dependencies: [.package(name: "LibFx", path: ProcessInfo.processInfo.environment["LIBFX_SWIFT_PACKAGE"]!),
                   .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")],
    targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "LibFx", package: "LibFx"),
                   .product(name: "LibFxMCP", package: "LibFx"), .product(name: "MCP", package: "swift-sdk")])]
)
SWIFT
cat > "$task_tmp/Sources/Consumer/Consumer.swift" <<'SWIFT'
import Foundation
import LibFx
import LibFxMCP
import MCP
final class TransportEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FxTransportEvent] = []
    var values: [FxTransportEvent] { lock.withLock { recorded } }
    func record(_ event: FxTransportEvent) { lock.withLock { recorded.append(event) } }
}
final class LifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FxLifecycleEvent] = []
    var values: [FxLifecycleEvent] { lock.withLock { recorded } }
    func record(_ event: FxLifecycleEvent) { lock.withLock { recorded.append(event) } }
}
final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [FxObservation] = []
    var values: [FxObservation] { lock.withLock { recorded } }
    func record(_ event: FxObservation) { lock.withLock { recorded.append(event) } }
}
struct MockHTTP: FxHTTPClient {
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text = request.httpMethod == "GET" ? #"{"data":[{"id":"swift/consumer","type":"language"}]}"# : "data: {\"type\":\"text-delta\",\"delta\":\"consumer ok\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8)); continuation.finish()
        })
    }
}
struct ProviderSearchHTTP: FxHTTPClient {
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            let text = #"{"data":[{"id":"swift/consumer","type":"language","tags":["tool-use"]}]}"#
            return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        guard case .array(let tools) = body["tools"], tools.contains(where: { $0["type"] == .string("provider") }) else {
            throw FxError.protocolViolation("Missing search advertisement")
        }
        return try await MockHTTP().send(request)
    }
}
actor ToolInputHTTP: FxHTTPClient {
    private var posts = 0
    let input: JSONValue
    let toolName: String
    let requiresSkill: Bool
    init(input: JSONValue, toolName: String = "probe", requiresSkill: Bool = true) {
        self.input = input; self.toolName = toolName; self.requiresSkill = requiresSkill
    }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" { return try await ProviderSearchHTTP().send(request) }
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        guard !requiresSkill || (body.contains("SKILL_CONSUMER") && body.contains("RESOURCE_CONSUMER")) else {
            throw FxError.protocolViolation("Missing skill context")
        }
        posts += 1
        if posts != 1 { return try await MockHTTP().send(request) }
        let call = JSONValue.object(["type": .string("tool-call"), "toolCallId": .string("consumer-call"),
                                    "toolName": .string(toolName), "input": input])
        let payload = "data: \(String(decoding: try JSONEncoder().encode(call), as: UTF8.self))\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(payload.utf8)); $0.finish() })
    }
}
actor PreparingHTTP: FxHTTPClient {
    private var blocked = true
    func unblock() { blocked = false }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            if blocked { try await Task.sleep(for: .seconds(60)) }
            let text = #"{"data":[{"id":"swift/preparing","type":"language","tags":["reasoning"],"reasoning_options":[{"type":"effort","values":["high"]}]}]}"#
            return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
        }
        return try await MockHTTP().send(request)
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
        let toolInput = JSONValue.object(["content": .string(String(repeating: "x", count: 128 * 1024))])
        let waitEvents = Observations()
        let tool = FxTool(name: "probe", description: "Probe", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { input, context in
            guard input == toolInput, let observation = context.observation else { throw FxError.protocolViolation("Incomplete tool context") }
            let returned = await observation.wait(FxWaitRequest(kind: .approval, prompt: "Continue?"),
                resolution: { _ in FxWaitResolution(answers: ["approve"]) }) { input }
            guard returned == input else { throw FxError.protocolViolation("Changed effect result") }
            return "received"
        }
        let skillFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: skillFile) }
        try Data("---\nname: consumer\ndescription: >-\n  Consumer skill\n---\nSKILL_CONSUMER".utf8).write(to: skillFile)
        let skills = try FxSkills([try await FxSkill.load(from: skillFile,
            resources: [.init(uri: "memory://consumer", text: "RESOURCE_CONSUMER")], tools: [tool])])
        let toolEngine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "consumer-test-key", model: "swift/consumer",
            instructions: skills.instructions, tools: skills.tools, httpClient: ToolInputHTTP(input: toolInput),
            observation: FxObservationOptions(captureContent: true, onEvent: waitEvents.record)))
        let toolTurn = try await toolEngine.prompt("probe")
        var previews = 0
        for try await event in toolTurn {
            if case .toolStarted(_, "probe", .truncated(let preview)) = event {
                guard preview.utf8.count == 64 * 1024 else { throw FxError.protocolViolation("Unexpected preview size") }
                previews += 1
            }
        }
        guard previews == 1, try await toolTurn.result.stopReason == .endTurn else {
            throw FxError.protocolViolation("Missing tool preview")
        }
        try await toolEngine.close()
        let waits = waitEvents.values.filter { $0.kind == .waitStarted || $0.kind == .waitEnded }
        guard waits.map(\.kind) == [.waitStarted, .waitEnded], waits[0].data["callId"] == .string("consumer-call"),
              waits[0].data["requestId"] == waits[1].data["requestId"], waits[0].data["prompt"] == .string("Continue?"),
              waits[1].data["outcome"] == .string("accepted"), waits[1].data["answers"] == .array([.string("approve")]),
              waits.allSatisfy({ $0.sessionID == toolEngine.sessionID && $0.turnID == toolTurn.id && $0.contentCaptured }) else {
            throw FxError.protocolViolation("Unexpected input wait observations")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FxSQLitePersistence(url: directory.appendingPathComponent("conversation.sqlite"))
        let transportEvents = TransportEvents()
        let lifecycleEvents = LifecycleEvents()
        let engine = try await FxEngine.open(configuration: FxConfiguration(
            apiKey: "consumer-test-key", model: "swift/consumer", httpClient: MockHTTP(), checkpointAfterBytes: 0,
            onTransportEvent: { transportEvents.record($0) },
            onPermission: { request in
                let offered: FxPermissionOption? = request.options.first { $0.kind == .rejectOnce }
                return offered.map { FxPermissionDecision.select(optionID: $0.id) } ?? .cancel
            }, onLifecycleEvent: lifecycleEvents.record
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
        let requests = transportEvents.values.compactMap { event -> FxTransportEvent.Request? in
            if case .started(let request) = event { return request }; return nil
        }
        let responses = transportEvents.values.compactMap { event -> FxTransportEvent.Request? in
            if case .response(let request, let response) = event, response.statusCode == 200 { return request }; return nil
        }
        guard requests.map(\.number) == [1, 2, 1], responses.map(\.id) == requests.map(\.id),
              requests.allSatisfy({ $0.sessionID == engine.sessionID && $0.modelID == "swift/consumer" }) else {
            throw FxError.protocolViolation("Unexpected transport events")
        }
        guard transportEvents.values.contains(where: { event in
            if case .activity(let request, let chunkBytes, let totalBytes) = event {
                return request.method == "POST" && chunkBytes > 0 && totalBytes >= chunkBytes
            }
            return false
        }) else { throw FxError.protocolViolation("Missing response progress") }
        let saved = try await store.load()
        guard saved.checkpoint != nil, saved.journal.isEmpty else { throw FxPersistenceError.invalidJournal }
        guard lifecycleEvents.values.contains(where: {
            if case .checkpointSaved(let id, let cursor, let bytes) = $0 {
                return id == engine.sessionID && cursor == saved.checkpoint?.through && bytes > 0
            }
            return false
        }) else { throw FxError.protocolViolation("Missing lifecycle snapshot event") }
        let restored = try await FxEngine.open(configuration: FxConfiguration(
            apiKey: "consumer-test-key", model: "swift/consumer", httpClient: MockHTTP()
        ), persistence: store)
        let duplicate = try await restored.prompt("ignored retry", id: followUp.id)
        for try await _ in duplicate { throw FxPersistenceError.invalidJournal }
        guard try await duplicate.result.stopReason == .endTurn else { throw FxPersistenceError.invalidJournal }
        try await restored.close()
        try await store.close()
        let defaultModel = try await FxEngine.open(configuration: FxConfiguration(apiKey: "consumer-test-key", httpClient: MockHTTP()))
        let defaultTurn = try await defaultModel.prompt("use the default model")
        guard try await defaultTurn.result.stopReason == .endTurn else { throw FxPersistenceError.invalidJournal }
        _ = try await defaultModel.checkpoint()
        try await defaultModel.close()
        let searching = try await FxEngine.open(configuration: FxConfiguration(apiKey: "consumer-test-key",
            model: "swift/consumer", providerTools: [.webSearch], httpClient: ProviderSearchHTTP()))
        let search = try await searching.prompt("search if needed")
        guard try await search.result.stopReason == .endTurn else { throw FxPersistenceError.invalidJournal }
        try await searching.close()
        let sessions = try FxSessionStore(url: directory.appendingPathComponent("sessions.sqlite"))
        let agent = try FxAgent(configuration: FxConfiguration(
            apiKey: "consumer-test-key", model: "swift/consumer", httpClient: MockHTTP()), store: sessions, checkpointAfterBytes: 0,
            deliveryPolicy: FxDeliveryPolicy(maximumDuration: .seconds(30), reserve: .seconds(5)))
        let session = try await agent.session(id: "consumer-session")
        let durable = try await session.prompt("hello", id: "durable-message")
        var durableText = ""
        for try await event in durable { if case .text(let delta) = event { durableText += delta } }
        guard durableText == "consumer ok", try await durable.result.stopReason == .endTurn else {
            throw FxError.protocolViolation("Unexpected durable response")
        }
        let repeated = try await session.prompt("ignored", id: durable.id)
        guard try await repeated.result.isRepeated else { throw FxPersistenceError.invalidJournal }
        guard try await session.resume() == nil else { throw FxPersistenceError.invalidJournal }
        let guidance = try await session.steer("remember this guidance", id: "consumer-guidance")
        let afterGuidance = try await session.prompt("after guidance", id: "after-guidance")
        guard try await afterGuidance.result.stopReason == .endTurn else { throw FxPersistenceError.invalidJournal }
        var sawGuidance = false
        for try await entry in session.events() {
            if case .ended(let result) = entry.event, result.id == guidance.id {
                sawGuidance = result.stopReason == .endTurn
                break
            }
        }
        guard sawGuidance else { throw FxPersistenceError.invalidJournal }
        let sessionCheckpoint = try await session.checkpoint()
        try await agent.close()
        let seeded = try FxAgent(configuration: FxConfiguration(
            apiKey: "consumer-test-key", model: "swift/consumer", httpClient: MockHTTP()),
            store: sessions, checkpoint: sessionCheckpoint)
        let seededSession = try await seeded.session(id: "seeded-session")
        let seededTurn = try await seededSession.prompt("continue", id: "seeded-message")
        guard try await seededTurn.result.stopReason == .endTurn else { throw FxPersistenceError.invalidJournal }
        try await seeded.close()
        let preparingHTTP = PreparingHTTP()
        let preparing = try FxAgent(configuration: FxConfiguration(apiKey: "consumer-test-key",
            model: FxModel(id: "swift/preparing", reasoningEffort: "high"), httpClient: preparingHTTP),
            store: sessions, deliveryPolicy: FxDeliveryPolicy(maximumDuration: .milliseconds(180), reserve: .milliseconds(80)))
        let preparingSession = try await preparing.session(id: "preparing-session")
        let waiting = try await preparingSession.prompt("retain this input", id: "preparing-message")
        do {
            _ = try await waiting.result
            throw FxError.protocolViolation("Expected preparation timeout")
        } catch FxSessionError.preparationTimedOut {}
        await preparingHTTP.unblock()
        guard let retried = try await preparingSession.resume(), retried.id == waiting.id,
              try await retried.result.stopReason == .endTurn else { throw FxPersistenceError.invalidJournal }
        try await preparing.close()
        try await sessions.close()
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
        let mcp = try await FxMCPAdapter.connect(transport: HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, streaming: false),
            prefix: "mcp_", resources: ["memory://consumer"], prompts: [.init(name: "review")])
        guard mcp.tools.map(\.name) == ["mcp_echo"], mcp.instructions.contains("MCP_RESOURCE"), mcp.instructions.contains("MCP_PROMPT") else {
            throw FxError.protocolViolation("Unexpected MCP catalog or context")
        }
        let mcpEvents = Observations()
        let mcpEngine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "consumer-test-key", model: "swift/consumer",
            instructions: mcp.instructions, tools: mcp.tools,
            httpClient: ToolInputHTTP(input: .object(["value": .string("hello")]), toolName: "mcp_echo", requiresSkill: false),
            observation: FxObservationOptions(onEvent: mcpEvents.record)))
        let mcpTurn = try await mcpEngine.prompt("Use MCP", id: "consumer-mcp-turn")
        var mcpResults = 0
        for try await event in mcpTurn {
            if case .toolFinished("consumer-call", "mcp_echo", let content, false) = event {
                guard content == "MCP_CONSUMER:hello" else { throw FxError.protocolViolation("Unexpected MCP result") }
                mcpResults += 1
            }
        }
        guard mcpResults == 1, try await mcpTurn.result.stopReason == .endTurn else { throw FxError.protocolViolation("Missing MCP result") }
        try await mcpEngine.close()
        await mcp.close()
        let mcpSpans = mcpEvents.values.filter { $0.kind == .mcpStarted || $0.kind == .mcpEnded }
        guard mcpSpans.map(\.kind) == [.mcpStarted, .mcpEnded],
              mcpSpans[0].data["server"] == .string("consumer"), mcpSpans[0].data["tool"] == .string("echo"),
              mcpSpans[0].data["callId"] == .string("consumer-call"),
              mcpSpans[0].data["operationId"] == mcpSpans[1].data["operationId"],
              mcpSpans[1].data["status"] == .string("success"),
              mcpSpans.allSatisfy({ $0.turnID == "consumer-mcp-turn" && $0.sessionID == mcpEngine.sessionID }) else {
            throw FxError.protocolViolation("Unexpected MCP observations")
        }
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
