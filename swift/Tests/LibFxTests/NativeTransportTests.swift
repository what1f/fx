import Foundation
import Testing
@testable import LibFx

@Test func nativeOutputWaitsForItsReaderWithoutDroppingResponses() async throws {
    let transport = try NativeTransport(options: .object([
        "apiKey": .string("test-key"), "model": .string("swift/backpressure"),
        "home": .string("/tmp"), "workspaceRoot": .string("/tmp"),
    ]))
    try await transport.start()
    do {
        let encoder = JSONEncoder()
        for id in 0...384 {
            let request = JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                "method": .string(id == 0 ? "initialize" : "unknown-backpressure-method"),
                "params": id == 0 ? .object(["protocolVersion": .number(1), "clientCapabilities": .object([:])]) : .object([:]),
            ])
            var bytes = try encoder.encode(request)
            bytes.append(10)
            try await transport.write(bytes)
            // Keep the consumer paused while independent readiness wakes arrive.
            try await Task.sleep(for: .milliseconds(1))
        }
        var buffered = Data(), replies: [Int] = []
        for try await chunk in transport.output {
            buffered.append(chunk)
            while let end = buffered.firstIndex(of: 10) {
                let reply = try JSONDecoder().decode(JSONValue.self, from: buffered[..<end])
                buffered.removeSubrange(...end)
                let id = try #require(reply["id"]?.integer)
                replies.append(id)
                if id == 0 { #expect(reply["result"] != nil) }
                else { #expect(reply["error"]?["code"] == .number(-32601)) }
            }
            if replies.count == 385 { break }
        }
        #expect(replies == Array(0...384))
        #expect(buffered.isEmpty)
        await transport.close()
    } catch {
        await transport.close()
        throw error
    }
}

@Test func closingNativeTransportReleasesAnIdleOutputReader() async throws {
    let transport = try NativeTransport(options: .object([
        "apiKey": .string("test-key"), "home": .string("/tmp"), "workspaceRoot": .string("/tmp"),
    ]))
    try await transport.start()
    let reading = Task {
        var iterator = transport.output.makeAsyncIterator()
        return try await iterator.next()
    }
    await Task.yield()
    await transport.close()
    #expect(try await reading.value == nil)
}

@Suite(.timeLimit(.minutes(1)))
struct NativeTransportBoundaryTests {
    private func makeTransport() throws -> NativeTransport {
        try NativeTransport(options: .object([
            "apiKey": .string("test-key"), "home": .string("/tmp"), "workspaceRoot": .string("/tmp"),
        ]))
    }

    @Test func closingBeforeStartIsIdempotentAndRejectsFurtherInput() async throws {
        let transport = try makeTransport()
        await transport.close()
        await transport.close()
        try await transport.start()
        await #expect(throws: FxError.closed) { try await transport.write(Data([10])) }
        await #expect(throws: FxError.closed) { try await transport.putAttachment(Data([1]), id: 1) }
        await #expect(throws: FxError.closed) { _ = try await transport.takeAttachment(id: 1) }
        await transport.abortEffects()
        await transport.discardAttachments()
        var output = transport.output.makeAsyncIterator()
        #expect(try await output.next() == nil)
    }

    @Test func cancellationReleasesTheNativeOutputReaderForReuse() async throws {
        let transport = try makeTransport()
        try await transport.start()
        try await transport.start()
        let reader = Task {
            var output = transport.output.makeAsyncIterator()
            return try await output.next()
        }
        await Task.yield()
        reader.cancel()
        do { #expect(try await reader.value == nil) }
        catch { #expect(error is CancellationError) }
        // A later reader must not inherit the previous read's cancellation.
        let client = RPCClient(transport: transport)
        await client.start()
        let initialized = try await client.request("initialize", .object([
            "protocolVersion": .number(1), "clientCapabilities": .object([:]),
        ]))
        #expect(initialized["protocolVersion"] == .number(1))
        await client.close()
        await transport.close()
    }

    @Test func cancelledCloseJoinsReadinessSourceCleanup() async throws {
        for _ in 0..<32 {
            let readinessClosed = PromptDispatch()
            let transport = try NativeTransport(options: .object([
                "apiKey": .string("test-key"), "home": .string("/tmp"), "workspaceRoot": .string("/tmp"),
            ]), readinessClosed: readinessClosed)
            try await transport.start()
            let closing = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await transport.close()
                return await readinessClosed.currentResult()
            }
            #expect(await closing.value == true)
            await #expect(throws: FxError.closed) { try await transport.write(Data()) }
            await transport.close()
        }
    }

    @Test func rejectedNativeInputDoesNotPoisonTheRuntime() async throws {
        let transport = try makeTransport()
        try await transport.start()
        await #expect(throws: FxError.transport("Core input rejected")) {
            try await transport.write(Data(repeating: 120, count: 8 * 1024 * 1024 + 1))
        }
        let client = RPCClient(transport: transport)
        await client.start()
        let result = try await client.request("initialize", .object([
            "protocolVersion": .number(1), "clientCapabilities": .object([:]),
        ]))
        #expect(result["protocolVersion"] == .number(1))
        await client.close()
    }

