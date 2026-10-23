import Foundation
import Testing
@testable import LibFx

private let approvalInput = JSONValue.object(["value": .string("payload")])
private let approvalContext = FxToolContext(executionID: "execution", sessionID: "session", turnID: "turn",
                                            context: .object(["host": .string("context")]))

private actor ApprovalProbe {
    var decision: FxToolApproval.Decision
    private(set) var requests: [FxToolApproval.Request] = []
    private(set) var calls: [(JSONValue, FxToolContext)] = []
    init(_ decision: FxToolApproval.Decision) { self.decision = decision }
    func approve(_ request: FxToolApproval.Request) -> FxToolApproval.Decision {
        requests.append(request)
        return decision
    }
    func execute(_ input: JSONValue, _ context: FxToolContext) -> FxToolResult {
        calls.append((input, context))
        return FxToolResult(text: "result", isError: true)
    }
    func tool(name: String = "save", writes: Bool? = true) -> FxTool {
        FxTool(name: name, description: "Save a value", inputSchema: .object(["type": .string("object")]),
               isIdempotent: false, writes: writes) { input, context in await self.execute(input, context) }
    }
}

private actor PendingApproval {
    private var response: CheckedContinuation<FxToolApproval.Decision, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var started = false

    func approve(_ request: FxToolApproval.Request) async -> FxToolApproval.Decision {
        await withCheckedContinuation {
            response = $0
            started = true
            entered?.resume()
            entered = nil
        }
    }
    func waitUntilEntered() async {
        if !started { await withCheckedContinuation { entered = $0 } }
    }
    func resolve(_ decision: FxToolApproval.Decision) {
        response?.resume(returning: decision)
        response = nil
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ToolApprovalTests {
    @Test(arguments: [FxToolEffect.readOnly, .write, .dangerous],
          [FxToolApproval.Decision.allowOnce, .allowPlugin, .deny])
    func effectPolicy(effect: FxToolEffect, decision: FxToolApproval.Decision) async throws {
        let probe = ApprovalProbe(decision)
        let approval = FxToolApproval { await probe.approve($0) }
        let tool = approval.wrap(tool: await probe.tool(), pluginID: "one", effect: effect)
        for _ in 0..<2 {
            if effect != .readOnly, decision == .deny {
                await #expect(throws: FxToolApproval.Failure.denied) {
                    try await tool.execute(approvalInput, approvalContext)
                }
            } else {
                #expect(try await tool.execute(approvalInput, approvalContext) == FxToolResult(text: "result", isError: true))
            }
        }
        let expectedApprovals = effect == .readOnly ? 0 : effect == .write && decision == .allowPlugin ? 1 : 2
        #expect(await probe.requests.count == expectedApprovals)
        #expect(await probe.calls.count == (effect != .readOnly && decision == .deny ? 0 : 2))
        #expect(await approval.allowedPlugins == (effect == .write && decision == .allowPlugin ? ["one"] : []))
    }

    @Test(arguments: [nil, false, true] as [Bool?])
    func preservesDescriptorInputContextAndResult(writes: Bool?) async throws {
        let probe = ApprovalProbe(.allowOnce)
        let approval = FxToolApproval { await probe.approve($0) }
        let original = await probe.tool(writes: writes)
        let tool = approval.wrap(tool: original, pluginID: "one", effect: .write)
        #expect(tool.descriptor == original.descriptor)
        #expect(tool.isIdempotent == original.isIdempotent)
        #expect(tool.writes == original.writes)
        #expect(try await tool.execute(approvalInput, approvalContext) == FxToolResult(text: "result", isError: true))
        let request = try #require(await probe.requests.first)
        #expect(request.pluginID == "one" && request.toolName == original.name && request.effect == .write)
        #expect(request.input == approvalInput)
        let call = try #require(await probe.calls.first)
        #expect(call.0 == approvalInput)
        for context in [request.context, call.1] {
            #expect(context.executionID == approvalContext.executionID)
            #expect(context.sessionID == approvalContext.sessionID)
            #expect(context.turnID == approvalContext.turnID)
            #expect(context.context == approvalContext.context)
        }
        #expect(await probe.calls.count == 1)
    }

    @Test func pluginGrantCoversOnlySamePluginWritesAndCanBeRevoked() async throws {
        let probe = ApprovalProbe(.allowPlugin)
        let approval = FxToolApproval { await probe.approve($0) }
        let original = await probe.tool()
        let first = approval.wrap(tool: original, pluginID: "one", effect: .write)
        _ = try await first.execute(approvalInput, approvalContext)
        let sibling = approval.wrap(tool: await probe.tool(name: "other"), pluginID: "one", effect: .write)
        _ = try await sibling.execute(approvalInput, approvalContext)
        #expect(await probe.requests.count == 1)
        let otherPlugin = approval.wrap(tool: original, pluginID: "two", effect: .write)
        _ = try await otherPlugin.execute(approvalInput, approvalContext)
        let dangerous = approval.wrap(tool: original, pluginID: "one", effect: .dangerous)
        _ = try await dangerous.execute(approvalInput, approvalContext)
        _ = try await dangerous.execute(approvalInput, approvalContext)
        #expect(await probe.requests.count == 4)
        await approval.revoke(pluginID: "one")
        #expect(await approval.allowedPlugins == ["two"])
        _ = try await first.execute(approvalInput, approvalContext)
        #expect(await probe.requests.count == 5)
    }

    @Test func hostCanRestoreWriteGrants() async throws {
        let probe = ApprovalProbe(.deny)
        let approval = FxToolApproval { await probe.approve($0) }
        await approval.allow(pluginID: "restored")
        let tool = approval.wrap(tool: await probe.tool(), pluginID: "restored", effect: .write)
        _ = try await tool.execute(approvalInput, approvalContext)
        #expect(await probe.requests.isEmpty)
        #expect(await approval.allowedPlugins == ["restored"])
        await approval.revoke(pluginID: "restored")
        await #expect(throws: FxToolApproval.Failure.denied) { try await tool.execute(approvalInput, approvalContext) }
        #expect(await probe.calls.count == 1)
    }

    @Test func revocationWhileWaitingCannotRestoreGrant() async throws {
        let pending = PendingApproval(), probe = ApprovalProbe(.deny)
        let approval = FxToolApproval { await pending.approve($0) }
        let tool = approval.wrap(tool: await probe.tool(), pluginID: "one", effect: .write)
        let call = Task { try await tool.execute(approvalInput, approvalContext) }
        await pending.waitUntilEntered()
        await approval.revoke(pluginID: "one")
        await pending.resolve(.allowPlugin)
        _ = try await call.value
        #expect(await approval.allowedPlugins.isEmpty)
        #expect(await probe.calls.count == 1)
    }

    @Test(arguments: [FxToolApproval.Decision.allowOnce, .allowPlugin])
    func cancellationWhileWaitingBlocksExecutionAndGrant(decision: FxToolApproval.Decision) async throws {
        let pending = PendingApproval(), probe = ApprovalProbe(.deny)
        let approval = FxToolApproval { await pending.approve($0) }
        let tool = approval.wrap(tool: await probe.tool(), pluginID: "one", effect: .write)
        let call = Task { try await tool.execute(approvalInput, approvalContext) }
        await pending.waitUntilEntered()
        call.cancel()
        await pending.resolve(decision)
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(await probe.calls.isEmpty)
        #expect(await approval.allowedPlugins.isEmpty)
    }

    @Test(arguments: [FxToolEffect.readOnly, .write, .dangerous])
    func alreadyCancelledNeverExecutes(effect: FxToolEffect) async throws {
        let probe = ApprovalProbe(.allowPlugin), gate = PendingApproval()
        let approval = FxToolApproval { await probe.approve($0) }
        await approval.allow(pluginID: "one")
        let tool = approval.wrap(tool: await probe.tool(), pluginID: "one", effect: effect)
        let call = Task {
            _ = await gate.approve(.init(pluginID: "gate", toolName: "gate", input: .null,
                                         context: approvalContext, effect: effect))
            return try await tool.execute(approvalInput, approvalContext)
        }
        await gate.waitUntilEntered()
        call.cancel()
        await gate.resolve(.allowOnce)
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(await probe.requests.isEmpty)
        #expect(await probe.calls.isEmpty)
    }

    private final class OriginalFailure: Error, Sendable {}

    @Test func callbackErrorPreventsExecutionAndPreservesError() async throws {
        let failure = OriginalFailure(), probe = ApprovalProbe(.deny)
        let approval = FxToolApproval { _ in throw failure }
        let tool = approval.wrap(tool: await probe.tool(), pluginID: "one", effect: .write)
        do {
            _ = try await tool.execute(approvalInput, approvalContext)
            Issue.record("Expected callback failure")
        } catch { #expect((error as? OriginalFailure) === failure) }
        #expect(await probe.calls.isEmpty)
        #expect(await approval.allowedPlugins.isEmpty)
    }

    @Test func originalClosureErrorIsPreservedWithoutRetry() async throws {
        let failure = OriginalFailure(), probe = ApprovalProbe(.allowOnce)
        let approval = FxToolApproval { await probe.approve($0) }
        let original = FxTool(name: "broken", description: "Failure probe", inputSchema: .object([:]), isIdempotent: true) { input, context in
            _ = await probe.execute(input, context)
            throw failure
        }
        let tool = approval.wrap(tool: original, pluginID: "one", effect: .write)
        do {
            _ = try await tool.execute(approvalInput, approvalContext)
            Issue.record("Expected original failure")
        } catch { #expect((error as? OriginalFailure) === failure) }
        #expect(await probe.calls.count == 1)
        #expect(await probe.requests.count == 1)
    }
}
