import Foundation
import Testing
@_spi(Conformance) @testable import LibFx

private actor PermissionTransport: CoreTransport {
    nonisolated let output: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private(set) var writes: [JSONValue] = []
    init() { (output, continuation) = AsyncThrowingStream.makeStream() }
    func write(_ data: Data) throws {
        let message = try JSONDecoder().decode(JSONValue.self, from: data)
        writes.append(message)
        if message["method"] == .string("echo"), let id = message["id"] {
            try emit(.object(["jsonrpc": .string("2.0"), "id": id, "result": .bool(true)]))
        }
    }
    func inject(id: Int = 100, params: JSONValue) throws {
        try emit(.object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "method": .string("session/request_permission"), "params": params,
        ]))
    }
    private func emit(_ message: JSONValue) throws {
        var data = try JSONEncoder().encode(message)
        data.append(10)
        continuation.yield(data)
    }
    func close() { continuation.finish() }
}

private func permissionParams(session: String = "session", input: JSONValue = .object(["path": .string("example.txt")]),
                              options: JSONValue? = nil) -> JSONValue {
    .object([
        "sessionId": .string(session),
        "toolCall": .object(["toolCallId": .string("call"), "name": .string("write_file"), "title": .string("Write example.txt"),
                             "kind": .string("edit"), "rawInput": input]),
        "options": options ?? .array([
            .object(["optionId": .string("allow"), "name": .string("Allow once"), "kind": .string("allow_once")]),
            .object(["optionId": .string("deny"), "name": .string("Reject"), "kind": .string("reject_once")]),
        ]),
    ])
}

private func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw FxError.transport("Permission test timed out") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private struct PermissionHarness {
    let transport: PermissionTransport
    let rpc: RPCClient
    let requests: PermissionRequests
    let scope: UUID
    static func open(handler: PermissionRequests.Handler?, active: @escaping @Sendable () async -> Bool = { true }) async -> Self {
        let transport = PermissionTransport(), scope = UUID()
        let rpc = RPCClient(transport: transport)
        let requests = PermissionRequests(sessionID: "session", rpc: rpc, handler: handler)
        await rpc.setHandler { message in
            guard let id = message.id else { return }
            await requests.handle(id: id, params: message.params, turnID: "public-turn", scope: scope, isActive: active)
        }
        await rpc.start()
        return Self(transport: transport, rpc: rpc, requests: requests, scope: scope)
    }
    func close() async { await requests.cancelAll(); await rpc.close() }
}

private actor PermissionGate {
    private(set) var calls: [FxPermissionRequest] = []
    private var continuations: [CheckedContinuation<FxPermissionDecision, Never>] = []
    func choose(_ request: FxPermissionRequest) async -> FxPermissionDecision {
        calls.append(request)
        return await withCheckedContinuation { continuations.append($0) }
    }
    func release() { for continuation in continuations { continuation.resume(returning: .select(optionID: "allow")) }; continuations.removeAll() }
}

private actor PermissionActivity {
    private(set) var active = true
    func end() { active = false }
}

