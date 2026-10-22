import Foundation
import Testing
@testable import LibFx

private final class ToolObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FxObservation] = []
    private var errors = 0
    var events: [FxObservation] { lock.withLock { stored } }
    var errorCount: Int { lock.withLock { errors } }
    func record(_ event: FxObservation) { lock.withLock { stored.append(event) } }
    func failed() { lock.withLock { errors += 1 } }
}

private func toolScope(options: FxObservationOptions) throws -> FxToolObservation {
    let scope = try FxObservation(raw: .object([
        "version": .number(1), "type": .string("tool.start"), "sessionId": .string("session"),
        "rootSessionId": .string("root"), "turnId": .string("turn"), "executionId": .string("execution"),
        "stepIndex": .number(2), "timestamp": .number(1_790_000_000_000),
        "contentCaptured": .bool(false), "contentTruncated": .bool(false), "data": .object([:]),
    ]))
    return try FxToolObservation(scope: scope, callID: "call", options: options)
}

private final class EffectFailure: Error, Sendable, CustomStringConvertible {
    var description: String { "private-credential-and-content" }
}

private actor PausedObservedEffect {
    private var continuation: CheckedContinuation<Int, Never>?
    func run() async -> Int { await withCheckedContinuation { continuation = $0 } }
    func waitUntilRunning() async { while continuation == nil { await Task.yield() } }
    func finish() { continuation?.resume(returning: 42); continuation = nil }
}

