import Foundation
import LibFx

enum RuntimeCatalogProbeError: Error { case failed(String) }
private func probeFailure(_ message: String) -> RuntimeCatalogProbeError {
    print("Catalog probe violation: \(message)")
    return .failed(message)
}

private actor RuntimeProbeCalls {
    var values: [JSONValue] = []
    func record(_ value: JSONValue) { values.append(value) }
}

// Extract the exact wire bytes, without re-encoding JSON objects.
func catalogRawArray(_ key: String, in data: Data) throws -> Data {
    let bytes = Array(data)
    let marker = Array("\"\(key)\":[".utf8)
    var level = 0, inString = false, escape = false
    var found: Int?
    for index in bytes.indices {
        let byte = bytes[index]
        if inString {
            if escape { escape = false } else if byte == 92 { escape = true } else if byte == 34 { inString = false }
        } else {
            if level == 1 && index + marker.count <= bytes.count && Array(bytes[index..<(index + marker.count)]) == marker { found = index; break }
            if byte == 34 { inString = true }
            else if byte == 91 || byte == 123 { level += 1 }
            else if byte == 93 || byte == 125 { level -= 1 }
        }
    }
    guard let start = found else { throw probeFailure("Missing raw array: \(key)") }
    let begin = start + marker.count - 1
    var depth = 0, quoted = false, escaped = false
    for index in begin..<bytes.count {
        let byte = bytes[index]
        if quoted {
            if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }
        } else if byte == 34 { quoted = true }
        else if byte == 91 || byte == 123 { depth += 1 }
        else if byte == 93 || byte == 125 {
            depth -= 1
            if depth == 0 { return Data(bytes[begin...index]) }
        }
    }
    throw probeFailure("Unterminated raw array")
}

