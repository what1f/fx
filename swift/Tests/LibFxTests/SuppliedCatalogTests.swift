import Foundation
import Testing
@testable import LibFx

private actor CatalogModelHTTP: FxHTTPClient {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        requests.append(request)
        let text = "data: {\"type\":\"text-delta\",\"delta\":\"catalog reply\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(Data(text.utf8)); $0.finish() })
    }
}

@Test func suppliedCatalogEnablesVisionAndReasoningWithoutFetchingModels() async throws {
    let http = CatalogModelHTTP()
    let response = Data(#"{"data":[{"id":"swift/provided","type":"language","tags":["vision","tool-use","reasoning"],"reasoning_options":[{"type":"effort","values":["high"]}]}]}"#.utf8)
    var config = FxConfiguration(apiKey: "fixture", model: .init(id: "swift/provided", reasoningEffort: "high"), httpClient: http)
    config.modelCatalog = try FxModelCatalog(response: response)
    let engine = try await FxEngine.open(configuration: config)
    let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=")!
    let turn = try await engine.prompt([.text("describe"), .image(FxImage(data: image, format: .png))])
    var reply = ""
    for try await event in turn { if case .text(let text) = event { reply += text } }
    #expect(try await turn.result.stopReason == .endTurn)
    #expect(reply == "catalog reply")
    try await engine.close()
    let requests = await http.requests
    #expect(requests.count == 1)
    #expect(requests.first?.httpMethod == "POST")
    let body = try JSONDecoder().decode(JSONValue.self, from: #require(requests.first?.httpBody))
    #expect(body["reasoning"] == .string("high"))
    guard case .array(let messages) = body["prompt"], case .array(let parts) = messages.first?["content"] else {
        Issue.record("Missing image content")
        return
    }
    #expect(parts.contains(.object([
        "type": .string("file"), "mediaType": .string("image/png"),
        "data": .object(["type": .string("data"), "data": .string(image.base64EncodedString())]),
    ])))
}

@Test func suppliedCatalogOnlyInterceptsTheGatewayModelList() async throws {
    let http = CatalogModelHTTP(), response = Data(#"{"data":[]}"#.utf8)
    let client = CatalogHTTPClient(client: http, catalog: try FxModelCatalog(response: response))
    let catalogURL = URL(string: "https://ai-gateway.vercel.sh/coding-agent/v1/models")!
    let local = try await client.send(URLRequest(url: catalogURL))
    var received = Data()
    for try await bytes in local.body { received.append(bytes) }
    #expect(received == response)
    var post = URLRequest(url: catalogURL); post.httpMethod = "POST"
    _ = try await client.send(post)
    _ = try await client.send(URLRequest(url: URL(string: "https://example.com/coding-agent/v1/models")!))
    _ = try await client.send(URLRequest(url: URL(string: "https://ai-gateway.vercel.sh/another-path")!))
    #expect(await http.requests.count == 3)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await client.send(URLRequest(url: catalogURL))
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
}

@Test func suppliedCatalogRejectsMalformedAndOversizedResponses() throws {
    for text in ["not json", "[]", #"{"data":{}}"#, #"{"data":[{}]}"#, #"{"data":[{"id":""}]}"#, #"{"data":[{"id":1}]}"#] {
        #expect(throws: FxModelCatalogError.malformedResponse) { try FxModelCatalog(response: Data(text.utf8)) }
    }
    #expect(throws: FxModelCatalogError.byteLimit) { try FxModelCatalog(response: Data(repeating: 32, count: 4 * 1024 * 1024 + 1)) }
    let entries = Array(repeating: JSONValue.object(["id": .string("model")]), count: 10_001)
    let response = try JSONEncoder().encode(JSONValue.object(["data": .array(entries)]))
    #expect(throws: FxModelCatalogError.entryLimit) { try FxModelCatalog(response: response) }
}
