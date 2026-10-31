import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private actor ProviderToolHTTP: FxHTTPClient {
    enum Failure: Error { case missingAdvertisement, missingHistory }
    private(set) var requests: [JSONValue] = []
    private(set) var catalogRequests = 0

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let payload: String
        if request.httpMethod == "GET" {
            catalogRequests += 1
            payload = #"{"data":[{"id":"swift/provider-tools","type":"language","tags":["tool-use"]}]}"#
        } else {
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            requests.append(body)
            guard case .array(let tools) = body["tools"],
                  let tool = tools.first(where: { $0["type"] == .string("provider") }),
                  let name = tool["name"]?.string else { throw Failure.missingAdvertisement }
            var events: [JSONValue] = []
            if requests.count == 1 {
                events += [
                    .object(["type": .string("tool-input-start"), "id": .string("search-1"), "toolName": .string(name)]),
                    .object(["type": .string("tool-call"), "toolCallId": .string("search-1"), "toolName": .string(name),
                             "input": .object(["query": .string("Swift SDK")]), "providerExecuted": .bool(true)]),
                    .object(["type": .string("tool-result"), "toolCallId": .string("search-1"),
                             "result": .object(["source": .string("saved-provider-result")])]),
                ]
            } else if !String(decoding: try JSONEncoder().encode(body), as: UTF8.self).contains("saved-provider-result") {
                throw Failure.missingHistory
            }
            events += [
                .object(["type": .string("text-delta"), "delta": .string(requests.count == 1 ? "searched" : "restored")]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])]),
            ]
            payload = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(payload.utf8)); $0.finish() })
    }
}

@Test(arguments: [false, true])
func providerSearchResultsSurviveRestore(useJournal: Bool) async throws {
    let http = ProviderToolHTTP(), store = FxMemoryPersistence()
    let configuration = FxConfiguration(apiKey: "test-key", model: "swift/provider-tools", providerTools: [.webSearch], httpClient: http)
    let engine = try await FxEngine.open(configuration: configuration, persistence: useJournal ? store : nil)
    let turn = try await engine.prompt("search")
    var events: [FxEvent] = []
    for try await event in turn { events.append(event) }
    #expect(try await turn.result.stopReason == .endTurn)
    #expect(events.contains { if case .toolStarted(_, "web_search", _) = $0 { return true }; return false })
    #expect(events.contains {
        if case .toolFinished(_, "web_search", let content, false) = $0 { return content?.contains("saved-provider-result") == true }
        return false
    })
    #expect(events.contains(.text("searched")))
    let checkpoint = useJournal ? nil : try await engine.checkpoint()
    try await engine.close()
    let restored = try await FxEngine.open(configuration: configuration, checkpoint: checkpoint, persistence: useJournal ? store : nil)
    let next = try await restored.prompt("use the saved search")
    var text = ""
    for try await event in next { if case .text(let delta) = event { text += delta } }
    #expect(try await next.result.stopReason == .endTurn)
    #expect(text == "restored")
    #expect(await http.requests.count == 2)
    try await restored.close()
}

@Test(arguments: [false, true])
func providerToolNamesCannotCollide(withHost: Bool) async throws {
    let http = ProviderToolHTTP()
    let host = FxTool(name: "web_search", description: "host search", inputSchema: .object([:]), isIdempotent: true) { _, _ in
        Issue.record("A colliding tool ran")
        return FxToolResult("unexpected")
    }
    let configuration = FxConfiguration(apiKey: "test-key", model: "swift/provider-tools",
        tools: withHost ? [host] : [], providerTools: withHost ? [.webSearch] : [.webSearch, .webSearch], httpClient: http)
    do {
        let engine = try await FxEngine.open(configuration: configuration)
        try await engine.close()
        Issue.record("Duplicate tool names were accepted")
    } catch FxError.invalidInput {}
    #expect(await http.requests.isEmpty)
    #expect(await http.catalogRequests == 0)
}

@Test func providerToolsParticipateInCheckpointIdentity() throws {
    var configuration = FxConfiguration(apiKey: "test-key", model: "swift/provider-tools")
    let without = try CheckpointMetadata(configuration: configuration)
    configuration.providerTools = [.webSearch]
    let withSearch = try CheckpointMetadata(configuration: configuration)
    #expect(withSearch.value["toolSchemaHash"] != without.value["toolSchemaHash"])
}
