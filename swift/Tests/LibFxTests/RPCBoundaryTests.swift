import Foundation
import Testing
@testable import LibFx

@Suite(.timeLimit(.minutes(1)))
struct RPCBoundaryTests {
    private static let malformedFrames: [String] = [
        "not-json",
        "[]",
        #"{"jsonrpc":"1.0","method":"notice"}"#,
        #"{"jsonrpc":"2.0","method":false}"#,
        #"{"jsonrpc":"2.0","method":"notice","params":false}"#,
        #"{"jsonrpc":"2.0","method":"notice","id":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"result":null,"error":{"code":-1,"message":"bad"}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":{"code":"bad","message":"bad"}}"#,
        #"{"jsonrpc":"2.0","id":1}"#,
    ]

    @Test(arguments: malformedFrames)
    func malformedFramesFailBothPendingRequestsAndOutput(frame: String) async throws {
        let transport = ScriptedTransport()
        await transport.disableReplies()
        let client = RPCClient(transport: transport)
        await client.start()
        let request = Task { try await client.request("wait") }
        while await transport.writeCount() == 0 { await Task.yield() }
        await transport.inject(Data((frame + "\n").utf8))
        await client.waitForTermination()
        do { _ = try await request.value; Issue.record("Malformed frame settled as a result") }
        catch { expectMalformedFailure(error, frame: frame) }
        var output = client.messages.makeAsyncIterator()
        do { _ = try await output.next(); Issue.record("Malformed output did not fail") }
        catch { expectMalformedFailure(error, frame: frame) }
        await #expect(throws: FxError.closed) { try await transport.write(Data()) }
        await client.close()
    }

    private func expectMalformedFailure(_ error: any Error, frame: String) {
        if frame == "not-json" { #expect(error is DecodingError) }
        else if case FxError.protocolViolation = error { /* Expected envelope failure. */ }
        else { Issue.record("Expected a protocol violation, received \(error)") }
    }

    @Test func terminationJoinsTransportCleanup() async throws {
        let transport = CleanupGatedTransport()
        let termination = PromptDispatch()
        let client = RPCClient(transport: transport, termination: termination)
        await client.start()
        let waiting = Task { await client.waitForTermination() }
        await transport.inject(Data("not-json\n".utf8))
        _ = await transport.closeEntered.wait()
        // The fixture has entered close but cannot finish until this test releases it.
        #expect(await termination.currentResult() == nil)
        await transport.allowClose.resolve(sent: true)
        await waiting.value
        #expect(await termination.currentResult() == true)
        await #expect(throws: FxError.closed) { try await transport.write(Data()) }
        await client.close()
    }

    @Test(arguments: ["{", #"{"jsonrpc":"2.0","method":"notice"}"#])
    func eofRejectsAnUnterminatedFrame(frame: String) async throws {
        let transport = ScriptedTransport()
        let client = RPCClient(transport: transport)
        await client.start()
        await transport.inject(Data(frame.utf8))
        await transport.close()
        var output = client.messages.makeAsyncIterator()
        await #expect(throws: FxError.protocolViolation("Core output ended within a frame")) {
            _ = try await output.next()
        }
        await client.close()
    }

    @Test func malformedUTF8FailsInsteadOfReplacingBytes() async throws {
        let transport = ScriptedTransport()
        let client = RPCClient(transport: transport)
        await client.start()
        var bytes = Data(#"{"jsonrpc":"2.0","method":""#.utf8)
        bytes.append(0xff)
        bytes.append(contentsOf: [34, 125, 10])
        await transport.inject(bytes)
        var output = client.messages.makeAsyncIterator()
        await #expect(throws: DecodingError.self) { _ = try await output.next() }
        await client.close()
    }

    @Test(arguments: [false, true])
    func frameLimitIncludesTheDelimiter(split: Bool) async throws {
        let bytes = Data((#"{"jsonrpc":"2.0","method":"notice"}"# + "\n").utf8)
        for limit in [bytes.count, bytes.count - 1] {
            let transport = ScriptedTransport()
            let client = RPCClient(transport: transport, maxFrameBytes: limit)
            await client.start()
            if split {
                await transport.inject(bytes.dropLast())
                await transport.inject(Data([10]))
            } else { await transport.inject(bytes) }
            var output = client.messages.makeAsyncIterator()
            if limit == bytes.count {
                #expect(try await output.next()?.method == "notice")
            } else {
                await #expect(throws: FxError.protocolViolation("Frame exceeds limit")) {
                    _ = try await output.next()
                }
            }
            await client.close()
        }
    }

    @Test func defaultLimitRejectsAnActual64MiBUnterminatedFrame() async throws {
        let transport = ScriptedTransport()
        let client = RPCClient(transport: transport)
        await client.start()
        let fragment = Data(repeating: 120, count: 32 * 1024 * 1024)
        await transport.inject(fragment)
        await transport.inject(fragment)
        await transport.inject(Data([10]))
        var output = client.messages.makeAsyncIterator()
        await #expect(throws: FxError.protocolViolation("Frame exceeds limit")) {
            _ = try await output.next()
        }
        await client.close()
    }

    @Test func coalescedFramesRetainOrderAcrossFragmentedUnicode() async throws {
        let transport = ScriptedTransport()
        let client = RPCClient(transport: transport)
        await client.start()
        let first = Data((#"{"jsonrpc":"2.0","method":"first","params":{"text":"界🦉"}}"# + "\n").utf8)
        let second = Data((#"{"jsonrpc":"2.0","method":"second"}"# + "\n").utf8)
        await transport.inject(first.prefix(first.count - 4))
        await transport.inject(first.suffix(4) + second)
        await transport.close()
        var output = client.messages.makeAsyncIterator()
        let message = try await output.next()
        #expect(message?.method == "first")
        #expect(message?.params["text"] == .string("界🦉"))
        #expect(try await output.next()?.method == "second")
        await #expect(throws: FxError.closed) { _ = try await output.next() }
        await client.close()
    }
}

private actor CleanupGatedTransport: CoreTransport {
    nonisolated let output: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    let closeEntered = PromptDispatch()
    let allowClose = PromptDispatch()
    private var closed = false

    init() { (output, continuation) = AsyncThrowingStream.makeStream() }
    func inject(_ data: Data) { continuation.yield(data) }
    func write(_ data: Data) throws { if closed { throw FxError.closed } }
    func close() async {
        await closeEntered.resolve(sent: true)
        _ = await allowClose.wait()
        closed = true
        continuation.finish()
    }
}