    @Test(arguments: [false, true])
    func fullNativeOutputQueueDrainsOrClosesWithoutBlockingOtherOwners(closeUnread: Bool) async throws {
        let transport = try makeTransport()
        try await transport.start()
        let encoder = JSONEncoder()
        var initialize = try encoder.encode(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .number(0), "method": .string("initialize"),
            "params": .object(["protocolVersion": .number(1), "clientCapabilities": .object([:])]),
        ]))
        initialize.append(10)
        try await transport.write(initialize)
        var initialOutput = transport.output.makeAsyncIterator()
        let initializedBytes = try #require(try await initialOutput.next())
        let initialReply = try JSONDecoder().decode(JSONValue.self, from: initializedBytes)
        #expect(initialReply["result"]?["protocolVersion"] == .number(1))
        let padding = String(repeating: "x", count: 16 * 1024)
        // Echoed request IDs alone exceed the native queue's 8 MiB capacity.
        // Keep every output reader paused until all input is admitted.
        for index in 0..<640 {
            var bytes = try encoder.encode(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .string("\(index):" + padding),
                "method": .string("unknown-pressure-method"),
            ]))
            bytes.append(10)
            try await transport.write(bytes)
            if index % 16 == 0 { try await Task.sleep(for: .milliseconds(1)) }
        }
        let independent = try makeTransport()
        try await independent.start()
        let client = RPCClient(transport: independent)
        await client.start()
        let initialized = try await client.request("initialize", .object([
            "protocolVersion": .number(1), "clientCapabilities": .object([:]),
        ]))
        #expect(initialized["protocolVersion"] == .number(1))
        await client.close()
        if !closeUnread {
            var buffered = Data()
            var received = 0
            for try await chunk in transport.output {
                buffered.append(chunk)
                while let end = buffered.firstIndex(of: 10) {
                    let reply = try JSONDecoder().decode(JSONValue.self, from: buffered[..<end])
                    buffered.removeSubrange(...end)
                    #expect(reply["id"] == .string("\(received):" + padding))
                    #expect(reply["error"]?["code"] == .number(-32601))
                    received += 1
                }
                if received == 640 { break }
            }
            #expect(received == 640)
            #expect(buffered.isEmpty)
        }
        let closing = ContinuousClock.now
        await transport.close()
        #expect(closing.duration(to: .now) < .seconds(2))
    }

    @Test func readinessSurvivesCoalescedBurstsAndRepeatedClose() async throws {
        for _ in 0..<8 {
            let transport = try makeTransport()
            try await transport.start()
            let client = RPCClient(transport: transport)
            await client.start()
            _ = try await client.request("initialize", .object([
                "protocolVersion": .number(1), "clientCapabilities": .object([:]),
            ]))
            for _ in 0..<3 {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<32 {
                        group.addTask {
                            do {
                                _ = try await client.request("unknown-readiness-method")
                                Issue.record("Unknown method succeeded")
                            } catch {
                                guard case FxError.rpc(let code, _, _) = error else {
                                    Issue.record("Readiness lost a response: \(error)")
                                    return
                                }
                                #expect(code == -32601)
                            }
                        }
                    }
                }
            }
            await client.close()
            await client.close()
            await transport.close()
        }
    }
}

private actor NativeFirstRequestCancellation {
    private var turn: FxTurn?
    private var waiter: CheckedContinuation<FxTurn, Never>?
    private var cancelled = false

    func install(_ turn: FxTurn) {
        self.turn = turn
        waiter?.resume(returning: turn)
        waiter = nil
    }

    func cancelFirstRequest() async {
        guard !cancelled else { return }
        cancelled = true
        let current: FxTurn
        if let turn { current = turn }
        else { current = await withCheckedContinuation { waiter = $0 } }
        await current.cancel()
    }
}

private actor NativeBoundaryHTTP: FxHTTPClient {
    private(set) var posts = 0
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let wire: String
        if request.httpMethod == "GET" {
            wire = #"{"data":[{"id":"swift/boundary","type":"language"}]}"#
        } else {
            posts += 1
            wire = "data: {\"type\":\"text-delta\",\"delta\":\"after cancel\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        }
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
            $0.yield(Data(wire.utf8))
            $0.finish()
        })
    }
}

@Test(.timeLimit(.minutes(1)))
func nativeCancellationBeforeHTTPDispatchSuppressesFetchAndAllowsReuse() async throws {
    let http = NativeBoundaryHTTP(), control = NativeFirstRequestCancellation()
    var configuration = FxConfiguration(apiKey: "test-key", model: "swift/boundary", httpClient: http)
    configuration.onTransportEvent = { event in
        if case .started(let request) = event, request.method == "POST" {
            await control.cancelFirstRequest()
        }
    }
    let engine = try await FxEngine.open(configuration: configuration)
    let first = try await engine.prompt("cancel before fetch")
    await control.install(first)
    #expect(try await first.result.stopReason == .cancelled)
    #expect(await http.posts == 0)
    let second = try await engine.prompt("reuse after cancellation")
    var text = ""
    for try await event in second { if case .text(let delta) = event { text += delta } }
    #expect(try await second.result.stopReason == .endTurn)
    #expect(text == "after cancel")
    #expect(await http.posts == 1)
    try await engine.close()
}
