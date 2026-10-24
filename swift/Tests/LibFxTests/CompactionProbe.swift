import Foundation
import LibFx

enum CompactionProbeError: Error {
    case failed(String)
}

/// Uses only public SDK APIs. The consumer smoke copies this file unchanged.
struct CompactionProof: Sendable {
    let summaryRequests: Int
    let conversationRequests: Int
    let replacementRecords: Int
    let beforeBytes: Int
    let afterBytes: Int
    let checkpointBytes: Int
}

private actor CompactionHTTP: FxHTTPClient {
    static let marker = "COMPACTION_PROBE_NOTE"
    static let continuedReply = "Conversation continued"
    private(set) var summaries: [String] = []
    private(set) var conversations: [String] = []

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        guard request.url?.absoluteString == "https://compaction.example/v1/chat/completions",
              let data = request.httpBody else {
            throw CompactionProbeError.failed("Unexpected provider request")
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard value["model"] == .string("small") else {
            throw CompactionProbeError.failed("Compaction changed the configured model")
        }
        guard case .array(let messages) = value["messages"] else {
            throw CompactionProbeError.failed("Missing model messages")
        }
        let text = messages.map { message -> String in
            if let text = message["content"]?.string { return text }
            if case .array(let parts) = message["content"] {
                return parts.compactMap { $0["text"]?.string }.joined(separator: "\n")
            }
            return ""
        }.joined(separator: "\n")
        let isSummary = text.contains("Write the compaction notes") || text.contains("Your notes on the turns above")
        let reply: String
        if isSummary {
            summaries.append(text)
            // Answer the compactor's requested turn headings, not an ordinary user prompt.
            let headings = text.split(separator: "\n").filter {
                $0.hasPrefix("Turn ") && $0.contains(" (")
            }
            reply = headings.map { "\($0)\nIn between: \(Self.marker): looked up the project code." }.joined(separator: "\n\n")
                + "\n\nFacts:\nnone\nRules:\nnone\nDecisions:\nnone\nStatus:\nnone\nOpen:\nnone"
        } else {
            conversations.append(text)
            let continuing = text.contains("PROBE_CONTINUE") || text.contains("PROBE_RESTORE")
            if continuing && !text.contains(Self.marker) {
                throw CompactionProbeError.failed("Continuation request omitted the model's compaction note")
            }
            reply = continuing
                ? Self.continuedReply
                : "Reply \(conversations.count): " + String(repeating: "fixturedata ", count: 300)
        }
        let callTool = !isSummary && messages.last?["role"] != .string("tool")
            && !text.contains("PROBE_CONTINUE") && !text.contains("PROBE_RESTORE")
        let delta: JSONValue = callTool ? .object([
            "role": .string("assistant"),
            "tool_calls": .array([.object([
                "index": .number(0), "id": .string("lookup-\(conversations.count)"), "type": .string("function"),
                "function": .object(["name": .string("fixture_lookup"), "arguments": .string("{}")]),
            ])]),
        ]) : .object(["role": .string("assistant"), "content": .string(reply)])
        let chunk: JSONValue = .object(["choices": .array([.object([
            "index": .number(0), "delta": delta,
            "finish_reason": .null,
        ])])])
        let encoded = String(decoding: try JSONEncoder().encode(chunk), as: UTF8.self)
        let reason = callTool ? "tool_calls" : "stop"
        let response = "data: \(encoded)\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(reason)\"}]}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, headers: ["content-type": "text/event-stream"],
                              body: AsyncThrowingStream { $0.yield(Data(response.utf8)); $0.finish() })
    }
}

