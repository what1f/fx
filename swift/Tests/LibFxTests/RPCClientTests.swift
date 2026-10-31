import Foundation
import Testing
@testable import LibFx

@Test func oversizedOutgoingRequestDoesNotWriteAndLeavesClientUsable() async throws {
    let transport = ScriptedTransport()
    let client = RPCClient(transport: transport)
    await client.start()
    do {
        _ = try await client.request("echo", .string(String(repeating: "x", count: 8 * 1024 * 1024)))
        Issue.record("Oversized request reached the transport")
    } catch {
        #expect(error as? FxError == .invalidInput("Request exceeds the 8388608 byte frame limit"))
    }
    #expect(await transport.writeCount() == 0)
    #expect(try await client.request("echo", .string("usable")) == .string("usable"))
    await client.close()
}

actor ScriptedTransport: CoreTransport {
    nonisolated let output: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var writes: [JSONValue] = []
    private var closed = false
    var autoReply = true

    init() {
        (output, continuation) = AsyncThrowingStream.makeStream()
    }
    func write(_ bytes: Data) async throws {
        guard !closed else { throw FxError.closed }
        let request = try JSONDecoder().decode(JSONValue.self, from: bytes)
        writes.append(request)
        if autoReply, let id = request["id"], request["method"] != nil {
            let reply = JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": request["params"] ?? .null])
            var response = try JSONEncoder().encode(reply)
            response.append(10)
            // Exercise arbitrary chunking, including inside multibyte UTF-8.
            for byte in response { continuation.yield(Data([byte])) }
        }
    }
    func inject(_ data: Data) { continuation.yield(data) }
    func disableReplies() { autoReply = false }
    func writeCount() -> Int { writes.count }
    func lastWrite() -> JSONValue? { writes.last }
    func close() { closed = true; continuation.finish() }
}

@Test(arguments: [true, false])
func toolResponseFrameOverflowPreservesReferencesOrReportsAnError(referenced: Bool) async throws {
    let transport = ScriptedTransport()
    let client = RPCClient(transport: transport)
    let image = FxImage(data: Data(repeating: 1, count: 3072), format: .png,
                        sourceReference: referenced ? "host:outer-frame" : nil)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let empty = try FxToolResult(text: "", images: [image]).response(toolName: "load")
    let overhead = try #require(empty["content"]?.string?.utf8.count)
    let text = String(repeating: "x", count: 8 * 1024 * 1024 - overhead - 32)
    let result = try FxToolResult(text: text, images: [image]).response(toolName: "load")
    let envelope = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string("outer-image"), "result": result])
    #expect(try encoder.encode(envelope).count + 1 > 8 * 1024 * 1024)
    try await client.respondToTool(id: .string("outer-image"), result: result)
    let written = try #require(await transport.lastWrite())
    #expect(try encoder.encode(written).count + 1 <= 8 * 1024 * 1024)
    if referenced {
        #expect(written["result"]?["isError"] == .bool(false))
        let content = try #require(written["result"]?["content"]?.string)
        let rich = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8))
        #expect(rich["text"] == .string(text))
        #expect(rich["images"] == .array([.object(image.fields)]))
    } else {
        #expect(written["result"]?["isError"] == .bool(true))
        #expect(written["result"]?["content"] == .string("Host tool result exceeded the response frame limit"))
    }
    await client.close()
}

@Test func rpcPreservesUnicodeAcrossByteBoundaries() async throws {
    let transport = ScriptedTransport()
    let client = RPCClient(transport: transport)
    await client.start()
    let payload = JSONValue.object(["text": .string("中文和 emoji 🦉")])
    let result = try await client.request("echo", payload)
    #expect(result == payload)
    await client.close()
}

@Test func rpcSeparatesHostRequestsFromReplies() async throws {
    let transport = ScriptedTransport()
    let client = RPCClient(transport: transport)
    await client.start()
    await transport.inject(Data("{\"jsonrpc\":\"2.0\",\"id\":\"tool-1\",\"method\":\"libfx/tool_call\",\"params\":{\"name\":\"lookup\"}}\n".utf8))
    var iterator = client.messages.makeAsyncIterator()
    let request = try await iterator.next()
    #expect(request?.method == "libfx/tool_call")
    #expect(request?.id == .string("tool-1"))
    let reply = try await client.request("echo", .bool(true))
    #expect(reply == .bool(true))
    await client.close()
}

@Test func rpcCloseSettlesOutstandingRequests() async throws {
    let transport = ScriptedTransport()
    await transport.disableReplies()
    let client = RPCClient(transport: transport)
    await client.start()
    let request = Task { try await client.request("wait") }
    while await transport.writeCount() == 0 { await Task.yield() }
    await client.close()
    await client.close()
    do { _ = try await request.value; Issue.record("Outstanding request succeeded after close") }
    catch { #expect(error as? FxError == .closed) }
}

@Test func rpcRejectsOversizeFrame() async throws {
    let transport = ScriptedTransport()
    let client = RPCClient(transport: transport, maxFrameBytes: 8)
    await client.start()
    await transport.inject(Data("123456789".utf8))
    var iterator = client.messages.makeAsyncIterator()
    do { _ = try await iterator.next(); Issue.record("Oversize frame was accepted") }
    catch { #expect(error as? FxError == .protocolViolation("Frame exceeds limit")) }
    await client.close()
}

@Test func rpcCancellationSettlesOutstandingRequest() async throws {
    let transport = ScriptedTransport()
    await transport.disableReplies()
    let client = RPCClient(transport: transport)
    await client.start()
    let request = Task { try await client.request("wait") }
    while await transport.writeCount() == 0 { await Task.yield() }
    request.cancel()
    do { _ = try await request.value; Issue.record("Cancelled request succeeded") }
    catch { #expect(error as? FxError == .cancelled) }
    await client.close()
}