@Suite(.timeLimit(.minutes(1))) struct PermissionTests {
    @Test(arguments: ["allow", "deny", "not-offered"])
    func onlyOfferedOptionsCanBeSelected(option: String) async throws {
        let harness = await PermissionHarness.open { request in
            #expect(request.sessionID == "session" && request.turnID == "public-turn")
            #expect(request.tool.id == "call" && request.tool.name == "write_file")
            #expect(request.tool.kind == .edit)
            #expect(request.tool.input == .complete(.object(["path": .string("example.txt")])))
            #expect(request.options.map(\.kind) == [.allowOnce, .rejectOnce])
            return .select(optionID: option)
        }
        try await harness.transport.inject(params: permissionParams())
        try await eventually { await harness.transport.writes.count == 1 }
        let result = try #require(await harness.transport.writes.first?["result"]?["outcome"])
        #expect(result["outcome"] == .string(option == "not-offered" ? "cancelled" : "selected"))
        #expect(result["optionId"] == (option == "not-offered" ? nil : .string(option)))
        await harness.close()
    }

    @Test(arguments: [false, true])
    func absentAndFailedCallbacksDenyWithoutLeakingErrors(throwing: Bool) async throws {
        let handler: PermissionRequests.Handler? = throwing ? { @Sendable _ in throw FxError.transport("private-host-detail") } : nil
        let harness = await PermissionHarness.open(handler: handler)
        try await harness.transport.inject(params: permissionParams())
        try await eventually { await harness.transport.writes.count == 1 }
        let reply = try #require(await harness.transport.writes.first)
        #expect(reply["result"]?["outcome"]?["outcome"] == .string("cancelled"))
        #expect(!String(describing: reply).contains("private-host-detail"))
        await harness.close()
    }

    @Test func foreignAndMalformedRequestsNeverReachTheCallback() async throws {
        let gate = PermissionGate()
        let harness = await PermissionHarness.open { await gate.choose($0) }
        let duplicate = JSONValue.array(Array(repeating: JSONValue.object([
            "optionId": .string("same"), "name": .string("Duplicate"), "kind": .string("allow_once"),
        ]), count: 2))
        for (index, params) in [permissionParams(session: "other"), .object(["sessionId": .string("session")]),
                                permissionParams(options: duplicate)].enumerated() {
            try await harness.transport.inject(id: index + 100, params: params)
        }
        try await eventually { await harness.transport.writes.count == 3 }
        #expect(await gate.calls.isEmpty)
        #expect(await harness.transport.writes.first?["error"] != nil)
        await harness.close()
    }

    @Test func cancellationSuppressesLateApprovalAndAllowsAnotherScope() async throws {
        let gate = PermissionGate()
        let harness = await PermissionHarness.open { await gate.choose($0) }
        try await harness.transport.inject(params: permissionParams())
        try await eventually { await gate.calls.count == 1 }
        await harness.requests.cancel(scope: harness.scope)
        let nextScope = UUID()
        await harness.requests.handle(id: .number(101), params: permissionParams(), turnID: "next-turn", scope: nextScope, isActive: { true })
        try await eventually { await gate.calls.count == 2 }
        // A second cleanup from the old turn must not cancel the new request.
        await harness.requests.cancel(scope: harness.scope)
        await gate.release()
        try await eventually { await harness.requests.pendingCount == 0 }
        let replies = await harness.transport.writes
        #expect(replies.count == 1 && replies.first?["id"] == .number(101))
        #expect(replies.first?["result"]?["outcome"]?["optionId"] == .string("allow"))
        await harness.close()
    }

    @Test func closingWhileACallbackWaitsSuppressesItsLateReply() async throws {
        let gate = PermissionGate()
        let harness = await PermissionHarness.open { await gate.choose($0) }
        try await harness.transport.inject(params: permissionParams())
        try await eventually { await gate.calls.count == 1 }
        await harness.close()
        await gate.release()
        try await eventually { await harness.requests.pendingCount == 0 }
        #expect(await harness.transport.writes.isEmpty)
    }

    @Test func permissionDisplayInputIsBounded() throws {
        let input = JSONValue.object(["content": .string(String(repeating: "中", count: 64 * 1024))])
        let request = try FxPermissionRequest(permissionParams(input: input), turnID: "turn")
        guard case .truncated(let preview) = request.tool.input else { Issue.record("Expected a bounded preview"); return }
        #expect(preview.utf8.count <= 64 * 1024 && !preview.contains("�"))
    }

    @Test func anEndedTurnCannotApproveAWaitingRequest() async throws {
        let gate = PermissionGate(), activity = PermissionActivity()
        let harness = await PermissionHarness.open(handler: { await gate.choose($0) }, active: { await activity.active })
        try await harness.transport.inject(params: permissionParams())
        try await eventually { await gate.calls.count == 1 }
        await activity.end()
        await gate.release()
        try await eventually { await harness.requests.pendingCount == 0 }
        #expect(await harness.transport.writes.isEmpty)
        await harness.close()
    }

    @Test func cancellationAtTheReplyBoundaryPreventsApprovalWrites() async throws {
        let transport = PermissionTransport()
        let rpc = RPCClient(transport: transport, observer: { direction, message in
            if direction == .sent, message["id"] == .number(100) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })
        let requests = PermissionRequests(sessionID: "session", rpc: rpc, handler: { _ in .select(optionID: "allow") })
        await requests.handle(id: .number(100), params: permissionParams(), turnID: "turn", scope: UUID(), isActive: { true })
        try await eventually { await requests.pendingCount == 0 }
        #expect(await transport.writes.isEmpty)
        await rpc.close()
    }

    @Test func waitingForPermissionDoesNotBlockRPCResponses() async throws {
        let gate = PermissionGate()
        let harness = await PermissionHarness.open { await gate.choose($0) }
        try await harness.transport.inject(params: permissionParams())
        try await eventually { await gate.calls.count == 1 }
        #expect(try await harness.rpc.request("echo") == .bool(true))
        await gate.release()
        try await eventually { await harness.requests.pendingCount == 0 }
        #expect(await harness.transport.writes.contains { $0["id"] == .number(100) && $0["result"]?["outcome"]?["optionId"] == .string("allow") })
        await harness.close()
    }
}
