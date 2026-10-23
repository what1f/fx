import Foundation
import FxAgentKit

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func log(_ line: String) { print(line); fflush(nil) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw Failure(message) }
}

// Records numeric usage only. Never records requests, headers, or credentials.
actor Meter {
    struct Record { let summary: Bool; var usage: [String: Int] = [:] }
    var records: [Record] = []
    func begin(summary: Bool) -> Int {
        records.append(Record(summary: summary)); return records.count - 1
    }
    func line(_ line: String, request: Int) {
        guard line.hasPrefix("data: "), let bytes = line.dropFirst(6).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        let response = object["response"] as? [String: Any]
        let message = object["message"] as? [String: Any]
        guard let usage = (response?["usage"] ?? message?["usage"] ?? object["usage"]) as? [String: Any] else { return }
        func collect(_ value: [String: Any], _ prefix: String = "") {
            for (key, field) in value {
                if let nested = field as? [String: Any] { collect(nested, prefix + key + ".") }
                else if let number = field as? Int { records[request].usage[prefix + key] = number }
            }
        }
        collect(usage)
    }
    var summaries: Int { records.filter(\.summary).count }
    func report() throws {
        for (index, record) in records.enumerated() {
            let fields = record.usage.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            log("request=\(index + 1) kind=\(record.summary ? "compaction" : "conversation") \(fields.isEmpty ? "usage=not-returned" : fields)")
        }
        let hits = records.dropFirst().filter { $0.usage.contains { ($0.key.contains("cached_tokens") || $0.key.contains("cache_read") || $0.key.contains("cache_hit")) && $0.value > 0 } }.count
        log("cache_hit_requests_after_first=\(hits)")
        try require(!records.isEmpty && records.allSatisfy { !$0.usage.isEmpty }, "Missing request usage")
        if records.contains(where: { $0.usage.keys.contains { $0.contains("cached_tokens") || $0.contains("cache_read") || $0.contains("cache_hit") } }) {
            try require(hits > 0, "Provider reported cache counters but no cache hits")
        } else { log("cache_information=not-returned") }
    }
}
actor BodyReader {
    var iterator: AsyncThrowingStream<Data, any Error>.Iterator
    let meter: Meter
    let request: Int
    var pending = Data()
    init(_ body: AsyncThrowingStream<Data, any Error>, meter: Meter, request: Int) {
        iterator = body.makeAsyncIterator(); self.meter = meter; self.request = request
    }
    func next() async throws -> Data? {
        var current = iterator
        let data = try await current.next(isolation: self)
        iterator = current
        if let data {
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                await meter.line(line, request: request)
            }
        }
        return data
    }
}
struct MeasuredHTTP: FxHTTPClient {
    let meter: Meter
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let summary = text.contains("Write the compaction notes") || text.contains("Your notes on the turns above")
        let index = await meter.begin(summary: summary)
        let response = try await FxURLSessionHTTPClient().send(request)
        if response.statusCode >= 400 {
            defer { response.cancel() }
            var data = Data()
            for try await chunk in response.body {
                guard data.count + chunk.count <= 65536 else { throw Failure("Provider error exceeded limit") }
                data.append(chunk)
            }
            var diagnostic = data
            if let object = try? JSONSerialization.jsonObject(with: data),
               let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) {
                diagnostic = normalized
            }
            var safe = String(decoding: diagnostic, as: UTF8.self)
            for header in ["Authorization", "x-api-key"] {
                if let credential = request.value(forHTTPHeaderField: header) {
                    let key = credential.hasPrefix("Bearer ") ? String(credential.dropFirst(7)) : credential
                    safe = safe.replacingOccurrences(of: key, with: "[REDACTED]")
                    if let encoded = try? JSONEncoder().encode(key) {
                        safe = safe.replacingOccurrences(of: String(String(decoding: encoded, as: UTF8.self).dropFirst().dropLast()), with: "[REDACTED]")
                    }
                }
            }
            log("provider_status=\(response.statusCode) error=\(safe)")
            return FxHTTPResponse(statusCode: response.statusCode, body: AsyncThrowingStream { $0.yield(data); $0.finish() })
        }
        let reader = BodyReader(response.body, meter: meter, request: index)
        return FxHTTPResponse(statusCode: response.statusCode, headers: response.headers,
                              body: AsyncThrowingStream(unfolding: { try await reader.next() }), cancel: { response.cancel() })
    }
}
actor State {
    var allow = false
    var decisions: [Bool] = []
    var calls: [String] = []
    func decide() -> FxToolApproval.Decision { decisions.append(allow); return allow ? .allowOnce : .deny }
    func permit() { allow = true }
    func call(_ name: String) { calls.append(name) }
}

