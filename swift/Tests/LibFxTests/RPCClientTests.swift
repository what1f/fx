import Foundation
import Testing
@testable import LibFx

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
    func close() { closed = true; continuation.finish() }
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
