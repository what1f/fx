import Foundation

/// The byte transport owns its runtime and terminates output when it closes.
package protocol CoreTransport: Sendable {
    var output: AsyncThrowingStream<Data, any Error> { get }
    func write(_ bytes: Data) async throws
    func close() async
}

struct RPCMessage: Sendable {
    let id: JSONValue?
    let method: String
    let params: JSONValue
}

/// Serializes frames and matches responses. Host requests remain separate from replies.
actor RPCClient {
    private let observer: (@Sendable (FxWireDirection, JSONValue) async -> Void)?
    private let transport: any CoreTransport
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var reader: Task<Void, Never>?
    private var handler: (@Sendable (RPCMessage) async -> Void)?
    private var failureHandler: (@Sendable (any Error) async -> Void)?
    private var failure: (any Error)?
    private let termination = PromptDispatch()
    private var closed = false
    private var frame = Data()
    private let maxFrameBytes: Int
    nonisolated let messages: AsyncThrowingStream<RPCMessage, any Error>
    private let continuation: AsyncThrowingStream<RPCMessage, any Error>.Continuation

    init(transport: any CoreTransport, maxFrameBytes: Int = 64 * 1024 * 1024, observer: (@Sendable (FxWireDirection, JSONValue) async -> Void)? = nil) {
        self.observer = observer
        self.transport = transport
        self.maxFrameBytes = maxFrameBytes
        (messages, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(4096))
    }

    func setHandler(_ handler: @escaping @Sendable (RPCMessage) async -> Void) { self.handler = handler }

    func setFailureHandler(_ handler: @escaping @Sendable (any Error) async -> Void) async {
        failureHandler = handler
        if let failure { await handler(failure) }
    }

    func waitForTermination() async { _ = await termination.wait() }

    func start() {
        guard reader == nil, !closed else { return }
        let output = transport.output
        reader = Task { [weak self] in
            do {
                for try await chunk in output {
                    guard !Task.isCancelled else { break }
                    try await self?.receive(chunk)
                }
                await self?.finish(FxError.closed)
            } catch { await self?.finish(error) }
        }
    }

    func request(_ method: String, _ params: JSONValue = .object([:]), beforeWrite: (@Sendable () async throws -> Void)? = nil, onSent: (@Sendable () async -> Void)? = nil) async throws -> JSONValue {
        guard !closed else { throw FxError.closed }
        try Task.checkCancellation()
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task {
                    do {
                        guard !Task.isCancelled, self.pending[id] != nil else { return }
                        try await self.send(.object([
                            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                            "method": .string(method), "params": params,
                        ]), beforeWrite: beforeWrite)
                        await onSent?()
                    } catch { self.failRequest(id, error) }
                }
            }
        } onCancel: {
            Task { await self.failRequest(id, FxError.cancelled) }
        }
    }

    func notify(_ method: String, _ params: JSONValue) async throws {
        try await send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    func respond(id: JSONValue, result: JSONValue) async throws {
        try await send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    func respondToTool(id: JSONValue, result: JSONValue) async throws {
        var result = result
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func frameSize() throws -> Int {
            try encoder.encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result])).count + 1
        }
        if try frameSize() > 8 * 1024 * 1024,
           result["contentType"] == .string("rich"), let content = result["content"]?.string,
           case .object(var rich) = try JSONDecoder().decode(JSONValue.self, from: Data(content.utf8)),
           case .array(let images) = rich["images"], case .object(var fields) = result {
            rich["images"] = .array(images.map { image in
                guard image["sourceRef"] != nil, case .object(var fields) = image else { return image }
                fields.removeValue(forKey: "data")
                fields.removeValue(forKey: "stored")
                return .object(fields)
            })
            fields["content"] = .string(String(decoding: try encoder.encode(JSONValue.object(rich)), as: UTF8.self))
            result = .object(fields)
        }
        if try frameSize() > 8 * 1024 * 1024 {
            result = .object(["content": .string("Host tool result exceeded the response frame limit"), "isError": .bool(true)])
        }
        try await respond(id: id, result: result)
    }

    func respond(id: JSONValue, error: FxError) async throws {
        try await send(.object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(-32000), "message": .string(String(describing: error))]),
        ]))
    }

    private func send(_ message: JSONValue, beforeWrite: (@Sendable () async throws -> Void)? = nil) async throws {
        guard !closed else { throw FxError.closed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(message)
        data.append(10)
        guard data.count <= 8 * 1024 * 1024 else { throw FxError.invalidInput("Request exceeds the 8388608 byte frame limit") }
        await observer?(.sent, message)
        try await beforeWrite?()
        try Task.checkCancellation()
        try await transport.write(data)
    }

    private func receive(_ data: Data) async throws {
        for byte in data {
            if byte == 10 {
                if !frame.isEmpty {
                    let bytes = frame
                    frame.removeAll(keepingCapacity: true)
                    try await receiveMessage(JSONDecoder().decode(JSONValue.self, from: bytes))
                }
            } else {
                guard frame.count < maxFrameBytes else { throw FxError.protocolViolation("Frame exceeds limit") }
                frame.append(byte)
            }
        }
    }

    private func receiveMessage(_ value: JSONValue) async throws {
        await observer?(.received, value)
        guard case .object = value, value["jsonrpc"] == .string("2.0") else {
            throw FxError.protocolViolation("Invalid JSON-RPC envelope")
        }
        if let method = value["method"]?.string {
            let message = RPCMessage(id: value["id"], method: method, params: value["params"] ?? .object([:]))
            if let handler { await handler(message) }
            else if case .dropped = continuation.yield(message) { throw FxError.outputOverflow }
            return
        }
        guard let id = value["id"]?.integer, let waiter = pending.removeValue(forKey: id) else { return }
        if let error = value["error"] {
            waiter.resume(throwing: FxError.rpc(
                code: error["code"]?.integer ?? -32603,
                message: error["message"]?.string ?? "Request failed", data: error["data"]
            ))
        } else if let result = value["result"] { waiter.resume(returning: result) }
        else { waiter.resume(throwing: FxError.protocolViolation("Response has no result")) }
    }

    private func failRequest(_ id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func finish(_ error: any Error) async {
        guard !closed else { return }
        closed = true
        failure = error
        await failureHandler?(error)
        for waiter in pending.values { waiter.resume(throwing: error) }
        pending.removeAll()
        continuation.finish(throwing: error)
        reader?.cancel()
        await termination.resolve(sent: true)
        await transport.close()
    }

    func close() async {
        await finish(FxError.closed)
        await transport.close()
    }
}