@main struct Acceptance {
    static func main() async {
        let key = (ProcessInfo.processInfo.environment["DORA_TEST_DEEPSEEK_KEY"] ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]) ?? ""
        do {
            try require(!key.isEmpty, "Set DORA_TEST_DEEPSEEK_KEY in the process environment")
            let kind = CommandLine.arguments.dropFirst().first ?? "responses"
            let api: FxCustomProvider.APIProtocol = kind == "messages" ? .anthropicMessages : kind == "chat" ? .chatCompletions : .responses
            let base = kind == "messages" ? "https://api.deepseek.com/anthropic/v1" : "https://api.deepseek.com/v1"
            let provider = try FxCustomProvider(name: "deepseek", baseURL: URL(string: base)!, models: ["deepseek-flash": .init(contextWindow: 32768, maxOutputTokens: 16384, supportsToolUse: true)], apiProtocol: api, deferredToolMode: kind == "messages" ? .callAction : .native)
            let state = State(), meter = Meter()
            let approval = FxToolApproval(onApproval: { _ in await state.decide() })
            func tool(_ name: String, value: String, write: Bool = false) -> FxTool {
                let original = FxTool(name: name, description: "Return the secret test code for \(name). Must call to get the code.", inputSchema: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]), isIdempotent: !write, writes: write, deferred: true) { _, _ in
                    await state.call(name + ":" + value); return FxToolResult(text: value)
                }
                return approval.wrap(tool: original, pluginID: "acceptance", effect: write ? .dangerous : .readOnly)
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fx-live-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var config = FxConfiguration(provider: .custom(provider, credentials: { _ in key }), model: "deepseek-flash", instructions: "You are a test assistant. Keep replies under 30 words. Use tool_search to discover deferred tools by exact name with query select:NAME. Call the discovered tool by its native name, or call_action where offered. Do not invent tool results. Never retry a rejected tool unless the next user message explicitly requests it.", tools: [tool("echo_code", value: "ALPHA-42"), tool("save_note", value: "SAVED-73", write: true)], workspace: directory, httpClient: MeasuredHTTP(meter: meter), checkpointAfterBytes: nil)
            config.toolSearchEnabled = true
            let database = directory.appendingPathComponent("conversation.sqlite")
            let agent = try await Agent.open(configuration: config, persistenceURL: database, approval: approval, builtInTools: [])
            var textEvents = 0, reasoningEvents = 0, toolStarts = 0, toolFinishes = 0
            func prompt(_ text: String) async throws -> String {
                let turn = try await agent.prompt(text)
                var reply = ""
                for try await event in turn {
                    switch event {
                    case .text(let value): textEvents += 1; reply += value
                    case .reasoning: reasoningEvents += 1
                    case .toolStarted(_, let name, _): toolStarts += 1; log("tool_started=\(name)")
                    case .toolFinished(_, let name, _, let error): toolFinishes += 1; log("tool_finished=\(name) error=\(error)")
                    default: break
                    }
                }
                let result = try await turn.result
                try require(result.stopReason == .endTurn, "Turn failed: \(result.stopReason) \(String(describing: result.failure))")
                log("turn_completed input=\(result.usage.inputTokens ?? -1) output=\(result.usage.outputTokens ?? -1) cached=\(result.usage.cacheReadTokens ?? -1)")
                return reply
            }
            do {
                _ = try await prompt("Remember the conversation marker MARIGOLD-81. Reply OK.")
                try require(try await prompt("What is our conversation marker?").contains("MARIGOLD-81"), "Multi-turn recall failed")
                _ = try await prompt("Search for echo_code, then call it. Report its code.")
                try require(await state.calls.contains("echo_code:ALPHA-42"), "Deferred tool did not execute")
                _ = try await prompt("Search for save_note, then call it once. If denied, stop and report denial.")
                try require(await state.decisions == [false], "Expected one denial")
                try require(await !state.calls.contains("save_note:SAVED-73"), "Denied closure executed")
                await state.permit()
                _ = try await prompt("Now explicitly retry save_note once. Report its result.")
                try require(await state.decisions == [false, true], "Expected denial then approval")
                try require(await state.calls.filter { $0 == "save_note:SAVED-73" }.count == 1, "Approved closure count differs")
                try await agent.upsertTools([tool("new_code", value: "BETA-56")])
                _ = try await prompt("Discover new_code with tool_search and call it.")
                try require(await state.calls.contains("new_code:BETA-56"), "Added tool did not execute")
                try await agent.upsertTools([tool("new_code", value: "GAMMA-92")])
                _ = try await prompt("Call new_code again to obtain its current code.")
                try require(await state.calls.contains("new_code:GAMMA-92"), "Updated closure did not execute")
                try await agent.removeTools(named: ["echo_code"])
                let beforeRemovalCheck = await state.calls.filter { $0 == "echo_code:ALPHA-42" }.count
                _ = try await prompt("Search for echo_code again. It was uninstalled. Confirm it is unavailable; do not substitute another tool.")
                try require(await state.calls.filter { $0 == "echo_code:ALPHA-42" }.count == beforeRemovalCheck, "Removed closure executed")
                try await agent.appendContext("The current preference code is VIOLET-39. Remember it through compaction. echo_code was removed.")
                for index in 0..<14 {
                    if await meter.summaries > 0 { break }
                    let padding = (0..<600).map { "record\(index)_\($0)=\(($0 * 7919 + index * 101) % 99991)" }.joined(separator: " ")
                    _ = try await prompt("Keep MARIGOLD-81 and VIOLET-39. Archive batch \(index) below; reply only archived.\n" + padding)
                }
                try require(await meter.summaries > 0, "Automatic compaction did not occur")
                let continued = try await prompt("Give our conversation marker and current preference code. Do not use tools.")
                try require(continued.contains("MARIGOLD-81") && continued.contains("VIOLET-39"), "Post-compaction recall failed")
                _ = try await prompt("Call new_code after compaction to get its current result.")
                try require(await state.calls.filter { $0 == "new_code:GAMMA-92" }.count >= 2, "Post-compaction tool call failed")
                try await agent.close()
                let inspection = try FxSQLitePersistence(url: database)
                let saved = try await inspection.load()
                let replacements = try saved.journal.reduce(0) { count, record in
                    let value = try JSONDecoder().decode(JSONValue.self, from: record.data)
                    guard case .array(let events) = value["events"] else { return count }
                    return count + events.filter { event in
                        guard event["type"] == .string("history_replaced"), case .array(let history) = event["data"] else { return false }
                        return history.contains { $0["kind"] == .string("compacted_summary") && $0["summary"]?.string?.hasPrefix("fx-compactor-v1\n") == true && ($0["removed_turn_count"]?.integer ?? 0) > 0 }
                    }.count
                }
                try await inspection.close()
                try require(replacements > 0, "No persisted compaction replacement")
                log("persisted_compaction_replacements=\(replacements)")
                try require(await meter.summaries > 0, "Missing compaction model request")
                // Reconstruct the current directory, including updated closures, on reopen.
                config.tools = [tool("new_code", value: "GAMMA-92"), tool("save_note", value: "SAVED-73", write: true)]
                let restored = try await Agent.open(configuration: config, persistenceURL: database, approval: approval, builtInTools: [])
                do {
                    let turn = try await restored.prompt("Give the current preference code only.")
                    var reply = ""
                    for try await event in turn { if case .text(let value) = event { reply += value } }
                    try require(try await turn.result.stopReason == .endTurn && reply.contains("VIOLET-39"), "Restore lost appended context")
                    try await restored.close()
                } catch { try? await restored.close(); throw error }
                try require(textEvents > 0 && reasoningEvents > 0 && toolStarts > 0 && toolStarts == toolFinishes, "Missing or unpaired streamed events")
                log("stream_events text=\(textEvents) reasoning=\(reasoningEvents) tool_started=\(toolStarts) tool_finished=\(toolFinishes)")
                try await meter.report()
                log("PASS protocol=\(kind) multi_turn deferred_tools catalog_add_update_remove compaction approval_deny_allow append_context restore close")
            } catch {
                try? await agent.close()
                try? await meter.report()
                throw error
            }
        } catch {
            let safe = String(describing: error).replacingOccurrences(of: key.isEmpty ? "SECRET_NOT_SET" : key, with: "[REDACTED]")
            log("FAIL \(safe)")
            exit(1)
        }
    }
}
