import CryptoKit
import Foundation
import Testing
@testable import LibFx

private func checkpointJSON(_ checkpoint: Data) throws -> JSONValue {
    let size = (0..<4).reduce(0) { $0 | Int(checkpoint[44 + $1]) << ($1 * 8) }
    return try JSONDecoder().decode(JSONValue.self, from: checkpoint[48..<(48 + size)])
}

private func expectHistoryPrefix(_ before: Data, _ after: Data) throws {
    guard case .array(let original) = try checkpointJSON(before)["history"],
          case .array(let current) = try checkpointJSON(after)["history"] else {
        Issue.record("Missing checkpoint history"); return
    }
    #expect(Array(current.prefix(original.count)) == original)
}

// Reproduce a saved duplicate with the current checkpoint format and checksum.
// This is a fixture mutation, not a production migration path.
private func duplicateSearch(in checkpoint: Data) throws -> Data {
    let headerSize = 44
    func length(_ offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(checkpoint[offset + $1]) << ($1 * 8) }
    }
    func littleEndian(_ value: Int) -> Data {
        Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    let jsonSize = length(headerSize)
    var first: String?
    var replacements = 0
    func replace(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(replace) }
        guard var object = value as? [String: Any] else { return value }
        if let saved = object["loaded_tools_json"] as? String {
            if saved != "[]" { first = saved }
            else if let first { object["loaded_tools_json"] = first; replacements += 1 }
        }
        for key in object.keys.sorted() { object[key] = replace(object[key]!) }
        return object
    }
    let json = try JSONSerialization.jsonObject(with: checkpoint[(headerSize + 4)..<(headerSize + 4 + jsonSize)])
    let rewritten = try JSONSerialization.data(withJSONObject: replace(json), options: [.sortedKeys])
    #expect(replacements == 1)
    let payload = littleEndian(rewritten.count) + rewritten + checkpoint[(headerSize + 4 + jsonSize)...]
    return checkpoint.prefix(8) + littleEndian(payload.count) + Data(SHA256.hash(data: payload)) + payload
}

@Test func runtimeCatalogRecoversPersistedDuplicateWithoutRewritingHistory() async throws {
    let calls = CatalogCalls()
    let http = CatalogHTTP(actions: [
        ("tool_search", .object(["query": .string("notes")])),
        ("tool_search", .object(["query": .string("notes")])), nil, nil,
    ], codex: true)
    let credentials = try FxSubscriptionCredentials(accessToken: "fixture-token", accountID: "fixture-account", expiresAt: Date().addingTimeInterval(3600))
    let config = FxConfiguration(provider: .subscription(FxSubscription(provider: .codex, credentials: { _ in credentials })), model: FxModel(id: "gpt-6.1-sol"), tools: [catalogTool("notes_read", calls: calls)], httpClient: http)
    let engine = try await FxEngine.open(configuration: config)
    try await drainCatalogTurn(try await engine.prompt("Search twice"))
    let poisoned = try duplicateSearch(in: await engine.checkpoint())
    try await engine.close()
    let restored = try await FxEngine.open(configuration: config, checkpoint: poisoned)
    // Opening and serializing a repaired request must leave the saved definitions alone.
    #expect(try checkpointJSON(await restored.checkpoint()) == checkpointJSON(poisoned))
    try await drainCatalogTurn(try await restored.prompt("Continue saved conversation"))
    let requests = await http.posts
    guard case .array(let input) = requests.last?["input"] else { Issue.record("Missing input"); return }
    let searches = input.filter { $0["type"] == .string("tool_search_output") }
    #expect(searches.count == 2)
    #expect(searches.last?["tools"] == .array([]))
    let names = searches.flatMap { item -> [JSONValue] in
        guard case .array(let tools) = item["tools"] else { return [] }
        return tools.compactMap { $0["name"] }
    }
    #expect(names == [.string("notes_read")])
    try expectHistoryPrefix(poisoned, await restored.checkpoint())
    try await restored.close()
}