@Test func toolMCPObservationPreservesValuesErrorsAndChildIdentity() async throws {
    let events = ToolObservations()
    let tool = try toolScope(options: FxObservationOptions(captureContent: true, onEvent: { event in
        events.record(event)
        throw EffectFailure()
    }, onError: { _ in events.failed() }))
    let answer = await tool.mcp(server: "server", tool: "remote.echo", correlationID: "correlation", isError: { $0 == 42 }) { 42 }
    #expect(answer == 42)
    let failure = EffectFailure()
    do {
        _ = try await tool.mcp(tool: "remote.error") { () async throws -> Int in throw failure }
        Issue.record("Expected original effect failure")
    } catch { #expect((error as? EffectFailure) === failure) }
    #expect(events.errorCount == events.events.count)
    #expect(events.events.map(\.kind) == [.mcpStarted, .mcpRequest, .mcpEnded, .mcpStarted, .mcpEnded])
    #expect(events.events.allSatisfy { $0.sessionID == "session" && $0.rootSessionID == "root" && $0.executionID == "execution" && $0.turnID == "turn" })
    #expect(events.events.allSatisfy { $0.contentCaptured && !$0.contentTruncated })
    #expect(events.events[0].data["tool"] == .string("remote.echo"))
    #expect(events.events[0].data["callId"] == .string("call"))
    #expect(events.events[0].data["operationId"] == events.events[2].data["operationId"])
    #expect(events.events[2].data["status"] == .string("failure"))
    #expect(!String(decoding: try JSONEncoder().encode(events.events), as: UTF8.self).contains(failure.description))
    #expect(tool.childOptions().captureContent)
    #expect(tool.childOptions().parent == (try FxObservationParent(rootSessionID: "root", sessionID: "session", turnID: "turn", callID: "call")))
}

@Test func toolMCPObservationCancellationEndsBeforeLateEffectSettles() async throws {
    let events = ToolObservations()
    let scope = try toolScope(options: FxObservationOptions(onEvent: events.record))
    let effect = PausedObservedEffect()
    let task = Task { await scope.mcp(tool: "remote.wait") { await effect.run() } }
    await effect.waitUntilRunning()
    task.cancel()
    #expect(events.events.map(\.kind) == [.mcpStarted, .mcpEnded])
    #expect(events.events.last?.data["status"] == .string("cancelled"))
    await effect.finish()
    #expect(await task.value == 42)
    #expect(events.events.count == 2)
    scope.invalidate()
    #expect(await scope.mcp(tool: "after-close") { 9 } == 9)
    #expect(events.events.count == 2)
}

@Test func toolMCPObservationInvalidationEndsAllConcurrentOperations() async throws {
    let events = ToolObservations()
    let scope = try toolScope(options: FxObservationOptions(onEvent: events.record))
    let first = PausedObservedEffect(), second = PausedObservedEffect()
    let a = Task { await scope.mcp(tool: "a") { await first.run() } }
    let b = Task { await scope.mcp(tool: "b") { await second.run() } }
    await first.waitUntilRunning(); await second.waitUntilRunning()
    scope.invalidate()
    let endings = events.events.filter { $0.kind == .mcpEnded }
    #expect(endings.count == 2)
    #expect(Set(endings.compactMap { $0.data["operationId"]?.string }).count == 2)
    #expect(endings.allSatisfy { $0.data["status"] == .string("cancelled") })
    await first.finish(); await second.finish()
    #expect(await a.value == 42)
    #expect(await b.value == 42)
    #expect(events.events.count == 4)
}

private final class ObservationHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FxToolObservation?
    var value: FxToolObservation? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Test func toolObserverCanInvalidateFromAnotherThreadWithoutHoldingItsStateLock() async throws {
    let events = ToolObservations(), holder = ObservationHolder()
    let scope = try toolScope(options: FxObservationOptions(onEvent: { event in
        events.record(event)
        if event.kind == .mcpStarted {
            DispatchQueue.global().sync { holder.value?.invalidate() }
        }
    }))
    holder.value = scope
    #expect(await scope.mcp(tool: "reentrant") { 7 } == 7)
    #expect(events.events.map(\.kind) == [.mcpStarted, .mcpEnded])
    #expect(events.events.last?.data["status"] == .string("cancelled"))
}

private actor ObservedWaitEffects {
    private(set) var calls = 0
    func run() -> Int { calls += 1; return 42 }
}

private final class ObservedWaitDecision: Sendable {
    let value = 42
    let answers = ["no"]
}

@Test func inputWaitsKeepTypedResultsErrorsAndObserverIsolation() async throws {
    let events = ToolObservations(), effects = ObservedWaitEffects()
    let scope = try toolScope(options: FxObservationOptions(captureContent: true, onEvent: { event in
        events.record(event)
        throw EffectFailure()
    }, onError: { _ in events.failed() }))
    let decision = ObservedWaitDecision()
    for kind in [FxWaitRequest.Kind.approval, .question, .mcpForm, .mcpURL] {
        let returned = await scope.wait(FxWaitRequest(kind: kind, externalID: "external", server: "server", prompt: "Continue?"),
                                        resolution: { FxWaitResolution(outcome: .denied, answers: $0.answers) }) {
            _ = await effects.run()
            return decision
        }
        #expect(returned === decision && returned.value == 42)
    }
    let failure = EffectFailure()
    for timeout in [false, true] {
        do {
            _ = try await scope.wait(FxWaitRequest(kind: .question), failure: { _ in timeout ? .timedOut : .failed }) {
                () async throws -> Int in
                _ = await effects.run()
                throw failure
            }
            Issue.record("Expected the original wait error")
        } catch { #expect((error as? EffectFailure) === failure) }
    }
    #expect(await effects.calls == 6)
    #expect(events.errorCount == events.events.count)
    let starts = events.events.filter { $0.kind == .waitStarted }, ends = events.events.filter { $0.kind == .waitEnded }
    #expect(starts.count == 6 && ends.count == 6)
    #expect(Set(starts.compactMap { $0.data["requestId"]?.string }).count == 6)
    #expect(starts.map { $0.data["requestId"] } == ends.map { $0.data["requestId"] })
    #expect(ends.map { $0.data["outcome"] } == Array(repeating: .string("denied"), count: 4) + [.string("failed"), .string("timed_out")])
    #expect(ends[0].data["answers"] == .array([.string("no")]))
    #expect(starts.allSatisfy { $0.data["callId"] == .string("call") && $0.executionID == "execution" && $0.turnID == "turn" })
    #expect(!String(decoding: try JSONEncoder().encode(events.events), as: UTF8.self).contains(failure.description))
}

@Test func inputWaitContentHasOneUTF8BudgetPerEventAndLeavesTheEffectIntact() async throws {
    for captureContent in [false, true] {
        let events = ToolObservations()
        let scope = try toolScope(options: FxObservationOptions(captureContent: captureContent, onEvent: events.record))
        let schema = String(repeating: "a", count: 65_535) + "🙂"
        let answers = [schema, "文", "x"]
        let request = FxWaitRequest(kind: .mcpForm, schemaJSON: schema, prompt: "文", questions: [
            .init("q", options: [.init(label: "label", description: "description")]),
        ])
        let value = await scope.wait(request, resolution: { FxWaitResolution(answers: $0) }) { answers }
        #expect(value == answers)
        let start = try #require(events.events.first), end = try #require(events.events.last)
        #expect(start.contentCaptured == captureContent && end.contentCaptured == captureContent)
        #expect(start.contentTruncated == captureContent && end.contentTruncated == captureContent)
        if captureContent {
            #expect(start.data["schemaJson"] == .string(String(repeating: "a", count: 65_535)))
            #expect(start.data["prompt"] == .string(""))
            guard case .array(let questions) = start.data["questions"],
                  case .array(let options) = questions.first?["options"] else { Issue.record("Missing captured questions"); return }
            #expect(questions.first?["question"] == .string("q"))
            #expect(options.first?["label"] == .string(""))
            #expect(options.first?["description"] == .string(""))
            #expect(end.data["answers"] == .array([.string(String(repeating: "a", count: 65_535)), .string(""), .string("x")]))
        } else {
            #expect(start.data["schemaJson"] == nil && start.data["prompt"] == nil && start.data["questions"] == nil)
            #expect(end.data["answers"] == nil)
        }
    }
}

@Test func inputWaitCollectionLimitsRetainOriginalCountsAndDecisions() async throws {
    for captureContent in [false, true] {
        for (questionCount, optionCount, answerCount) in [(129, 1, 1), (1, 129, 1), (1, 1, 129), (128, 128, 128), (129, 129, 129)] {
            let events = ToolObservations()
            let scope = try toolScope(options: FxObservationOptions(captureContent: captureContent, onEvent: events.record))
            let request = FxWaitRequest(kind: .question, questions: Array(repeating:
                .init("", options: Array(repeating: .init(label: ""), count: optionCount)), count: questionCount))
            let answers = Array(repeating: "", count: answerCount)
            #expect(await scope.wait(request, resolution: { FxWaitResolution(answers: $0) }) { answers } == answers)
            let start = try #require(events.events.first), end = try #require(events.events.last)
            #expect(start.data["questionCount"] == .number(Double(questionCount)))
            #expect(start.contentTruncated == (questionCount > 128 || optionCount > 128))
            #expect(end.contentTruncated == (answerCount > 128))
            if captureContent {
                guard case .array(let questions) = start.data["questions"],
                      case .array(let options) = questions.first?["options"],
                      case .array(let capturedAnswers) = end.data["answers"] else { Issue.record("Missing captured arrays"); return }
                #expect(questions.count == min(questionCount, 128))
                #expect(options.count == min(optionCount, 128))
                #expect(capturedAnswers.count == min(answerCount, 128))
            } else {
                #expect(start.data["questions"] == nil && end.data["answers"] == nil)
            }
        }
    }
}

@Test func inputWaitCancellationPreservesALateAnswerAndEndsOnlyOnce() async throws {
    let events = ToolObservations(), effect = PausedObservedEffect()
    let scope = try toolScope(options: FxObservationOptions(captureContent: true, onEvent: events.record))
    let task = Task { await scope.wait(FxWaitRequest(kind: .approval, prompt: "Approve?"),
                                       resolution: { _ in FxWaitResolution(answers: ["late answer"]) }) { await effect.run() } }
    await effect.waitUntilRunning()
    task.cancel()
    #expect(events.events.map(\.kind) == [.waitStarted, .waitEnded])
    #expect(events.events.last?.data["outcome"] == .string("cancelled"))
    #expect(events.events.last?.data["answers"] == .array([]))
    await effect.finish()
    #expect(await task.value == 42)
    #expect(events.events.count == 2)
    scope.invalidate()
    #expect(await scope.wait(FxWaitRequest(kind: .question), resolution: { _ in
        events.failed()
        return FxWaitResolution()
    }) { "after close" } == "after close")
    #expect(events.events.count == 2 && events.errorCount == 0)
}

