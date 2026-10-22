import Foundation
import LibFx

// Test-only runtime peer. RPC parsing, dispatch, ownership and tool execution
// remain in the same FxEngine used by the native C transport.
actor FixtureTransport: EngineTransport {
    nonisolated let output: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private var tools: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextTool = 1
    private var closed = false
    private var writes: [String: CheckedContinuation<Void, any Error>] = [:]

    init() { (output, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(256)) }
    func start() {}
    func setContext(sessionID: String, modelID: String) {}
    func beginTurn() {}
    func abortEffects() {}
    func discardAttachments() { DriverOutput.emit(.object(["fixtureDiscard": .bool(true)])) }
    func putAttachment(_ data: Data, id: UInt32) async throws {
        try await relay("fixtureAttachment", .object(["id": .number(Double(id)), "data": .string(data.base64EncodedString())]))
    }
    func takeAttachment(id: UInt32) throws -> Data { throw FxError.invalidInput("Fixture has no attachments") }

    func write(_ bytes: Data) async throws {
        guard !closed else { throw FxError.closed }
        let message = try JSONDecoder().decode(JSONValue.self, from: bytes)
        if message["method"] == .string("libfx/conformance_barrier"), let id = message["id"] {
            try receive(.object(["id": id, "result": .object([:])]))
        } else if let id = message["id"]?.string, let tool = tools.removeValue(forKey: id) {
            tool.resume(returning: message)
        } else { try await relay("fixtureSend", message) }
    }

    private func relay(_ key: String, _ value: JSONValue) async throws {
        let token = UUID().uuidString
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                writes[token] = continuation
                DriverOutput.emit(.object([key: value, "fixtureToken": .string(token)]))
            }
        } onCancel: { Task { await self.finishWrite(token, error: CancellationError()) } }
    }

    func finishWrite(_ token: String, error: (any Error)? = nil) {
        guard let waiter = writes.removeValue(forKey: token) else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    func receive(_ message: JSONValue) throws {
        guard !closed else { throw FxError.closed }
        guard case .object(var fields) = message else { throw FxError.invalidInput("Invalid fixture frame") }
        // The fixture's parsed-object callback omits the wire version field.
        if fields["jsonrpc"] == nil { fields["jsonrpc"] = .string("2.0") }
        if fields["method"] == .string("libfx/hook"), case .object(var params) = fields["params"] {
            // Fill only wire metadata omitted by the parsed-object JS fixture.
            let defaults: [String: JSONValue] = ["timestamp": .number(Date().timeIntervalSince1970 * 1000),
                "stepIndex": .number(0), "contentCaptured": .bool(false), "contentTruncated": .bool(false)]
            for (key, value) in defaults where params[key] == nil { params[key] = value }
            fields["params"] = .object(params)
        }
        var bytes = try JSONEncoder().encode(JSONValue.object(fields))
        bytes.append(10)
        if case .dropped = continuation.yield(bytes) { throw FxError.outputOverflow }
    }

    func executeTool(name: String, input: JSONValue, sessionID: String, callID: String) async throws -> JSONValue {
        guard !closed else { throw FxError.closed }
        let id = "fixture-tool-\(nextTool)"
        nextTool += 1
        return try await withCheckedThrowingContinuation { waiter in
            tools[id] = waiter
            do { try receive(.object([
                "id": .string(id), "method": .string("libfx/tool_call"), "params": .object([
                    "name": .string(name), "input": input, "sessionId": .string(sessionID), "toolCallId": .string(callID),
                ]),
            ])) } catch { tools.removeValue(forKey: id)?.resume(throwing: error) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        for waiter in writes.values { waiter.resume(throwing: FxError.closed) }
        writes.removeAll()
        for waiter in tools.values { waiter.resume(throwing: FxError.closed) }
        tools.removeAll()
        continuation.finish()
        DriverOutput.emit(.object(["fixtureClosed": .bool(true)]))
    }

    func fail(_ error: any Error) {
        guard !closed else { return }
        closed = true
        for waiter in writes.values { waiter.resume(throwing: error) }
        writes.removeAll()
        for waiter in tools.values { waiter.resume(throwing: error) }
        tools.removeAll()
        continuation.finish(throwing: error)
    }
}
