import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private actor RequestRecorder: FxHTTPClient {
    var calls: [JSONValue] = []
    var frames: [JSONValue] = []
    var catalogRequests = 0
    func record(_ frame: JSONValue) { frames.append(frame) }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let payload: String
        if request.httpMethod == "GET" {
            catalogRequests += 1
            payload = #"{"data":[{"id":"swift/vision","type":"language","tags":["vision","tool-use","reasoning"],"reasoning_options":[{"type":"effort","values":["low","high"]}],"fast_options":[{"type":"toggle"}]}]}"#
        } else {
            calls.append(try JSONDecoder().decode(JSONValue.self, from: request.httpBody!))
            payload = "data: {\"type\":\"text-delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(payload.utf8)); continuation.finish()
        })
    }
}

@Test func modelOptionsReachProviderAndValidateCapabilities() async throws {
    let recorder = RequestRecorder()
    let engine = try await FxEngine.open(configuration: FxConfiguration(
        apiKey: "test-key", model: FxModel(id: "swift/vision", reasoningEffort: "high", fast: true), httpClient: recorder
    ))
    let turn = try await engine.prompt("hello")
    for try await _ in turn {}
    #expect(try await turn.result.stopReason == .endTurn)
    let requests = await recorder.calls
    #expect(requests.count == 1)
    #expect(requests[0]["reasoning"] == .string("high"))
    #expect(requests[0]["providerOptions"]?["gateway"]?["speed"] == .string("fast"))
    try await engine.close()
    do {
        let invalid = try await FxEngine.open(configuration: FxConfiguration(
            apiKey: "test-key", model: FxModel(id: "swift/vision", reasoningEffort: "max"), httpClient: recorder
        ))
        try await invalid.close()
        Issue.record("Unsupported effort was accepted")
    } catch FxError.rpc(_, _, let data) {
        #expect(data?["code"] == .string("LIBFX_MODEL_UNSUPPORTED_EFFORT"))
        #expect(data?["model"] == .string("swift/vision"))
    }
}

@Test(arguments: [String(repeating: "x", count: 65), String(repeating: "é", count: 33)])
func oversizedEffortIsRejectedBeforeCoreAllocation(effort: String) async throws {
    let recorder = RequestRecorder()
    var configuration = FxConfiguration(apiKey: "test-key", model: FxModel(id: "swift/vision", reasoningEffort: effort), httpClient: recorder)
    configuration.wireObserver = { direction, frame in
        if direction == .sent { await recorder.record(frame) }
    }
    await #expect(throws: FxError.invalidInput("Reasoning effort must not exceed 64 bytes")) {
        try await FxEngine.open(configuration: configuration)
    }
    #expect(await recorder.frames.isEmpty)
    #expect(await recorder.catalogRequests == 0)
    #expect(await recorder.calls.isEmpty)
}

@Test func malformedEffortIsRejectedByTheCoreWithoutNetwork() async throws {
    let recorder = RequestRecorder()
    do {
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test-key",
            model: FxModel(id: "swift/vision", reasoningEffort: "turbo!"), httpClient: recorder))
        try await engine.close()
        Issue.record("Malformed effort was accepted")
    } catch FxError.rpc(let code, let message, _) {
        #expect(code == -32602)
        #expect(message == "Invalid reasoning effort")
    }
    #expect(await recorder.catalogRequests == 0)
    #expect(await recorder.calls.isEmpty)
}

@Test func defaultEffortAndDisabledFastAvoidCatalogAndProviderOverrides() async throws {
    let recorder = RequestRecorder()
    let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test-key",
        model: FxModel(id: "swift/vision", reasoningEffort: "default", fast: false), httpClient: recorder))
    #expect(await recorder.catalogRequests == 0)
    let turn = try await engine.prompt("hello")
    #expect(try await turn.result.stopReason == .endTurn)
    let requests = await recorder.calls
    #expect(requests.count == 1)
    #expect(requests.first?["reasoning"] == nil)
    #expect(requests.first?["providerOptions"]?["gateway"]?["speed"] == nil)
    try await engine.close()
}

@Test func imageBytesReachProviderWithoutEnteringACPFrames() async throws {
    let recorder = RequestRecorder()
    var config = FxConfiguration(
        apiKey: "test-key", model: "swift/vision", httpClient: recorder
    )
    config.wireObserver = { direction, frame in
        if direction == .sent { await recorder.record(frame) }
    }
    let engine = try await FxEngine.open(configuration: config)
    let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII="
    let turn = try await engine.prompt([.text("describe"), .image(FxImage(data: Data(base64Encoded: encoded)!, format: .png))])
    for try await _ in turn {}
    #expect(try await turn.result.stopReason == .endTurn)
    let requests = await recorder.calls
    guard case .array(let messages) = requests[0]["prompt"],
          case .array(let parts) = messages.first?["content"] else {
        Issue.record("Missing provider content"); try await engine.close(); return
    }
    #expect(parts.contains(.object([
        "type": .string("file"), "mediaType": .string("image/png"),
        "data": .object(["type": .string("data"), "data": .string(encoded)]),
    ])))
    let frames = await recorder.frames
    let promptFrame = frames.first { $0["method"] == .string("session/prompt") }
    guard case .array(let blocks) = promptFrame?["params"]?["prompt"] else {
        Issue.record("Missing ACP prompt"); try await engine.close(); return
    }
    #expect(blocks.last?["_meta"]?["fx"]?["attachment"] == .number(1))
    #expect(blocks.last?["data"] == nil)
    await #expect(throws: FxError.self) {
        try await engine.prompt([.image(FxImage(data: Data(repeating: 1, count: 4 * 1024 * 1024), format: .png))])
    }
    try await engine.close()
}

@Test func richToolResultPreservesImagesAndFailure() throws {
    let image = FxImage(data: Data([1, 2, 3]), format: .png, sourceReference: "screenshot-1")
    let response = try FxToolResult(text: "partial", images: [image], isError: true).response()
    #expect(response["contentType"] == .string("rich"))
    #expect(response["isError"] == .bool(true))
    let content = try JSONDecoder().decode(JSONValue.self, from: Data(response["content"]!.string!.utf8))
    #expect(content["text"] == .string("partial"))
    #expect(content["images"] == .array([.object([
        "type": .string("image"), "mimeType": .string("image/png"), "sourceRef": .string("screenshot-1"), "data": .string("AQID"),
    ])]))
}