@Test func inputWaitAlreadyCancelledTaskStillCallsTheEffectOnceWithoutObservation() async throws {
    let events = ToolObservations(), gate = PausedObservedEffect(), effects = ObservedWaitEffects()
    let scope = try toolScope(options: FxObservationOptions(onEvent: events.record))
    let task = Task {
        _ = await gate.run()
        return await scope.wait(FxWaitRequest(kind: .question)) { await effects.run() }
    }
    await gate.waitUntilRunning()
    task.cancel()
    await gate.finish()
    #expect(await task.value == 42)
    #expect(await effects.calls == 1)
    #expect(events.events.isEmpty)
}

@Test func invalidatingMixedMCPAndInputWaitsKeepsTheirTerminalKinds() async throws {
    let events = ToolObservations(), mcp = PausedObservedEffect(), input = PausedObservedEffect()
    let scope = try toolScope(options: FxObservationOptions(onEvent: events.record))
    let a = Task { await scope.mcp(tool: "mcp") { await mcp.run() } }
    let b = Task { await scope.wait(FxWaitRequest(kind: .mcpURL)) { await input.run() } }
    await mcp.waitUntilRunning(); await input.waitUntilRunning()
    scope.invalidate()
    let ends = events.events.filter { $0.kind == .mcpEnded || $0.kind == .waitEnded }
    #expect(ends.count == 2)
    let mcpEnd = try #require(ends.first { $0.kind == .mcpEnded }), waitEnd = try #require(ends.first { $0.kind == .waitEnded })
    #expect(mcpEnd.data["status"] == .string("cancelled") && mcpEnd.data["operationId"] != nil && mcpEnd.data["requestId"] == nil)
    #expect(waitEnd.data["outcome"] == .string("cancelled") && waitEnd.data["requestId"] != nil && waitEnd.data["operationId"] == nil)
    await mcp.finish(); await input.finish()
    #expect(await a.value == 42)
    #expect(await b.value == 42)
    #expect(events.events.count == 4)
}
