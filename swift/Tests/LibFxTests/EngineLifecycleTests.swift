import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private struct FixedHTTPClient: FxHTTPClient {
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let text: String
        if request.httpMethod == "GET" {
            text = "{\"data\":[{\"id\":\"swift/test\",\"type\":\"language\"}]}"
        } else {
            text = "data: {\"type\":\"text-delta\",\"delta\":\"hello\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        }
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(Data(text.utf8))
            continuation.finish()
        }
        return FxHTTPResponse(statusCode: 200, body: body)
    }
}

private actor CheckpointGate {
    private var blocked = false
    private var release: CheckedContinuation<Void, Never>?
    func block() async {
        blocked = true
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilBlocked() async {
        while !blocked { await Task.yield() }
    }
    func open() { release?.resume(); release = nil }
}

@Suite(.serialized) struct EngineLifecycleTests {
    private func configuration() -> FxConfiguration {
        FxConfiguration(apiKey: "swift-test-key", model: "swift/test", httpClient: FixedHTTPClient())
    }

    @Test func closedEnginesReleaseNativeSlotsWhileRetained() async throws {
        // The native runtime has 64 slots. Retaining closed wrappers must not retain slots.
        var retained: [FxEngine] = []
        for _ in 0..<70 {
            let engine = try await FxEngine.open(configuration: configuration())
            try await engine.close()
            retained.append(engine)
        }
        #expect(retained.count == 70)
    }

    @Test func nativeStreamAndResultAgree() async throws {
        let engine = try await FxEngine.open(configuration: configuration())
        let turn = try await engine.prompt("hello")
        var text = ""
        for try await event in turn { if case .text(let delta) = event { text += delta } }
        let result = try await turn.result
        #expect(text == "hello")
        #expect(result.stopReason == .endTurn)
        try await engine.close()
        await #expect(throws: FxError.closed) { try await engine.prompt("after close") }
    }

    @Test func promptWaitsForTheCurrentCheckpointAndQueuedExportsRecheckIt() async throws {
        let gate = CheckpointGate()
        var config = configuration()
        config.wireObserver = { direction, message in
            if direction == .sent, message["method"] == .string("libfx/checkpoint") { await gate.block() }
        }
        let engine = try await FxEngine.open(configuration: config)
        let checkpoint = Task { try await engine.checkpoint() }
        await gate.waitUntilBlocked()
        let queued = Task { try await engine.checkpoint() }
        let turn = try await engine.prompt("racing prompt")
        await gate.open()
        #expect(try await checkpoint.value.count > 0)
        await #expect(throws: FxError.busy) { try await queued.value }
        #expect(try await turn.result.stopReason == .endTurn)
        try await engine.close()
    }

    @Test func concurrentCheckpointsExceedTheNativeOutboundTableWithoutOverlapping() async throws {
        let engine = try await FxEngine.open(configuration: configuration())
        let turn = try await engine.prompt("remember")
        _ = try await turn.result
        let expected = try await engine.checkpoint()
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<32 { group.addTask { try await engine.checkpoint() } }
            for try await data in group { #expect(data == expected) }
        }
        try await engine.close()
    }

    @Test(arguments: [0, 4 * 1024 * 1024 + 1]) func invalidCheckpointSizeFailsAtTheSwiftBoundary(size: Int) async throws {
        let message = size == 0 ? "Checkpoint must not be empty" : "Checkpoint exceeds the 4194304 byte limit"
        await #expect(throws: FxError.invalidInput(message)) {
            try await FxEngine.open(configuration: configuration(), checkpoint: Data(repeating: 0, count: size))
        }
    }

    @Test func checkpointCancellationDoesNotCancelTheActiveExport() async throws {
        let gate = CheckpointGate()
        var config = configuration()
        config.wireObserver = { direction, message in
            if direction == .sent, message["method"] == .string("libfx/checkpoint") { await gate.block() }
        }
        let engine = try await FxEngine.open(configuration: config)
        let active = Task { try await engine.checkpoint() }
        await gate.waitUntilBlocked()
        let queued = Task { try await engine.checkpoint() }
        while await engine.queuedCheckpointCount == 0 { await Task.yield() }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        await gate.open()
        #expect(try await active.value.count > 0)
        try await engine.close()
    }

    @Test func closingReleasesTheCurrentAndPendingCheckpointCalls() async throws {
        let gate = CheckpointGate()
        var config = configuration()
        config.wireObserver = { direction, message in
            if direction == .sent, message["method"] == .string("libfx/checkpoint") { await gate.block() }
        }
        let engine = try await FxEngine.open(configuration: config)
        let active = Task { try await engine.checkpoint() }
        await gate.waitUntilBlocked()
        let pending = (0..<16).map { _ in Task { try await engine.checkpoint() } }
        while await engine.queuedCheckpointCount < pending.count { await Task.yield() }
        try await engine.close()
        await gate.open()
        await #expect(throws: FxError.closed) { try await active.value }
        for task in pending { await #expect(throws: FxError.closed) { try await task.value } }
    }

    @Test func oldTurnControlsCannotAffectANewerTurn() async throws {
        let engine = try await FxEngine.open(configuration: configuration())
        let old = try await engine.prompt("first")
        for try await _ in old {}
        _ = try await old.result
        let current = try await engine.prompt("second")
        await #expect(throws: FxError.noActiveTurn) { try await old.steer("stale") }
        #expect(try await old.withdraw("unknown") == .alreadyPlaced)
        await old.cancel()
        for try await _ in current {}
        #expect(try await current.result.stopReason == .endTurn)
        try await engine.close()
    }
}