private actor VerifiedCatalogHTTP: FxHTTPClient {
    let fixture: CatalogHTTP
    var previous: Data?
    var verified = 0
    init(_ fixture: CatalogHTTP) { self.fixture = fixture }

    func resetPrefix() { previous = nil }

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let raw = request.httpBody!
        let body = try JSONDecoder().decode(JSONValue.self, from: raw)
        if let previous {
            let old = try JSONDecoder().decode(JSONValue.self, from: previous)
            #expect(body["instructions"] == old["instructions"])
            #expect(body["reasoning"] == old["reasoning"])
            #expect(try catalogRawArray("tools", in: raw) == catalogRawArray("tools", in: previous))
            #expect(try catalogRawArray("input", in: raw).starts(with: catalogRawArray("input", in: previous).dropLast()))
        }
        let response = try await FxURLSessionHTTPClient().send(request)
        defer { response.cancel() }
        guard response.statusCode == 200 else {
            throw RuntimeCatalogProbeError.failed("DeepSeek rejected catalog request: HTTP \(response.statusCode)")
        }
        var data = Data()
        for try await part in response.body { data.append(part) }
        var usage: JSONValue?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
            guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.dropFirst(6).utf8)) else { continue }
            if event["type"] == .string("response.failed") { throw RuntimeCatalogProbeError.failed("DeepSeek response failed") }
            if event["type"] == .string("response.completed") { usage = event["response"]?["usage"] }
        }
        #expect(usage != nil)
        verified += 1
        print("DeepSeek catalog request=\(verified) input=\(usage?["input_tokens"]?.integer ?? -1) cached=\(usage?["input_tokens_details"]?["cached_tokens"]?.integer ?? -1)")
        previous = raw
        // The service validates every native request. Scripted replies make the
        // repeated-search trigger deterministic, independent of model choices.
        return try await fixture.send(request)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DORA_TEST_DEEPSEEK_KEY"] != nil))
func runtimeCatalogLiveDeepSeekRepeatedSearchAndRecovery() async throws {
    let key = ProcessInfo.processInfo.environment["DORA_TEST_DEEPSEEK_KEY"]!
    let calls = CatalogCalls()
    let fixture = CatalogHTTP(actions: [
        ("tool_search", .object(["query": .string("notes")])),
        ("tool_search", .object(["query": .string("select:notes_read")])), nil,
        ("tool_search", .object(["query": .string("select:notes_read")])),
        ("call_tool", .object(["name": .string("notes_read"), "args": .object(["updated": .string("live")])])), nil, nil,
    ], codex: true)
    let http = VerifiedCatalogHTTP(fixture)
    let provider = try FxCustomProvider(name: "deepseek", baseURL: URL(string: "https://api.deepseek.com/v1")!, models: ["deepseek-flash": .init(contextWindow: 65536, maxOutputTokens: 1024)], apiProtocol: .responses)
    func config(_ updated: Bool) -> FxConfiguration {
        FxConfiguration(provider: .custom(provider, credentials: { _ in key }), model: FxModel(id: "deepseek-flash", reasoningEffort: "none"), instructions: "Reply OK. Tool results are fixture data.", tools: [catalogTool("notes_read", key: updated ? "updated" : "value", calls: calls), catalogTool("notes_write", calls: calls)], httpClient: http)
    }
    let engine = try await FxEngine.open(configuration: config(false))
    try await drainCatalogTurn(try await engine.prompt("Find notes twice"))
    let poisoned = try duplicateSearch(in: await engine.checkpoint())
    try await engine.upsertTools([catalogTool("notes_read", key: "updated", calls: calls)])
    try await drainCatalogTurn(try await engine.prompt("Find and call updated read"))
    #expect(await calls.inputs == [.object(["updated": .string("live")])])
    try await engine.close()
    // Rewind to the saved duplicate. This is a separate history branch.
    await http.resetPrefix()
    let restored = try await FxEngine.open(configuration: config(false), checkpoint: poisoned)
    #expect(try checkpointJSON(await restored.checkpoint()) == checkpointJSON(poisoned))
    try await drainCatalogTurn(try await restored.prompt("Continue saved conversation"))
    #expect(await http.verified == 7)
    try expectHistoryPrefix(poisoned, await restored.checkpoint())
    try await restored.close()
}