func catalogDiagnose(_ before: Data, _ after: Data) {
    let a = Array(before), b = Array(after)
    let i = zip(a,b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? min(a.count,b.count)
    print("WIRE DIFF", i, "BEFORE", String(decoding: a[max(0,i-80)..<min(a.count,i+240)], as: UTF8.self), "AFTER", String(decoding: b[max(0,i-80)..<min(b.count,i+240)], as: UTF8.self))
}

private actor ContextAppendProbe {
    var texts: [String] = []
    func receive(_ event: FxLifecycleEvent) {
        if case .contextAppended(let name, let text) = event, name == "preferences" { texts.append(text) }
    }
}

private actor RuntimeProbeHTTP: FxHTTPClient {
    var summaries = 0
    var searches = 0
    var conversations = 0
    var key = "value"
    var removed = false
    var requests: [JSONValue] = []
    var toolBytes: Data?
    var previousFields: [String: JSONValue]?
    var previousMessages: Data?
    func resetPrefix() { previousMessages = nil }
    func update(key: String, removed: Bool = false) {
        self.key = key; self.removed = removed
    }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
        guard case .array(let messages) = body["messages"] else { throw probeFailure("Missing messages") }
        requests.append(body)
        let text = messages.map { message in
            if let value = message["content"]?.string { return value }
            if case .array(let parts) = message["content"] { return parts.compactMap { $0["text"]?.string }.joined(separator: "\n") }
            return ""
        }.joined(separator: "\n")
        let summary = text.contains("Write the compaction notes") || text.contains("Your notes on the turns above")
        let delta: JSONValue
        var reason = "stop"
        if summary {
            if let previousMessages {
                let messages = try catalogRawArray("messages", in: request.httpBody!)
                guard messages.starts(with: previousMessages.dropLast()) else { catalogDiagnose(Data(previousMessages.dropLast()), messages); throw probeFailure("Summary changed the parent history prefix") }
            }
            if case .object(var fields) = body {
                fields.removeValue(forKey: "messages")
                if let previousFields, fields != previousFields { throw probeFailure("Summary changed parent configuration or tools") }
            }
            previousMessages = nil
            summaries += 1
            let headings = text.split(separator: "\n").filter { $0.hasPrefix("Turn ") && $0.contains(" (") }
            let notes = headings.map { "\($0)\nIn between: catalog probe used the action." }.joined(separator: "\n\n")
                + "\n\nFacts:\nnone\nRules:\nnone\nDecisions:\nnone\nStatus:\nnone\nOpen:\nnone"
            delta = .object(["role": .string("assistant"), "content": .string(notes)])
        } else {
            if summaries > 0 {
                guard text.contains("Available actions (current catalog") else { throw probeFailure("Catalog missing after compaction") }
                guard text.contains("Preference marker") else { throw probeFailure("Named context missing after compaction") }
            }
            let rawTools = try catalogRawArray("tools", in: request.httpBody!)
            if let toolBytes, toolBytes != rawTools { throw probeFailure("Tool bytes changed") }
            toolBytes = rawTools
            let rawMessages = try catalogRawArray("messages", in: request.httpBody!)
            if let previousMessages {
                guard rawMessages.starts(with: previousMessages.dropLast()) else { catalogDiagnose(Data(previousMessages.dropLast()), rawMessages); throw probeFailure("Prior message bytes changed") }
            }
            previousMessages = rawMessages
            if case .object(var fields) = body { fields.removeValue(forKey: "messages"); previousFields = fields }
            conversations += 1
            let lastRole = messages.last?["role"]?.string
            let afterSearch: Bool
            if lastRole == "tool", case .array(let calls) = messages.dropLast().last?["tool_calls"] {
                afterSearch = calls.last?["function"]?["name"] == .string("tool_search")
            } else { afterSearch = false }
            if lastRole == "user" || afterSearch {
                let name = afterSearch || removed ? "call_action" : "tool_search"
                if afterSearch && !removed {
                    guard text.contains("\"required\":[\"\(key)\"]") else { throw probeFailure("Search omitted current definition") }
                }
                if name == "tool_search" { searches += 1 }
                let args: JSONValue = name == "tool_search"
                    ? .object(["query": .string("select:probe_action")])
                    : .object(["name": .string("probe_action"), "args": .object([key: .string("current")])])
                let arguments = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
                delta = .object(["role": .string("assistant"), "tool_calls": .array([.object([
                    "index": .number(0), "id": .string("probe-\(conversations)"), "type": .string("function"),
                    "function": .object(["name": .string(name), "arguments": .string(arguments)])])])])
                reason = "tool_calls"
            } else {
                delta = .object(["role": .string("assistant"), "content": .string(String(repeating: "fixturedata ", count: 300))])
            }
        }
        let chunk: JSONValue = .object(["choices": .array([.object(["index": .number(0), "delta": delta, "finish_reason": .null])])])
        let encoded = String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self)
        let stream = "data: \(encoded)\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(reason)\"}]}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(stream.utf8)); $0.finish() })
    }
}

