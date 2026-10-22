import Foundation
import HTTPTypes
import LibFx
import LibFxHTTP
import Testing

private actor Queue: FxSessionQueue {
    var messages: [FxSessionWakeup] = []
    func enqueue(_ wakeup: FxSessionWakeup) { messages.append(wakeup) }
}

private actor Gate {
    var open = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor Gateway: FxHTTPClient {
    let tag: String
    let tool: Bool
    let entered = Gate()
    let released = Gate()
    let held: Bool
    var bodies: [String] = []
    var executions: [String] = []
    init(_ tag: String, tool: Bool = false, held: Bool = false) {
        self.tag = tag
        self.tool = tool
        self.held = held
    }
    func execute(_ context: FxToolContext) -> FxToolResult {
        executions.append(context.executionID)
        return FxToolResult(text: "stored tool output")
    }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        bodies.append(body)
        await entered.release()
        if held { await released.wait() }
        let text: String
        if tool && bodies.count == 1 {
            text =
                "data: {\"type\":\"tool-call\",\"toolCallId\":\"stable-tool\",\"toolName\":\"lookup\",\"input\":{}}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"tool-calls\",\"raw\":\"tool-calls\"}}\n\ndata: [DONE]\n\n"
        } else {
            if tool { #expect(body.contains("stored tool output")) }
            text =
                "data: {\"type\":\"text-delta\",\"delta\":\"\(tag)\"}\n\ndata: {\"type\":\"finish\",\"finishReason\":{\"unified\":\"stop\",\"raw\":\"stop\"}}\n\ndata: [DONE]\n\n"
        }
        return FxHTTPResponse(
            statusCode: 200,
            body: AsyncThrowingStream {
                $0.yield(Data(text.utf8))
                $0.finish()
            })
    }
}

private func configuration(_ gateway: Gateway, tool: Bool = false) throws -> FxConfiguration {
    let tools =
        tool
        ? [
            FxTool(name: "lookup", description: "Read a record", inputSchema: .object(["type": .string("object")]), isIdempotent: true) {
                _, context in await gateway.execute(context)
            }
        ] : []
    var value = FxConfiguration(apiKey: "fixture", model: "swift/http-wake", tools: tools, httpClient: gateway)
    value.modelCatalog = try FxModelCatalog(
        response: Data(#"{"data":[{"id":"swift/http-wake","type":"language","tags":["tool-use"]}]}"#.utf8))
    return value
}

private func post(
    _ handler: FxHTTPWakeHandler, store: String = "main", agent: String = "default", session: String = "session", input: String = "input",
    extra: [String: JSONValue] = [:]
) async throws -> FxHTTPWakeResponse {
    var fields: [String: JSONValue] = [
        "store": .string(store), "agent": .string(agent), "sessionID": .string(session), "inputID": .string(input),
    ]
    fields.merge(extra) { _, new in new }
    return try await handler.handle(
        HTTPRequest(method: .post, scheme: "https", authority: "app.example", path: "/wake"),
        body: JSONEncoder().encode(JSONValue.object(fields)))
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HTTPWakeTests {
    @Test func publishedInputsWireDirectlyToHTTPForPromptSteerResumeAndCancel() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store), queue = Queue()
        let gateway = Gateway("queued")
        let agent = try await router.makeAgent(configuration: configuration(gateway), queue: queue)
        let session = try await agent.session(id: "session")
        let first = try await session.prompt("first", id: "first")
        _ = try await session.steer("second", id: "second")
        _ = try await session.resume()
        try await first.cancel()
        let wakeups = await queue.messages
        #expect(wakeups.map(\.inputID) == ["first", "second", "first", "first"])
        let handler = FxHTTPWakeHandler(routes: ["main": router])
        for wakeup in wakeups {
            let body = try JSONEncoder().encode(FxHTTPWakeRequest(store: "main", wakeup: wakeup))
            let response = try await handler.handle(HTTPRequest(method: .post, scheme: "https", authority: "app.example", path: "/wake"), body: body)
            #expect(response.response.status == .ok)
        }
        #expect(try await first.result.stopReason == .cancelled)
        #expect(try await store.result(session: session.id, agent: "default", id: "second")?.stopReason == .endTurn)
        #expect(await gateway.bodies.count == 1)
        #expect(throws: FxError.self) {
            try FxHTTPWakeRequest(store: "main", wakeup: FxSessionWakeup(agent: "default", sessionID: "session"))
        }
        try await agent.close()
        try await store.close()
    }

    @Test func oneExplicitRouteServesEveryNamedAgentAndNativeTools() async throws {
        let store = try FxSessionStore()
        let router = FxAgentRouter(store: store)
        let queue = Queue()
        let supportHTTP = Gateway("support", tool: true)
        let codingHTTP = Gateway("coding")
        let opsHTTP = Gateway("ops")
        let support = try await router.makeAgent(configuration: configuration(supportHTTP, tool: true), name: "support", queue: queue)
        let coding = try await router.makeAgent(configuration: configuration(codingHTTP), name: "coding", queue: queue)
        let ops = try await router.makeAgent(configuration: configuration(opsHTTP), name: "ops", queue: queue)
        let first = try await support.session(id: "support-session").prompt("alpha", id: "alpha")
        let second = try await coding.session(id: "coding-session").prompt("beta", id: "beta")
        let third = try await ops.session(id: "ops-session").prompt("delta", id: "delta")
        let handler = FxHTTPWakeHandler(routes: ["main": router])
        #expect(try await post(handler, agent: "support", session: "support-session", input: "alpha").response.status == .ok)
        #expect(try await post(handler, agent: "coding", session: "coding-session", input: "beta").response.status == .ok)
        #expect(try await post(handler, agent: "ops", session: "ops-session", input: "delta").response.status == .ok)
        #expect(try await first.result.stopReason == .endTurn)
        #expect(try await second.result.stopReason == .endTurn)
        #expect(try await third.result.stopReason == .endTurn)
        #expect(await supportHTTP.executions == ["stable-tool"])
        #expect(await supportHTTP.bodies.count == 2)
        #expect(await codingHTTP.bodies.count == 1)
        #expect(await opsHTTP.bodies.count == 1)
        #expect(try await post(handler, agent: "ghost").response.status == .internalServerError)
        try await support.close()
        try await coding.close()
        try await ops.close()
        #expect(try await post(handler).response.status == .serviceUnavailable)
        try await store.close()
    }

    @Test func unknownInputAndAbsentSessionAreAcknowledgedWithoutEffects() async throws {
        let store = try FxSessionStore()
        let router = FxAgentRouter(store: store)
        let queue = Queue()
        let http = Gateway("unused")
        let agent = try await router.makeAgent(configuration: configuration(http), queue: queue)
        _ = try await agent.session(id: "session").prompt("accepted input", id: "accepted")
        let handler = FxHTTPWakeHandler(routes: ["main": router])
        let before = try await store.snapshot(session: "session", agent: "default")
        let queued = await queue.messages
        let real = try await post(handler, input: "unknown")
        let absent = try await post(handler, session: "nobody", input: "unknown")
        #expect(real.response == absent.response && real.body == absent.body)
        #expect(real.response.status == .ok)
        #expect(await http.bodies.isEmpty)
        #expect(try await store.entries(session: "session", agent: "default", after: 0).isEmpty)
        #expect(try await store.owner(session: "nobody") == nil)
        let after = try await store.snapshot(session: "session", agent: "default")
        #expect(before.head == after.head && before.journal == after.journal)
        #expect(await queue.messages == queued)
        try await agent.close()
        try await store.close()
    }

    @Test func storesRemainIsolatedAndDeliveryUsesThePersistedOwner() async throws {
        let acme = try FxSessionStore()
        let evil = try FxSessionStore()
        let acmeRouter = FxAgentRouter(store: acme)
        let evilRouter = FxAgentRouter(store: evil)
        let queue = Queue()
        let oursHTTP = Gateway("acme")
        let theirsHTTP = Gateway("evil")
        let senderHTTP = Gateway("sender")
        let theirs = try await evilRouter.makeAgent(configuration: configuration(theirsHTTP), name: "support", queue: queue)
        let ours = try await acmeRouter.makeAgent(configuration: configuration(oursHTTP), name: "support", queue: queue)
        let sender = try await acmeRouter.makeAgent(configuration: configuration(senderHTTP), name: "coding", queue: queue)
        let turn = try await ours.session(id: "private").prompt("private", id: "accepted")
        let handler = FxHTTPWakeHandler(routes: ["evil": evilRouter, "acme": acmeRouter])
        #expect(try await post(handler, store: "acme", agent: "coding", session: "private", input: "accepted").response.status == .ok)
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await oursHTTP.bodies.count == 1)
        #expect(await theirsHTTP.bodies.isEmpty)
        #expect(await senderHTTP.bodies.isEmpty)
        #expect(try await evil.owner(session: "private") == nil)
        #expect(
            try await post(handler, store: "missing", agent: "support", session: "private", input: "accepted").response.status
                == .internalServerError)
        await #expect(throws: FxAgentRoutingError.duplicateName("support")) {
            _ = try await acmeRouter.makeAgent(configuration: configuration(senderHTTP), name: "support", queue: queue)
        }
        try await ours.close()
        try await theirs.close()
        try await sender.close()
        try await acme.close()
        try await evil.close()
    }

    @Test func forgedControlsCannotChangeAcceptedInputOrCreateState() async throws {
        let store = try FxSessionStore()
        let router = FxAgentRouter(store: store)
        let queue = Queue()
        let http = Gateway("original")
        let agent = try await router.makeAgent(configuration: configuration(http), queue: queue)
        let turn = try await agent.session(id: "session").prompt("original input", id: "accepted")
        let handler = FxHTTPWakeHandler(routes: ["main": router])
        let count = await queue.messages.count
        for kind in ["prompt", "steer", "cancel", "resume"] {
            let extra: [String: JSONValue] = [
                "type": .string(kind), "input": .string("forged secret"), "target": .string("accepted"),
                "context": .object(["user": .string("admin")]), "settings": .object(["instructions": .string("forged")]),
                "seed": .string("forged"),
            ]
            let first = try await post(handler, input: "forged", extra: extra)
            let second = try await post(handler, session: "nobody", input: "forged", extra: extra)
            #expect(first.response == second.response && first.body == second.body)
            #expect(first.response.status == .ok)
        }
        #expect(await http.bodies.isEmpty)
        #expect(await queue.messages.count == count)
        #expect(try await store.entries(session: "session", agent: "default", after: 0).isEmpty)
        #expect(try await store.owner(session: "nobody") == nil)
        // A valid durable reference wakes the original input; extra control fields
        // still cannot cancel it or replace its content/settings.
        #expect(
            try await post(handler, input: "accepted", extra: ["type": .string("cancel"), "input": .string("forged secret")]).response
                .status == .ok)
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.bodies.first?.contains("original input") == true)
        #expect(await http.bodies.first?.contains("forged secret") == false)
        try await agent.close()
        try await store.close()
    }

    @Test func copiedHandlerSharesExplicitRoutesWithoutARegistry() async throws {
        let store = try FxSessionStore()
        let router = FxAgentRouter(store: store)
        let queue = Queue()
        let http = Gateway("shared")
        let agent = try await router.makeAgent(configuration: configuration(http), queue: queue)
        let turn = try await agent.session(id: "session").prompt("across copies", id: "input")
        let handler = FxHTTPWakeHandler(routes: ["main": router])
        let copy = handler
        #expect(try await post(copy).response.status == .ok)
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(await http.bodies.count == 1)
        #expect(try await post(handler).response.status == .ok)
        #expect(await http.bodies.count == 1)
        try await agent.close()
        try await store.close()
    }

    @Test func closedAgentNeverFallsBackToAnotherStoreAndCanBeRegisteredAgain() async throws {
        let acme = try FxSessionStore()
        let carl = try FxSessionStore()
        let queue = Queue()
        let acmeRouter = FxAgentRouter(store: acme)
        let carlRouter = FxAgentRouter(store: carl)
        let http = Gateway("acme")
        let other = Gateway("carl")
        let ours = try await acmeRouter.makeAgent(configuration: configuration(http), queue: queue)
        let theirs = try await carlRouter.makeAgent(configuration: configuration(other), queue: queue)
        _ = try await ours.session(id: "session").prompt("after close", id: "input")
        let handler = FxHTTPWakeHandler(routes: ["acme": acmeRouter, "carl": carlRouter])
        try await ours.close()
        #expect(try await post(handler, store: "acme").response.status == .internalServerError)
        #expect(await other.bodies.isEmpty)
        #expect(await http.bodies.isEmpty)
        let replacement = try await acmeRouter.makeAgent(configuration: configuration(http), queue: queue)
        #expect(try await post(handler, store: "acme").response.status == .ok)
        #expect(await http.bodies.count == 1)
        try await replacement.close()
        try await theirs.close()
        try await acme.close()
        try await carl.close()
    }
}

