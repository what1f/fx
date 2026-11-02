import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private let toolFrameLimit = 8 * 1024 * 1024
private let toolFrameFailure = "Host tool result exceeded the response frame limit"
private let toolContentFailure = "Host tool result exceeded the configured limit"

private actor ToolFrameProbe {
    struct Reply: Sendable {
        let bytes: Int
        let contentBytes: Int
        let isError: Bool
        let failure: String?
        let contentType: JSONValue?
    }
    private var requestID: JSONValue?
    private(set) var replies: [Reply] = []
    private(set) var executions = 0

    func observe(_ direction: FxWireDirection, _ message: JSONValue) throws {
        if direction == .received, message["method"] == .string("libfx/tool_call") { requestID = message["id"] }
        if direction == .sent, let content = message["result"]?["content"]?.string {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            replies.append(Reply(bytes: try encoder.encode(message).count + 1, contentBytes: content.utf8.count,
                isError: message["result"]?["isError"] == .bool(true),
                failure: content == toolFrameFailure ? content : nil, contentType: message["result"]?["contentType"]))
        }
    }

    func execute(overflow: Bool) throws -> FxToolResult {
        executions += 1
        let id = try #require(requestID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let overhead = try encoder.encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id,
            "result": .object(["content": .string(""), "isError": .bool(false)]),
        ])).count + 1
        // Plain ASCII needs no JSON escaping. These are the real serialized
        // request limits, including the actual RPC id and newline delimiter.
        return FxToolResult(text: String(repeating: "x", count: toolFrameLimit - overhead + (overflow ? 1 : 0)))
    }
}

private actor ToolFrameHTTP: FxHTTPClient {
    let overflow: Bool
    private(set) var requests = 0
    init(overflow: Bool) { self.overflow = overflow }

    func send(_ request: URLRequest) throws -> FxHTTPResponse {
        requests += 1
        let events: [JSONValue]
        if requests == 1 {
            events = [
                .object(["type": .string("tool-call"), "toolCallId": .string("frame-call"), "toolName": .string("large_text"), "input": .object([:])]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])]),
            ]
        } else {
            #expect(requests <= 3)
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
            guard case .array(let messages) = body["prompt"] else { throw FxError.invalidInput("Missing fixture prompt") }
            let results = messages.flatMap { message -> [JSONValue] in
                guard case .array(let content) = message["content"] else { return [] }
                return content
            }.filter {
                $0["type"] == .string("tool-result") && $0["toolCallId"] == .string("frame-call")
            }
            #expect(results.count == 1)
            let output = try #require(results.first?["output"])
            #expect(output == .object([
                "type": .string("error-text"),
                "value": .string(overflow ? toolFrameFailure : toolContentFailure),
            ]))
            events = [
                .object(["type": .string("text-delta"), "delta": .string(requests == 2 ? "handled result" : "still usable")]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])]),
            ]
        }
        let frames = try events.map { "data: \(String(decoding: try JSONEncoder().encode($0), as: UTF8.self))\n\n" }.joined() + "data: [DONE]\n\n"
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data(frames.utf8)); $0.finish()
        })
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct HostToolFrameBoundaryTests {
    @Test(arguments: [false, true])
    func nativeTextToolFrameLimitPreservesContinuationAndReuse(overflow: Bool) async throws {
        let probe = ToolFrameProbe(), http = ToolFrameHTTP(overflow: overflow)
        let tool = FxTool(name: "large_text", description: "Return boundary-sized text", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            try await probe.execute(overflow: overflow)
        }
        var configuration = FxConfiguration(apiKey: "fixture", model: "swift/tool-frame", tools: [tool], httpClient: http)
        configuration.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/tool-frame","type":"language","tags":["tool-use"]}]}"#.utf8))
        configuration.wireObserver = { direction, message in try? await probe.observe(direction, message) }
        let engine = try await FxEngine.open(configuration: configuration)
        let turn = try await engine.prompt("get boundary text")
        var text = "", toolEnds = 0
        for try await event in turn {
            if case .text(let delta) = event { text += delta }
            if case .toolFinished(_, "large_text", let content, let isError) = event {
                toolEnds += 1
                #expect(isError)
                #expect(content == (overflow ? toolFrameFailure : toolContentFailure))
            }
        }
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(text == "handled result" && toolEnds == 1)
        let reply = try #require(await probe.replies.first)
        #expect(await probe.replies.count == 1)
        #expect(reply.isError == overflow && reply.contentType == nil)
        if overflow {
            #expect(reply.failure == toolFrameFailure && reply.bytes < 1024)
        } else {
            // The frame itself passes. The native core's separate default
            // content limit then reports a configured-limit tool error.
            #expect(reply.bytes == toolFrameLimit && reply.contentBytes > toolFrameLimit - 256)
        }
        let next = try await engine.prompt("continue without replaying the tool")
        var continued = ""
        for try await event in next { if case .text(let delta) = event { continued += delta } }
        #expect(try await next.result.stopReason == .endTurn)
        #expect(continued == "still usable")
        #expect(await probe.executions == 1)
        #expect(await http.requests == 3)
        #expect(await probe.replies.count == 1)
        try await engine.close()
    }
}
