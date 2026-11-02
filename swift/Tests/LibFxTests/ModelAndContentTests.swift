import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private actor RequestRecorder: FxHTTPClient {
    var calls: [JSONValue] = []
    var frames: [JSONValue] = []
    var catalogRequests = 0
    var modelHeaders: [String?] = []
    func record(_ frame: JSONValue) { frames.append(frame) }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let payload: String
        if request.httpMethod == "GET" {
            catalogRequests += 1
            payload = #"{"data":[{"id":"swift/vision","type":"language","tags":["vision","tool-use","reasoning"],"reasoning_options":[{"type":"effort","values":["low","high"]}],"fast_options":[{"type":"toggle"}]},{"id":"openai/swift-ultra","type":"language","owned_by":"openai","fast_options":[{"type":"toggle"}],"pricing":{"service_tiers":{"ultrafast":{"input":0.00006,"output":0.0003}}}}]}"#
        } else {
            modelHeaders.append(request.value(forHTTPHeaderField: "ai-language-model-id"))
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

@Test(arguments: [false, true])
func kernelDefaultModelMatchesSavedMetadataAndRestoredRequests(useJournal: Bool) async throws {
    let recorder = RequestRecorder(), store = FxMemoryPersistence()
    var configuration = FxConfiguration(apiKey: "test-key", httpClient: recorder)
    configuration.wireObserver = { direction, frame in
        if direction == .sent { await recorder.record(frame) }
    }
    #expect(configuration.model.id == nil)
    let engine = try await FxEngine.open(configuration: configuration, persistence: useJournal ? store : nil)
    let turn = try await engine.prompt("hello")
    #expect(try await turn.result.stopReason == .endTurn)
    let checkpoint: Data?
    if useJournal { try await engine.saveCheckpoint(); checkpoint = nil }
    else { checkpoint = try await engine.checkpoint() }
    let headers = await recorder.modelHeaders
    let model = try #require(headers.first ?? nil)
    #expect(!model.isEmpty)
    let frames = await recorder.frames
    let exported = try #require(frames.first { $0["method"] == .string(useJournal ? "libfx/snapshot" : "libfx/checkpoint") })
    #expect(exported["params"]?["checkpointMeta"]?["model"] == .string(model))
    try await engine.close()
    let restored = try await FxEngine.open(configuration: configuration, checkpoint: checkpoint, persistence: useJournal ? store : nil)
    let next = try await restored.prompt("continue")
    #expect(try await next.result.stopReason == .endTurn)
    #expect(await recorder.modelHeaders == [model, model])
    try await restored.close()
}

@Test(arguments: [false, true])
func nonGatewayProvidersStillRequireAnExplicitModel(subscription: Bool) async throws {
    let recorder = RequestRecorder()
    let provider: FxProvider
    if subscription {
        provider = .subscription(FxSubscription(provider: .codex, credentials: { _ in
            Issue.record("Credentials loaded without a model")
            throw FxError.invalidInput("Unexpected credential lookup")
        }))
    } else {
        provider = .custom(try FxCustomProvider(name: "fixture", baseURL: URL(string: "https://example.com/v1")!))
    }
    await #expect(throws: FxError.invalidInput("Model is required")) {
        try await FxEngine.open(configuration: FxConfiguration(provider: provider, httpClient: recorder))
    }
    #expect(await recorder.catalogRequests == 0)
    #expect(await recorder.calls.isEmpty)
}

@Test(arguments: [false, true])
func ultrafastRoutingTakesPriorityOverFastWhenEnabled(ultrafast: Bool) async throws {
    let recorder = RequestRecorder()
    let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test-key",
        model: FxModel(id: "openai/swift-ultra", fast: true, ultrafast: ultrafast), httpClient: recorder))
    #expect(await recorder.catalogRequests == 1)
    let turn = try await engine.prompt("hello")
    #expect(try await turn.result.stopReason == .endTurn)
    let requests = await recorder.calls
    let options = try #require(requests.first?["providerOptions"])
    if ultrafast {
        #expect(options["openai"]?["serviceTier"] == .string("ultrafast"))
        #expect(options["gateway"]?["only"] == .array([.string("openai")]))
        #expect(options["gateway"]?["speed"] == nil)
    } else {
        #expect(options["openai"]?["serviceTier"] == nil)
        #expect(options["gateway"]?["only"] == nil)
        #expect(options["gateway"]?["speed"] == .string("fast"))
    }
    try await engine.close()
}

@Test func unsupportedUltrafastNeverSendsChat() async throws {
    let recorder = RequestRecorder()
    do {
        let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test-key",
            model: FxModel(id: "swift/vision", ultrafast: true), httpClient: recorder))
        try await engine.close()
        Issue.record("Unsupported ultrafast was accepted")
    } catch FxError.rpc(_, _, let data) {
        #expect(data?["code"] == .string("LIBFX_MODEL_UNSUPPORTED_ULTRAFAST"))
        #expect(data?["model"] == .string("swift/vision"))
        #expect(data?["capability"] == .string("ultrafast"))
    }
    #expect(await recorder.catalogRequests == 1)
    #expect(await recorder.calls.isEmpty)
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
    let response = try FxToolResult(text: "partial", images: [image], isError: true).response(toolName: "probe")
    #expect(response["contentType"] == .string("rich"))
    #expect(response["isError"] == .bool(true))
    let content = try JSONDecoder().decode(JSONValue.self, from: Data(response["content"]!.string!.utf8))
    #expect(content["text"] == .string("partial"))
    #expect(content["images"] == .array([.object([
        "type": .string("image"), "mimeType": .string("image/png"), "sourceRef": .string("screenshot-1"), "data": .string("AQID"),
    ])]))
}

@Test(arguments: [3145731, 3342336, 3932163])
func richToolImageOverflowPreservesReferences(size: Int) throws {
    let bytes = Data(repeating: 1, count: size)
    let images = ["host:first", "host:second"].map { FxImage(data: bytes, format: .png, sourceReference: $0) }
    let response = try FxToolResult(text: "host image", images: images).response(toolName: "load")
    let content = try #require(response["content"]?.string)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
    #expect(response["contentType"] == .string("rich"))
    #expect(decoded["images"] == .array(images.map { .object($0.fields) }))
    #expect(throws: FxError.self) {
        try FxToolResult(text: "host image", images: images.map { _ in FxImage(data: bytes, format: .png) }).response(toolName: "load")
    }
}