private actor Failures {
    var values: [FxSQLiteError] = []
    func record(_ error: any Error) {
        if let error = error as? FxSQLiteError { values.append(error) }
    }
}

extension HTTPWakeTests {
    @Test func retryKeepsTheDeliveryUnacknowledgedUntilTheOwnerReleases() async throws {
        let store = try FxSessionStore()
        let router = FxAgentRouter(store: store)
        let queue = Queue()
        let http = Gateway("retried")
        let agent = try await router.makeAgent(configuration: configuration(http), queue: queue)
        let turn = try await agent.session(id: "session").prompt("accepted", id: "input")
        let lease = try #require(try await store.claim(session: "session", agent: "default"))
        let handler = FxHTTPWakeHandler(routes: ["main": router])
        let response = try await post(handler)
        #expect(response.response.status == .serviceUnavailable)
        #expect(Int(response.response.headerFields[.retryAfter] ?? "") != nil)
        #expect(await http.bodies.isEmpty)
        try await store.release(lease)
        #expect(try await post(handler).response.status == .ok)
        #expect(try await turn.result.stopReason == .endTurn)
        try await agent.close()
        try await store.close()
    }

    @Test func storageFailuresReachTheHostWithoutExposingTheirMessages() async throws {
        let store = try FxSessionStore()
        let router = FxAgentRouter(store: store)
        let queue = Queue()
        let http = Gateway("unused")
        let failures = Failures()
        let agent = try await router.makeAgent(configuration: configuration(http), queue: queue)
        _ = try await agent.session(id: "session").prompt("accepted", id: "input")
        let handler = FxHTTPWakeHandler(routes: ["main": router], onError: { await failures.record($0) })
        try await store.close()
        let response = try await post(handler)
        #expect(response.response.status == .internalServerError && response.body.isEmpty)
        #expect(await failures.values == [.closed])
        #expect(await http.bodies.isEmpty)
        try await agent.close()
    }