func runCompactionProbe(trigger: FxAutoCompaction? = nil) async throws -> CompactionProof {
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CompactionProbeError.failed(message) }
    }
    func prompt(_ engine: FxEngine, _ text: String) async throws -> String {
        let turn = try await engine.prompt(text)
        var reply = ""
        for try await event in turn {
            if case .text(let text) = event { reply += text }
        }
        try require(try await turn.result.stopReason == .endTurn, "Turn did not end normally")
        return reply
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fx-compaction-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("conversation.sqlite")
    let http = CompactionHTTP()
    let store = try FxSQLitePersistence(url: database)
    let provider = try FxCustomProvider(name: "compactionfixture", baseURL: URL(string: "https://compaction.example/v1")!,
                                        models: ["small": .init(contextWindow: 8192, maxOutputTokens: 1024)])
    let lookup = FxTool(name: "fixture_lookup", description: "Look up the project code", inputSchema: .object(["type": .string("object")]),
                        isIdempotent: true) { _, _ in "Project code: alpha42" }
    var config = FxConfiguration(provider: .custom(provider), model: "small", tools: [lookup], workspace: directory, httpClient: http,
                                 checkpointAfterBytes: nil)
    config.autoCompaction = trigger
    let engine = try await FxEngine.open(configuration: config, persistence: store)
    do {
        for index in 1...16 {
            _ = try await prompt(engine, "Turn \(index). Remember the project code alpha42. Give the next fixture reply.")
            if await !http.summaries.isEmpty { break }
        }
        let summaries = await http.summaries
        try require(!summaries.isEmpty, "Automatic compaction never called the model")
        let requests = await http.conversations
        try require(requests.count > 1, "Compaction did not follow a conversation")
        let snapshot = try await store.load()
        try require(snapshot.checkpoint == nil, "Automatic journal snapshots should be disabled")
        let replacementRecords = try snapshot.journal.flatMap { record -> [JSONValue] in
            let value = try JSONDecoder().decode(JSONValue.self, from: record.data)
            guard case .array(let events) = value["events"] else {
                throw CompactionProbeError.failed("Journal record has no events")
            }
            return events.filter { $0["type"] == .string("history_replaced") }
        }
        try require(!replacementRecords.isEmpty, "No compacted history was persisted")
        try require(replacementRecords.contains {
            guard case .array(let history) = $0["data"] else { return false }
            return history.contains { turn in
                turn["kind"] == .string("compacted_summary")
                    && turn["summary"]?.string?.hasPrefix("fx-compactor-v1\n") == true
                    && turn["summary"]?.string?.contains(CompactionHTTP.marker) == true
                    && (turn["removed_turn_count"]?.integer ?? 0) > 0
                    && (turn["compaction_count"]?.integer ?? 0) > 0
            }
        }, "Persisted history has no compactor summary")
        let continued = try await prompt(engine, "PROBE_CONTINUE: use the remembered note.")
        try require(continued == CompactionHTTP.continuedReply, "Conversation did not continue")
        let checkpoint = try await engine.checkpoint()
        try require(String(decoding: checkpoint, as: UTF8.self).contains("fx-compactor-v1"), "Checkpoint lost compaction")
        try await engine.close()
        try await store.close()
        let restoredStore = try FxSQLitePersistence(url: database)
        let restored = try await FxEngine.open(configuration: config, persistence: restoredStore)
        do {
            let reply = try await prompt(restored, "PROBE_RESTORE: use the remembered note.")
            try require(reply == CompactionHTTP.continuedReply, "Restored conversation did not continue")
            try await restored.close()
            try await restoredStore.close()
        } catch {
            try? await restored.close()
            try? await restoredStore.close()
            throw error
        }
        let finalRequests = await http.conversations
        try require(finalRequests.last?.contains(CompactionHTTP.marker) == true, "Restore omitted the note")
        try require(await http.summaries.count == summaries.count, "Continuation regenerated the compaction note")
        let afterBytes = requests.last!.utf8.count
        let beforeBytes = requests.dropLast().map { $0.utf8.count }.max() ?? 0
        try require(afterBytes < beforeBytes, "Compaction did not reduce the next model context")
        return CompactionProof(summaryRequests: summaries.count, conversationRequests: finalRequests.count,
                               replacementRecords: replacementRecords.count, beforeBytes: beforeBytes,
                               afterBytes: afterBytes, checkpointBytes: checkpoint.count)
    } catch {
        try? await engine.close()
        try? await store.close()
        throw error
    }
}
