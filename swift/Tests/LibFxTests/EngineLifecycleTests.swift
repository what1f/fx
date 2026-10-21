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

    @Test func checkpointBlocksOtherStateTransitions() async throws {
        let gate = CheckpointGate()
        var config = configuration()
        config.wireObserver = { direction, message in
            if direction == .sent, message["method"] == .string("libfx/checkpoint") { await gate.block() }
        }
        let engine = try await FxEngine.open(configuration: config)
        let checkpoint = Task { try await engine.checkpoint() }
        await gate.waitUntilBlocked()
        await #expect(throws: FxError.busy) { try await engine.prompt("racing prompt") }
        await #expect(throws: FxError.busy) { try await engine.checkpoint() }
        await gate.open()
        #expect(try await checkpoint.value.count > 0)
        try await engine.close()
    }
}
