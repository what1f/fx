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
