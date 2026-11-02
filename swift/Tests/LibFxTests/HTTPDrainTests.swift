import Foundation
import Testing
@testable import LibFx

private final class TailHTTPClient: FxHTTPClient, Sendable {
    struct State {
        var bodies: [AsyncThrowingStream<Data, any Error>.Continuation] = []
        var cancellations = 0
        var ended: Set<Int> = []
        var nextRequestOvertookEOF = false
    }
    final class LockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = State()
        func withLock<T>(_ action: (inout State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return action(&value)
        }
    }
    let state = LockedState()
    let toolStep: Bool
    init(toolStep: Bool = false) { self.toolStep = toolStep }

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        if request.httpMethod == "GET" {
            return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream {
                $0.yield(Data(#"{"data":[{"id":"swift/drain","type":"language"}]}"#.utf8))
                $0.finish()
            })
        }
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let index = state.withLock { state in
            let index = state.bodies.count
            if index > 0 && !state.ended.contains(index - 1) { state.nextRequestOvertookEOF = true }
            state.bodies.append(continuation)
            return index
        }
        let frames: String
        if toolStep && index == 0 {
            frames = "data: {\"type\":\"tool-call\",\"toolCallId\":\"tail-tool\",\"toolName\":\"lookup\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n"
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                self.finish(index)
            }
        } else {
            frames = "data: {\"type\":\"text-delta\",\"delta\":\"OK\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        }
        continuation.yield(Data(frames.utf8))
        return FxHTTPResponse(statusCode: 200, body: body, cancel: {
            self.state.withLock { $0.cancellations += 1 }
            continuation.finish(throwing: CancellationError())
        })
    }

    func finish(_ index: Int = 0) {
        let body = state.withLock { state in
            state.ended.insert(index)
            return state.bodies[index]
        }
        body.finish()
    }

    func tail(_ count: Int) {
        let body = state.withLock { $0.bodies.last! }
        body.yield(Data(repeating: 32, count: count))
    }
}

@Test(arguments: [false, true])
func consumedResponseDrainsToEOFWithoutCancellation(toolStep: Bool) async throws {
    let client = TailHTTPClient(toolStep: toolStep)
    let tool = FxTool(name: "lookup", description: "Look up a value", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in "value" }
    let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test-key", model: "swift/drain", tools: [tool], httpClient: client))
    let turn = try await engine.prompt("hello")
    var text = ""
    for try await event in turn { if case .text(let delta) = event { text += delta } }
    #expect(try await turn.result.stopReason == .endTurn)
    #expect(text == "OK")
    #expect(client.state.withLock { $0.cancellations } == 0)
    let eof = Task {
        try await Task.sleep(for: .milliseconds(30))
        client.finish(toolStep ? 1 : 0)
    }
    try await engine.close()
    try await eof.value
    #expect(client.state.withLock { $0.cancellations } == 0)
    #expect(!client.state.withLock { $0.nextRequestOvertookEOF })
}

@Test(arguments: [false, true])
func consumedResponseTailHasTimeAndByteBounds(oversized: Bool) async throws {
    let client = TailHTTPClient()
    let engine = try await FxEngine.open(configuration: FxConfiguration(apiKey: "test-key", model: "swift/drain", httpClient: client))
    let turn = try await engine.prompt("hello")
    for try await _ in turn {}
    #expect(try await turn.result.stopReason == .endTurn)
    #expect(client.state.withLock { $0.cancellations } == 0)
    let offeredEOF: Task<Void, any Error>?
    if oversized {
        client.tail(96 * 1024)
        offeredEOF = Task {
            try await Task.sleep(for: .milliseconds(30))
            client.finish()
        }
    } else { offeredEOF = nil }
    let start = ContinuousClock.now
    try await engine.close()
    let elapsed = start.duration(to: .now)
    try await offeredEOF?.value
    #expect(client.state.withLock { $0.cancellations } == 1)
    #expect(elapsed < .seconds(2))
    if !oversized { #expect(elapsed >= .milliseconds(50)) }
}
