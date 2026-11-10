import Foundation
import Testing
@testable import LibFx

@Test(arguments: [-1, 0, 1])
func toolInputDisplayHonorsTheExactByteBoundary(extra: Int) throws {
    let input = JSONValue.object(["v": .string(String(repeating: "x", count: 64 * 1024 - 8 + extra))])
    let display = try FxToolInput.display(input)
    if extra <= 0 { #expect(display == .complete(input)) }
    else {
        guard case .truncated(let preview) = display else { Issue.record("Expected a bounded preview"); return }
        #expect(preview.utf8.count == 64 * 1024)
        #expect(preview.hasPrefix("{\"v\":\""))
    }
    #expect(try FxToolInput.display(nil) == nil)
    #expect(try FxToolInput.display(.null) == nil)
}

@Test(arguments: ["中", "😀"])
func toolInputPreviewPreservesUTF8AndCanonicalOrder(character: String) throws {
    let content = String(repeating: character, count: 40 * 1024)
    let input = JSONValue.object(["z": .string("last"), "a": .string(content)])
    guard case .truncated(let preview) = try FxToolInput.display(input) else { Issue.record("Expected a preview"); return }
    #expect(preview.utf8.count <= 64 * 1024)
    #expect(preview.utf8.count >= 64 * 1024 - 3)
    #expect(("{\"a\":\"" + content + "\",\"z\":\"last\"}").hasPrefix(preview))
    #expect(!preview.contains("�"))
}

@Test func toolStartEventRecordsKeepTheirInputShapeAndBoundPreviews() throws {
    let data = Data(#"{"toolStarted":{"id":"call","name":"probe","input":{"v":"ok"}}}"#.utf8)
    let event = try JSONDecoder().decode(FxEvent.self, from: data)
    #expect(event == .toolStarted(id: "call", name: "probe", input: .complete(.object(["v": .string("ok")]))))
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event))
    #expect(encoded["toolStarted"]?["input"] == .object(["v": .string("ok")]))
    let preview = FxEvent.toolStarted(id: "call", name: "probe", input: .truncated(preview: "{\"v\":\""))
    #expect(try JSONDecoder().decode(FxEvent.self, from: JSONEncoder().encode(preview)) == preview)
    #expect(throws: EncodingError.self) {
        try JSONEncoder().encode(FxEvent.toolStarted(id: "call", name: "probe", input: .truncated(preview: String(repeating: "x", count: 64 * 1024 + 1))))
    }
    for fields in [
        JSONValue.object(["input": .object([:]), "inputPreview": .string("preview")]),
        .object(["inputPreview": .string(String(repeating: "x", count: 64 * 1024 + 1))]),
    ] {
        guard case .object(var fields) = fields else { continue }
        fields["id"] = .string("call"); fields["name"] = .string("probe")
        let bytes = try JSONEncoder().encode(JSONValue.object(["toolStarted": .object(fields)]))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FxEvent.self, from: bytes) }
    }
}

private actor ToolInputHTTP: FxHTTPClient {
    let input: JSONValue
    private var posts = 0
    init(input: JSONValue) { self.input = input }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let payload: String
        if request.httpMethod == "GET" {
            payload = #"{"data":[{"id":"swift/tool-input","type":"language","tags":["tool-use"]}]}"#
        } else {
            posts += 1
            let events: [JSONValue]
            if posts == 1 {
                events = [
                    .object(["type": .string("tool-call"), "toolCallId": .string("call"), "toolName": .string("probe"), "input": input]),
                    .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])]),
                ]
            } else {
                events = [
                    .object(["type": .string("text-delta"), "delta": .string("complete")]),
                    .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])]),
                ]
            }
            payload = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(payload.utf8)); $0.finish() })
    }
}

private actor ToolArguments {
    private(set) var values: [JSONValue] = []
    func append(_ value: JSONValue) { values.append(value) }
}

@Test func boundedToolEventsLeaveExecutorArgumentsComplete() async throws {
    let input = JSONValue.object(["path": .string("/tmp/example.txt"), "content": .string(String(repeating: "x", count: 128 * 1024))])
    let calls = ToolArguments()
    let tool = FxTool(name: "probe", description: "Probe", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { input, _ in
        await calls.append(input)
        return "received"
    }
    let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test", model: "swift/tool-input", tools: [tool], httpClient: ToolInputHTTP(input: input)))
    let turn = try await engine.prompt("probe")
    var starts: [FxToolInput] = []
    for try await event in turn {
        if case .toolStarted(_, "probe", let input) = event, let input { starts.append(input) }
    }
    #expect(try await turn.result.stopReason == .endTurn)
    try await engine.close()
    #expect(await calls.values == [input])
    #expect(starts.count == 1)
    guard case .truncated(let preview) = try #require(starts.first) else { Issue.record("Expected a preview"); return }
    #expect(preview.utf8.count == 64 * 1024)
    #expect(preview.hasPrefix("{\"content\":\""))
}

@Test func toolInputVariantsSurviveSessionStoreReopen() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let events: [FxSessionEvent] = [
        .update(id: "turn", .toolStarted(id: "small", name: "probe", input: .complete(.object(["v": .string("ok")])))),
        .update(id: "turn", .toolStarted(id: "large", name: "probe", input: .truncated(preview: String(repeating: "x", count: 64 * 1024)))),
    ]
    let store = try FxSessionStore(url: url)
    _ = try await store.accept(session: "session", agent: "agent", id: "turn", content: [.text("probe")], options: .init())
    let lease = try #require(try await store.claim(session: "session", agent: "agent"))
    for event in events { try await store.appendEvent(lease, event) }
    try await store.release(lease)
    try await store.close()
    let reopened = try FxSessionStore(url: url)
    #expect(try await reopened.entries(session: "session", agent: "agent", after: 0).map(\.event) == events)
    try await reopened.close()
}