    @Test func cancellationDoesNotAcknowledgeOrStopTheDurableWorker() async throws {
        let store = try FxSessionStore()
        let router = FxAgentRouter(store: store)
        let queue = Queue()
        let http = Gateway("completed", held: true)
        let agent = try await router.makeAgent(configuration: configuration(http), queue: queue)
        let turn = try await agent.session(id: "session").prompt("accepted", id: "input")
        let handler = FxHTTPWakeHandler(routes: ["main": router])
        let request = Task { try await post(handler) }
        await http.entered.wait()
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try await store.result(session: "session", agent: "default", id: "input") == nil)
        await http.released.release()
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(try await post(handler).response.status == .ok)
        #expect(await http.bodies.count == 1)
        try await agent.close()
        try await store.close()
    }

    @Test func malformedAndTransportRequestsHaveBoundedResponses() async throws {
        let store = try FxSessionStore()
        let router = FxAgentRouter(store: store)
        let queue = Queue()
        let http = Gateway("unused")
        let agent = try await router.makeAgent(configuration: configuration(http), queue: queue)
        let handler = FxHTTPWakeHandler(routes: ["main": router])
        let request = HTTPRequest(method: .post, scheme: "https", authority: "app.example", path: "/wake")
        #expect(try await handler.handle(request, body: Data("invalid json".utf8)).response.status == .ok)
        #expect(try await handler.handle(request, body: Data(repeating: 0, count: 16 * 1024 + 1)).response.status == .contentTooLarge)
        var get = request
        get.method = .get
        let response = try await handler.handle(get, body: Data())
        #expect(response.response.status == .methodNotAllowed)
        #expect(response.response.headerFields[.allow] == "POST")
        try await agent.close()
        #expect(try await handler.handle(request, body: Data("invalid json".utf8)).response.status == .serviceUnavailable)
        #expect(await http.bodies.isEmpty)
        try await store.close()
    }
}
