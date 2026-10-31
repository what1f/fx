import Foundation
import Testing
@testable import LibFx

private actor ContractHTTP: FxHTTPClient {
    private let names: [String]
    private var posts = 0
    private(set) var results: [JSONValue] = []
    init(names: [String]) { self.names = names }

    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        let payload: String
        if request.httpMethod == "GET" {
            payload = #"{"data":[{"id":"swift/tool-contract","type":"language","tags":["tool-use"]}]}"#
        } else {
            posts += 1
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            if case .array(let messages) = body["prompt"] {
                results = messages.flatMap { message -> [JSONValue] in
                    guard case .array(let content) = message["content"] else { return [] }
                    return content.filter { $0["type"] == .string("tool-result") }
                }
            }
            var events: [JSONValue] = []
            if posts == 1 {
                events = names.enumerated().map { index, name in .object([
                    "type": .string("tool-call"), "toolCallId": .string("call-\(index)"),
                    "toolName": .string(name), "input": .object([:]),
                ]) }
            }
            events.append(.object(["type": .string("finish"), "finishReason": .object([
                "unified": .string(posts == 1 ? "tool-calls" : "stop"), "raw": .string(posts == 1 ? "tool-calls" : "stop"),
            ])]))
            payload = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(payload.utf8)); $0.finish() })
    }
}

private actor ContractCalls {
    private(set) var events: [String] = []
    private(set) var contexts: [String: FxToolContext] = [:]
    private var readers: [CheckedContinuation<Void, Never>] = []

    func execute(_ name: String, context: FxToolContext) async -> FxToolResult {
        events.append("start:\(name)")
        contexts[name] = context
        if name == "first" || name == "second" {
            // Neither reader can finish until both have actually entered.
            await withCheckedContinuation { waiter in
                readers.append(waiter)
                if readers.count == 2 {
                    for reader in readers { reader.resume() }
                    readers.removeAll()
                }
            }
        }
        events.append("end:\(name)")
        return FxToolResult(text: "\(name) ok")
    }
}

// The core admits at most 64 live engines per process. Serialize fixture
// creation while keeping each engine's tool calls genuinely concurrent.
@Suite(.serialized) struct ToolContractTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func nativeToolAdmissionHonorsReadOverlapAndWriterBarriers(idempotentWriter: Bool) async throws {
        let names = ["first", "second", "save", "after"], calls = ContractCalls()
        let tools = names.map { name in
            FxTool(name: name, description: "Contract probe", inputSchema: .object(["type": .string("object")]),
                isIdempotent: name == "save" ? idempotentWriter : name != "second",
                writes: name == "second" ? false : name == "save" && idempotentWriter ? true : nil) { _, context in
                    await calls.execute(name, context: context)
                }
        }
        let http = ContractHTTP(names: names)
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "swift/tool-contract", tools: tools, httpClient: http))
        let turn = try await engine.prompt("tool contract", id: "public-turn")
        #expect(try await turn.result.stopReason == .endTurn)
        try await engine.close()
        let events = await calls.events
        #expect(Set(events.prefix(2)) == ["start:first", "start:second"])
        #expect(Set(events.dropFirst(2).prefix(2)) == ["end:first", "end:second"])
        #expect(Array(events.suffix(4)) == ["start:save", "end:save", "start:after", "end:after"])
        let contexts = await calls.contexts
        for (index, name) in names.enumerated() {
            #expect(contexts[name]?.executionID == "call-\(index)")
            #expect(contexts[name]?.turnID == "public-turn")
            #expect(contexts[name]?.sessionID == engine.sessionID)
        }
        #expect(await http.results.compactMap { $0["toolName"]?.string } == names)
    }

    private struct ContractFailure: Error, CustomStringConvertible {
        let description: String
    }

    private struct LocalizedContractFailure: LocalizedError {
        let errorDescription: String?
    }

    private enum FailureMode: CaseIterable, Sendable { case returned, described, localized }

    @Test(arguments: FailureMode.allCases, ["", "host failure"])
    private func nativeToolFailureTextReachesTheModel(mode: FailureMode, message: String) async throws {
        let http = ContractHTTP(names: ["broken"])
        let tool = FxTool(name: "broken", description: "Failure probe", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            if mode == .described { throw ContractFailure(description: message) }
            if mode == .localized { throw LocalizedContractFailure(errorDescription: message) }
            return FxToolResult(text: message, isError: true)
        }
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "fixture", model: "swift/tool-contract", tools: [tool], httpClient: http))
        let turn = try await engine.prompt("failure contract")
        #expect(try await turn.result.stopReason == .endTurn)
        try await engine.close()
        let results = await http.results
        #expect(results.count == 1)
        let output = try #require(results.first?["output"])
        #expect(output["type"] == .string("error-text"))
        #expect(output["value"] == .string(message.isEmpty ? "Tool broken failed without a message" : message))
    }
}