/// Runs through the public SDK, including the native core and SQLite store.
func runRuntimeCatalogProbe() async throws -> Int {
    func require(_ value: Bool, _ message: String) throws { if !value { throw probeFailure(message) } }
    func prompt(_ engine: FxEngine) async throws {
        let turn = try await engine.prompt("Use probe_action with the current definition.")
        for try await _ in turn {}
        try require(try await turn.result.stopReason == .endTurn, "Turn failed")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-catalog-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("session.sqlite")
    let calls = RuntimeProbeCalls()
    let http = RuntimeProbeHTTP()
    let provider = try FxCustomProvider(name: "runtimefixture", baseURL: URL(string: "https://runtime.example/v1")!,
        models: ["small": .init(contextWindow: 65536, maxOutputTokens: 1024)])
    func tool(_ key: String) -> FxTool {
        FxTool(name: "probe_action", description: "Probe action", inputSchema: .object([
            "type": .string("object"), "properties": .object([key: .object(["type": .string("string")])]),
            "required": .array([.string(key)]), "additionalProperties": .bool(false),
        ]), isIdempotent: true, deferred: true) { input, _ in await calls.record(input); return "called" }
    }
    func config(_ tools: [FxTool]) -> FxConfiguration {
        var configuration = FxConfiguration(provider: .custom(provider), model: "small", tools: [FxTool(name: "resident", description: "Always available", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in "resident" }] + tools, workspace: directory,
            httpClient: http, checkpointAfterBytes: nil)
        configuration.toolSearchEnabled = true
        // Trigger before capacity is tight, matching hosts that reserve room
        // for the cache-preserving summary fork.
        configuration.autoCompaction = .tokens(5000)
        return configuration
    }
    let notices = ContextAppendProbe()
    let store = try FxSQLitePersistence(url: database)
    var observed = config([tool("value")])
    observed.onLifecycleEvent = { await notices.receive($0) }
    let engine = try await FxEngine.open(configuration: observed, persistence: store)
    do {
        try await engine.setContext(name: "preferences", text: "Preference marker: concise answers.")
        try require(await notices.texts.count == 1, "Missing initial context notification")
        let beforeDuplicate = try await engine.checkpoint()
        try await engine.setContext(name: "preferences", text: "Preference marker: concise answers.")
        try require(await notices.texts.count == 1, "Duplicate context notification")
        try require(try await engine.checkpoint() == beforeDuplicate, "Unchanged context appended twice")
        for _ in 0..<16 { try await prompt(engine); if await http.summaries > 0 { break } }
        try require(await http.summaries > 0, "Automatic compaction never ran")
        try require(await notices.texts.count > 1, "Compaction did not notify reinjected context")
        try require(await notices.texts.allSatisfy { $0 == "<system-reminder>\nPreference marker: concise answers.\n</system-reminder>" }, "Context notification differs from model text")
        try await engine.flushPersistence()
        let persisted = try await store.load()
        let replacements = try persisted.journal.flatMap { record -> [JSONValue] in
            let data = try JSONDecoder().decode(JSONValue.self, from: record.data)
            if case .array(let events) = data["events"] { return events.filter { $0["type"] == .string("history_replaced") } }
            return []
        }
        try require(replacements.contains { event in
            guard case .array(let history) = event["data"] else { return false }
            return history.contains { $0["kind"] == .string("compacted_summary") && $0["host_state_json"]?.string?.contains("probe_action") == true }
        }, "No compacted activation state in journal")
        try await prompt(engine)

        try await engine.upsertTools([tool("updated")])
        await http.update(key: "updated")
        try await prompt(engine)
        try require(await calls.values.last == .object(["updated": .string("current")]), "Updated schema did not execute")
        try await engine.setContext(name: "preferences", text: "Preference marker: concise answers.")
        let checkpoint = try await engine.checkpoint()
        try require(String(decoding: checkpoint, as: UTF8.self).contains("Preference marker"), "Context missing from checkpoint")
        try require(String(decoding: checkpoint, as: UTF8.self).contains("host_state_json"), "Compaction activation state missing")
        try await engine.close()
        try await store.close()
        let reopenedStore = try FxSQLitePersistence(url: database)
        let reopened = try await FxEngine.open(configuration: config([tool("updated")]), persistence: reopenedStore)
        try await prompt(reopened)
        try require(String(describing: await http.requests.last).contains("Preference marker"), "Context missing after immediate close and reopen")
        try await reopened.removeTools(named: ["probe_action"])
        await http.update(key: "updated", removed: true)
        let count = await calls.values.count
        try await prompt(reopened)
        try require(await calls.values.count == count, "Deleted closure executed")
        let removedCheckpoint = try await reopened.checkpoint()
        try await reopened.close()
        try await reopenedStore.close()
        await http.resetPrefix()
        let restored = try await FxEngine.open(configuration: config([tool("updated")]), checkpoint: checkpoint)
        try await prompt(restored)
        try require(await calls.values.count == count + 1, "Checkpoint did not restore current action")
        try await restored.close()
        await http.resetPrefix()
        let deleted = try await FxEngine.open(configuration: config([]), checkpoint: removedCheckpoint)
        try await prompt(deleted)
        try require(await calls.values.count == count + 1, "Deleted checkpoint action executed")
        try await deleted.close()
        await http.resetPrefix()
        let deletedStore = try FxSQLitePersistence(url: database)
        let deletedJournal = try await FxEngine.open(configuration: config([]), persistence: deletedStore)
        try await prompt(deletedJournal)
        try require(await calls.values.count == count + 1, "Deleted journal action executed")
        try await deletedJournal.close()
        try await deletedStore.close()
        try require(await http.searches > 1, "Definitions were not fetched on demand")
        return await http.summaries
    } catch {
        print("Catalog probe failure: summaries=\(await http.summaries), conversations=\(await http.conversations)")
        try? await engine.close(); try? await store.close(); throw error
    }
}
