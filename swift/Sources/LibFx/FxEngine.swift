import Foundation

/// One conversation backed by the native fx core. Call close when the conversation ends.
public actor FxEngine {
    public nonisolated let sessionID: String
    private let rpc: RPCClient
    private let transport: NativeTransport
    private let tools: [String: FxTool]
    private let permissions: PermissionRequests
    private let journal: JournalWriter?
    private let observation: FxObservationOptions?
    private let onLifecycleEvent: (@Sendable (FxLifecycleEvent) -> Void)?
    private let checkpointAfterBytes: Int?
    private let checkpointMetadata: CheckpointMetadata
    private var recovery: FxRecoveryState?
    private var followUps: [QueuedFollowUp] = []
    private var followUpAcceptances: [String: FxFollowUp] = [:]
    private var activeFollowUpID: String?
    private var followUpAcceptanceTask: Task<Void, Never>?
    private var lastCompletedTurnID: String?
    private var journalFailure: (any Error)?
    private var turnID: UUID?
    private var publicTurnID: String?
    private var output: AsyncThrowingStream<FxEvent, any Error>.Continuation?
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var toolObservations: [String: FxToolObservation] = [:]
    private var toolNames: [String: String] = [:]
    private var closed = false
    private var handedOff = false
    private var cancelling = false
    private var turnCancelled = false
    private var promptDispatch: PromptDispatch?
    private var checkpointing = false
    private var checkpointSaveTask: Task<Void, any Error>?
    private var closingTask: Task<Void, any Error>?

    private init(
        sessionID: String, rpc: RPCClient, transport: NativeTransport,
        tools: [String: FxTool], journal: JournalWriter?, observation: FxObservationOptions?, checkpointAfterBytes: Int?, checkpointMetadata: CheckpointMetadata, onPermission: PermissionRequests.Handler?, onLifecycleEvent: (@Sendable (FxLifecycleEvent) -> Void)?
    ) {
        self.sessionID = sessionID
        self.rpc = rpc
        self.transport = transport
        self.tools = tools
        let permissionHandler: PermissionRequests.Handler?
        if let onPermission {
            permissionHandler = { request in
                try await journal?.check()
                let decision = try await onPermission(request)
                try await journal?.check()
                return decision
            }
        } else { permissionHandler = nil }
        self.permissions = PermissionRequests(sessionID: sessionID, rpc: rpc, handler: permissionHandler)
        self.journal = journal
        self.observation = observation
        self.onLifecycleEvent = onLifecycleEvent
        self.checkpointAfterBytes = checkpointAfterBytes
        self.checkpointMetadata = checkpointMetadata
    }

    public static func open(configuration: FxConfiguration, sessionID: String? = nil, checkpoint: Data? = nil, persistence: (any FxPersistence)? = nil) async throws -> FxEngine {
        try Task.checkCancellation()
        if let sessionID, !validSessionIdentifier(sessionID) { throw FxError.invalidInput("Invalid session ID") }
        guard checkpoint == nil || persistence == nil else {
            throw FxError.invalidInput("Use a checkpoint or a persistence store, not both")
        }
        if let bytes = configuration.checkpointAfterBytes, bytes < 0 {
            throw FxError.invalidInput("Checkpoint interval must not be negative")
        }
        if case .gateway(let key) = configuration.provider,
           key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FxError.invalidInput("API key is required")
        }
        if let model = configuration.model.id {
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FxError.invalidInput("Model is required") }
        } else {
            guard case .gateway = configuration.provider else { throw FxError.invalidInput("Model is required") }
        }
        if let effort = configuration.model.reasoningEffort, effort.utf8.count > 64 {
            throw FxError.invalidInput("Reasoning effort must not exceed 64 bytes")
        }
        let loaded: LoadedJournal?
        if let persistence { loaded = try LoadedJournal(try await persistence.load()) }
        else { loaded = nil }
        try Task.checkCancellation()
        let providerNames = configuration.providerTools.map(\.rawValue)
        guard Set(providerNames).count == providerNames.count else {
            throw FxError.invalidInput("Tool names must be unique")
        }
        var tools: [String: FxTool] = [:]
        for tool in configuration.tools {
            guard !tool.name.isEmpty, tools[tool.name] == nil, !providerNames.contains(tool.name), case .object = tool.inputSchema else {
                throw FxError.invalidInput("Tool names must be unique and schemas must be objects")
            }
            tools[tool.name] = tool
        }
        let httpClient = ProviderHTTPClient(client: configuration.httpClient, provider: configuration.provider)
        try Task.checkCancellation()
        let transport = try NativeTransport(options: configuration.nativeOptions, httpClient: httpClient, modelID: configuration.model.id, onTransportEvent: configuration.onTransportEvent)
        let rpc = RPCClient(transport: transport, observer: configuration.wireObserver)
        do {
            try await transport.start()
            await rpc.start()
            _ = try await rpc.request("initialize", .object([
                "protocolVersion": .number(1),
                "clientCapabilities": .object([
                    "libfx": .object([
                        "tools": .array(configuration.toolDescriptors),
                        "instructions": .string(configuration.instructions),
                    ]),
                ]),
            ]))
            var sessionOptions: [String: JSONValue] = [:]
            if let sessionID { sessionOptions["sessionId"] = .string(sessionID) }
            if let observation = configuration.observation {
                sessionOptions["hooks"] = .object(["captureContent": .bool(observation.captureContent)])
            }
            let session = try await rpc.request("libfx/new", .object(sessionOptions))
            guard let id = session["sessionId"]?.string else {
                throw FxError.protocolViolation("Missing session identifier")
            }
            let selectedModel: String?
            if case .array(let options) = session["configOptions"] {
                selectedModel = options.first { $0["id"] == .string("model") }?["currentValue"]?.string
            } else { selectedModel = nil }
            guard let modelID = selectedModel, !modelID.isEmpty else {
                throw FxError.protocolViolation("Missing selected model")
            }
            let checkpointMetadata = try CheckpointMetadata(configuration: configuration, modelID: modelID)
            await httpClient.setSessionID(id)
            await transport.setContext(sessionID: id, modelID: modelID)
            if configuration.observation != nil, session["_meta"]?["fx"]?["hooksVersion"] != .number(1) {
                throw FxError.protocolViolation("Runtime does not support observation")
            }
            let journal = persistence.map { JournalWriter(store: $0, head: loaded?.head, lastSequence: loaded?.lastSequence ?? 0, tailBytes: loaded?.tailBytes ?? 0) }
            let engine = FxEngine(sessionID: id, rpc: rpc, transport: transport, tools: tools, journal: journal, observation: configuration.observation, checkpointAfterBytes: configuration.checkpointAfterBytes, checkpointMetadata: checkpointMetadata, onPermission: configuration.onPermission, onLifecycleEvent: configuration.onLifecycleEvent)
            await rpc.setHandler { [weak engine] message in await engine?.handle(message) }
            if let checkpoint {
                try await transport.putAttachment(checkpoint, id: 1)
                let restored = try await rpc.request("libfx/restore", .object([
                    "sessionId": .string(id), "checkpointAttachment": .number(1),
                ]))
                checkpointMetadata.compare(restored["checkpointMeta"], sessionID: id, observation: configuration.observation, onLifecycleEvent: configuration.onLifecycleEvent)
            }
            if let loaded {
                var params: [String: JSONValue] = ["sessionId": .string(id)]
                var attachment: UInt32 = 1
                if !loaded.events.isEmpty {
                    try await transport.putAttachment(JSONEncoder().encode(JSONValue.array(loaded.events)), id: attachment)
                    params["journalAttachment"] = .number(Double(attachment))
                    attachment += 1
                }
                if let checkpoint = loaded.checkpoint {
                    try await transport.putAttachment(checkpoint, id: attachment)
                    params["snapshotAttachment"] = .number(Double(attachment))
                }
                let opened = try await rpc.request("libfx/journal_open", .object(params))
                checkpointMetadata.compare(opened["checkpointMeta"], sessionID: id, observation: configuration.observation, onLifecycleEvent: configuration.onLifecycleEvent)
                await engine.setRecovery(opened)
                configuration.onLifecycleEvent?(.journalOpened(FxJournalRestoration(
                    sessionID: id, cursor: loaded.head, lastSequence: loaded.lastSequence,
                    resumable: opened["resumable"] == .bool(true), openTurnID: opened["openTurnId"]?.string,
                    lastTurnID: opened["lastTurnId"]?.string, eventCount: loaded.events.count,
                    hasCheckpoint: loaded.checkpoint != nil, turnCount: opened["turns"]?.integer ?? 0)))
                configuration.observation?.deliver(FxObservation(journal: .journalRestored, sessionID: id, data: .object([
                    "cursor": loaded.head.map(JSONValue.string) ?? .null,
                    "lastSeq": .number(Double(loaded.lastSequence)),
                    "resumable": opened["resumable"] ?? .bool(false),
                    "openTurnId": opened["openTurnId"] ?? .null, "lastTurnId": opened["lastTurnId"] ?? .null,
                    "events": .number(Double(loaded.events.count)), "checkpoint": .bool(loaded.checkpoint != nil),
                    "turns": opened["turns"] ?? .number(0),
                ])))
            }
            try Task.checkCancellation()
            return engine
        } catch {
            await rpc.close()
            throw error
        }
    }

    public func prompt(_ text: String, id: String = UUID().uuidString, yieldAt: Date? = nil) throws -> FxTurn {
        try prompt([.text(text)], id: id, yieldAt: yieldAt)
    }

    public func prompt(_ content: [FxPromptContent], id: String = UUID().uuidString, yieldAt: Date? = nil) throws -> FxTurn {
        guard !closed else { throw FxError.closed }
        guard !handedOff else { throw FxError.handedOff }
        if let journalFailure { throw journalFailure }
        guard turnID == nil, !cancelling, !checkpointing else { throw FxError.busy }
        guard validInputID(id) else { throw FxError.invalidInput("Turn ID must contain 1–128 ASCII letters, digits, '.', '_' or '-'") }
        if journal != nil {
            if recovery?.turnID == id, let turn = try resume(yieldAt: yieldAt) { return turn }
            if lastCompletedTurnID == id { return .completed(id: id) }
        }
        let turn = try startTurn(content, publicID: id, yieldAt: yieldAt)
        recovery = nil
        return turn
    }

    /// Queues text as a separate turn. Await accepted before relying on recovery after a process exit.
    public func followUp(_ text: String) throws -> FxFollowUp {
        guard !closed else { throw FxError.closed }
        guard !handedOff else { throw FxError.handedOff }
        if let journalFailure { throw journalFailure }
        guard !text.isEmpty, text.utf8.count <= 64 * 1024 else {
            throw FxError.invalidInput("Follow-up text must contain 1–65536 UTF-8 bytes")
        }
        let receipt = FxFollowUp(id: "in_" + UUID().uuidString.lowercased())
        let acceptNow = journal != nil && turnID != nil
        followUps.append(QueuedFollowUp(receipt: receipt, text: text, acceptance: acceptNow ? .pending : .onStart, held: false))
        if journal != nil { followUpAcceptances[receipt.id] = receipt }
        if acceptNow {
            let dispatch = promptDispatch
            let previous = followUpAcceptanceTask
            followUpAcceptanceTask = Task {
                do {
                    await previous?.value
                    _ = await dispatch?.wait()
                    guard !closed else { throw FxError.closed }
                    guard !handedOff else { throw FxError.handedOff }
                    _ = try await rpc.request("libfx/follow_up", .object([
                        "sessionId": .string(sessionID), "id": .string(receipt.id), "text": .string(text),
                    ]))
                    try await journal?.check()
                    guard !closed else { throw FxError.closed }
                    guard !handedOff else { throw FxError.handedOff }
                    if let index = followUps.firstIndex(where: { $0.receipt.id == receipt.id }) { followUps[index].acceptance = .stored }
                    await receipt.acceptance.resolve(.success(()))
                    startNextFollowUp()
                } catch {
                    followUps.removeAll { $0.receipt.id == receipt.id }
                    followUpAcceptances.removeValue(forKey: receipt.id)
                    await receipt.acceptance.resolve(.failure(error))
                    await receipt.started.resolve(.failure(error))
                    startNextFollowUp()
                }
            }
        } else { startNextFollowUp() }
        return receipt
    }

    @discardableResult
    private func startNextFollowUp(held: Bool = false) -> FxTurn? {
        guard !closed, !handedOff, journalFailure == nil, turnID == nil, !cancelling, !checkpointing else { return nil }
        while let index = followUps.firstIndex(where: { $0.held == held }) {
            guard followUps[index].ready else { return nil }
            let entry = followUps.remove(at: index)
            do {
                let turn = try startTurn([.text(entry.text)], publicID: entry.receipt.id, followUp: entry)
                recovery = nil
                Task {
                    await entry.receipt.started.resolve(.success(turn))
                    if journal == nil || entry.acceptedInCore { await entry.receipt.acceptance.resolve(.success(())) }
                }
                return turn
            } catch {
                followUpAcceptances.removeValue(forKey: entry.receipt.id)
                Task {
                    await entry.receipt.acceptance.resolve(.failure(error))
                    await entry.receipt.started.resolve(.failure(error))
                }
            }
        }
        return nil
    }

    private func failFollowUps(_ error: any Error) {
        let queued = followUps
        let accepting = followUpAcceptances.values.map { $0 }
        followUps.removeAll()
        followUpAcceptances.removeAll()
        Task {
            for entry in queued {
                await entry.receipt.started.resolve(.failure(error))
                await entry.receipt.acceptance.resolve(.failure(error))
            }
            for receipt in accepting { await receipt.acceptance.resolve(.failure(error)) }
        }
    }

    var completedTurnID: String? { lastCompletedTurnID }

    public var recoveryState: FxRecoveryState? { recovery }
    @_spi(Conformance) public var hasResumableWork: Bool { recovery != nil || followUps.contains { $0.held } }

    /// Continues an interrupted turn. Unlisted ambiguous calls are not repeated.
    public func resume(rerunning executionIDs: Set<String> = [], yieldAt: Date? = nil) throws -> FxTurn? {
        guard !closed else { throw FxError.closed }
        guard !handedOff else { throw FxError.handedOff }
        if let journalFailure { throw journalFailure }
        guard turnID == nil, !cancelling, !checkpointing else { throw FxError.busy }
        guard let recovery else { return startNextFollowUp(held: true) }
        guard executionIDs.isSubset(of: Set(recovery.runningCalls.map(\.executionID))) else {
            throw FxError.invalidInput("Unknown recovery execution identifier")
        }
        return try startTurn([], publicID: recovery.turnID ?? UUID().uuidString, yieldAt: yieldAt, resuming: true, rerunning: executionIDs)
    }

    private func setRecovery(_ opened: JSONValue) {
        lastCompletedTurnID = opened["lastTurnId"]?.string
        if case .array(let entries) = opened["followUps"] {
            followUps = entries.compactMap { entry in
                guard let id = entry["id"]?.string, let text = entry["text"]?.string else { return nil }
                return QueuedFollowUp(receipt: FxFollowUp(id: id), text: text, acceptance: .stored, held: true)
            }
        }
        guard opened["resumable"] == .bool(true) else { recovery = nil; return }
        let calls: [FxRecoveryCall]
        if case .array(let entries) = opened["runningCalls"] {
            calls = entries.compactMap { entry in
                guard let id = entry["id"]?.string, let name = entry["name"]?.string else { return nil }
                let text = entry["arguments"]?.string ?? "null"
                let input = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
                return FxRecoveryCall(executionID: id, name: name, input: input)
            }
        } else { calls = [] }
        recovery = FxRecoveryState(turnID: opened["openTurnId"]?.string, runningCalls: calls)
    }

    private func startTurn(_ content: [FxPromptContent], publicID: String, yieldAt: Date? = nil, resuming: Bool = false, rerunning: Set<String> = [], followUp: QueuedFollowUp? = nil) throws -> FxTurn {
        guard !closed else { throw FxError.closed }
        guard turnID == nil, !cancelling, !checkpointing else { throw FxError.busy }
        var metadata: [String: JSONValue] = [:]
        if let yieldAt {
            guard journal != nil else { throw FxError.invalidInput("Yielding requires persistence") }
            let milliseconds = (yieldAt.timeIntervalSince1970 * 1000).rounded()
            guard milliseconds.isFinite, milliseconds > 0, milliseconds <= 9_007_199_254_740_991 else {
                throw FxError.invalidInput("Yield deadline is outside the supported date range")
            }
            metadata["yieldAt"] = .number(milliseconds)
        }
        if !resuming { metadata["turnId"] = .string(publicID) }
        if let followUp {
            metadata["inputId"] = .string(followUp.receipt.id)
            metadata["inputAccepted"] = .bool(followUp.acceptedInCore)
        }
        let prepared = try PreparedPrompt(content, allowEmpty: resuming)
        let blocks = prepared.blocks, images = prepared.images
        let id = UUID()
        turnID = id
        publicTurnID = publicID
        activeFollowUpID = followUp?.receipt.id
        turnCancelled = false
        let dispatch = PromptDispatch()
        promptDispatch = dispatch
        toolNames.removeAll()
        let (events, continuation) = AsyncThrowingStream<FxEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        output = continuation
        if resuming {
            for call in recovery?.runningCalls ?? [] where !rerunning.contains(call.executionID) {
                continuation.yield(.toolFinished(
                    id: call.executionID, name: call.name,
                    content: "fx stopped while this tool was running, so it may have partly run. Check its effects before running it again.",
                    isError: true
                ))
            }
        }
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { Task { await self?.cancel(turn: id) } }
        }
        let task = Task {
            do {
                await transport.beginTurn()
                for (index, bytes) in images.enumerated() {
                    try await transport.putAttachment(bytes, id: UInt32(index + 1))
                }
                // Recovery must reach the core before cancellation so its open
                // journal turn is closed rather than left pending.
                if turnCancelled && !resuming {
                    await dispatch.resolve(sent: false)
                    await transport.discardAttachments()
                    self.finish(turn: id)
                    return FxTurnResult(stopReason: .cancelled, usage: FxUsage(nil))
                }
                var params: [String: JSONValue] = [
                    "sessionId": .string(sessionID),
                    "prompt": .array(blocks),
                ]
                if resuming {
                    metadata["continueRecovery"] = .bool(true)
                    metadata["freshOutput"] = .bool(true)
                    metadata["rerun"] = .array(rerunning.sorted().map(JSONValue.string))
                }
                params["_meta"] = .object(["fx": .object(metadata)])
                let result = try await rpc.request("session/prompt", .object(params), onSent: { await dispatch.resolve(sent: true) })
                try await journal?.check()
                try Task.checkCancellation()
                let reason = FxTurnResult.StopReason(rawValue: result["stopReason"]?.string ?? "") ?? .unknown
                if !handedOff {
                    if reason == .yielded {
                        recovery = FxRecoveryState(turnID: publicID, runningCalls: [])
                    } else {
                        recovery = nil
                        if journal != nil { lastCompletedTurnID = publicID }
                    }
                }
                await maybeSaveCheckpoint(finishing: id)
                self.finish(turn: id)
                return FxTurnResult(
                    stopReason: reason,
                    usage: FxUsage(result["usage"])
                )
            } catch {
                await dispatch.resolve(sent: false)
                await transport.discardAttachments()
                if turnID == id, turnCancelled, !closed,
                   case FxError.rpc(_, "Cancelled", _) = error {
                    do { try await journal?.check() }
                    catch {
                        self.finish(turn: id, error: error)
                        throw error
                    }
                    self.finish(turn: id)
                    return FxTurnResult(stopReason: .cancelled, usage: FxUsage(nil))
                }
                self.finish(turn: id, error: error)
                throw error
            }
        }
        return FxTurn(
            id: publicID, events: events, completion: task,
            cancelAction: { [weak self] in await self?.cancel(turn: id) },
            handoffAction: { [weak self] in
                guard let self else { throw FxError.closed }
                try await self.handoff(turn: id)
            },
            endForSteeringAction: { [weak self] in
                guard let self else { throw FxError.closed }
                try await self.endForSteering(turn: id)
            },
            steerAction: { [weak self] text, inputID in
                guard let self else { throw FxError.closed }
                return try await self.steer(turn: id, text: text, inputID: inputID)
            },
            withdrawAction: { [weak self] inputID in
                guard let self else { throw FxError.closed }
                return try await self.withdraw(turn: id, inputID: inputID)
            }
        )
    }

    private func handle(_ message: RPCMessage) async {
        guard !closed else { return }
        if message.method == "libfx/hook", message.params["rootSessionId"]?.string == sessionID {
            guard let observation else { return }
            do {
                var params = message.params
                if handedOff, params["type"] == .string("turn.end"), case .object(var fields) = params,
                   case .object(var data) = fields["data"] {
                    data["handoff"] = .bool(true)
                    fields["data"] = .object(data)
                    params = .object(fields)
                }
                let event = observation.project(try FxObservation(raw: params))
                if event.sessionID == sessionID, let callID = event.data["call"]?["callId"]?.string {
                    if event.kind == .toolStarted {
                        toolObservations[callID]?.invalidate()
                        toolObservations[callID] = try FxToolObservation(scope: event, callID: callID, options: observation)
                    } else if event.kind == .toolEnded, toolObservations[callID]?.scope.executionID == event.executionID {
                        toolObservations.removeValue(forKey: callID)?.invalidate()
                    }
                }
                if event.kind == .turnEnded {
                    for (id, tool) in toolObservations where tool.scope.executionID == event.executionID {
                        tool.invalidate()
                        toolObservations.removeValue(forKey: id)
                    }
                }
                observation.deliver(event)
            } catch { observation.onError(error) }
        } else if message.method == "libfx/journal_append", message.params["sessionId"]?.string == sessionID, let journal {
            guard !handedOff, journalFailure == nil else { return }
            do {
                let events = message.params["events"] ?? .null
                try await journal.append(events, barrier: message.params["barrier"] == .bool(true))
                if case .array(let batch) = events, !batch.isEmpty {
                    for event in batch where event["type"] == .string("input_accepted") {
                        if let id = event["data"]?["id"]?.string, let receipt = followUpAcceptances.removeValue(forKey: id) {
                            await receipt.acceptance.resolve(.success(()))
                        }
                    }
                    let cursor = await journal.head
                    observation?.deliver(FxObservation(journal: .journalCommitted, sessionID: sessionID, data: .object([
                        "cursor": cursor.map(JSONValue.string) ?? .null,
                        "firstSeq": batch.first?["seq"] ?? .null, "lastSeq": batch.last?["seq"] ?? .null,
                        "eventCount": .number(Double(batch.count)),
                    ])))
                }
            } catch {
                guard journalFailure == nil else { return }
                journalFailure = error
                failFollowUps(error)
                observation?.deliver(FxObservation(journal: .journalError, sessionID: sessionID, data: .object([
                    "error": .string(String(describing: type(of: error))),
                    "fenced": .bool((error as? FxPersistenceError) == .fenced),
                ])))
                if let turnID { await cancel(turn: turnID) }
            }
        } else if message.method == "libfx/journal_flush", let id = message.id {
            do {
                try await journal?.check()
                try await rpc.respond(id: id, result: .object([:]))
            } catch { try? await rpc.respond(id: id, error: .transport(String(describing: error))) }
        } else if message.method == "session/update", message.params["sessionId"]?.string == sessionID {
            guard !handedOff else { return }
            do {
                if let event = try event(for: message.params["update"] ?? .null), let output {
                    if case .dropped = output.yield(event) {
                        output.finish(throwing: FxError.outputOverflow)
                        if let turnID { await cancel(turn: turnID) }
                    }
                }
            } catch {
                output?.finish(throwing: error)
                if let turnID { await cancel(turn: turnID) }
            }
        } else if message.method == "libfx/tool_call", let requestID = message.id {
            let params = message.params
            let callID = params["toolCallId"]?.string ?? ""
            let expectedTurn = turnID
            guard isActive(expectedTurn), let publicTurnID, params["sessionId"]?.string == sessionID else {
                try? await rpc.respond(id: requestID, error: .protocolViolation("Tool call does not belong to the active conversation"))
                return
            }
            let name = params["name"]?.string ?? ""
            let context = FxToolContext(executionID: callID, sessionID: sessionID, turnID: publicTurnID,
                                        observation: toolObservations[callID])
            let tool = tools[name]
            toolTasks[callID] = Task { [weak self, rpc] in
                guard let self, await self.isActive(expectedTurn) else { return }
                let response: JSONValue
                do {
                    try await self.journal?.check()
                    try Task.checkCancellation()
                    guard let tool else { throw FxError.invalidInput("Unknown tool") }
                    let value = try await tool.execute(params["input"] ?? .null, context)
                    try Task.checkCancellation()
                    response = try value.response()
                } catch {
                    response = .object(["content": .string(String(describing: error)), "isError": .bool(true)])
                }
                guard !Task.isCancelled, await self.isActive(expectedTurn) else { return }
                try? await rpc.respond(id: requestID, result: response)
                await self.removeTool(callID, turn: expectedTurn)
            }
        } else if message.method == "session/request_permission", let id = message.id {
            let expectedTurn = turnID
            await permissions.handle(id: id, params: message.params, turnID: publicTurnID, scope: expectedTurn) { [weak self] in
                await self?.isActive(expectedTurn) == true
            }
        } else if let id = message.id {
            try? await rpc.respond(id: id, error: .protocolViolation("Unsupported host request: \(message.method)"))
        }
    }

    private func event(for update: JSONValue) throws -> FxEvent? {
        switch update["sessionUpdate"]?.string {
        case "agent_message_chunk":
            guard let text = update["content"]?["text"]?.string, !text.hasPrefix("[context]") else { return nil }
            return .text(text)
        case "agent_thought_chunk": return update["content"]?["text"]?.string.map(FxEvent.reasoning)
        case "user_message_chunk":
            guard let text = update["content"]?["text"]?.string else { return nil }
            return .userMessage(text, id: update["_meta"]?["fx"]?["steering"]?["inputId"]?.string)
        case "tool_call":
            guard let id = update["toolCallId"]?.string, toolNames[id] == nil else { return nil }
            let name = update["name"]?.string ?? update["toolName"]?.string ?? update["title"]?.string ?? "tool"
            toolNames[id] = name
            return .toolStarted(id: id, name: name, input: try FxToolInput.display(update["rawInput"]))
        case "tool_call_update":
            guard let id = update["toolCallId"]?.string, let status = update["status"]?.string,
                  status == "completed" || status == "failed" else { return nil }
            var text: String?
            if case .array(let entries) = update["content"] {
                text = entries.first { $0["content"]?["type"] == .string("text") }?["content"]?["text"]?.string
            }
            return .toolFinished(id: id, name: toolNames[id] ?? "tool", content: text, isError: status == "failed")
        default: return nil
        }
    }

    private func isActive(_ id: UUID?) -> Bool { id != nil && turnID == id && !closed && !turnCancelled }
    private func removeTool(_ id: String, turn: UUID?) {
        guard turnID == turn else { return }
        toolTasks.removeValue(forKey: id)
        toolObservations.removeValue(forKey: id)?.invalidate()
    }

    private func invalidateToolObservations() {
        for observation in toolObservations.values { observation.invalidate() }
        toolObservations.removeAll()
    }

    private func cancel(turn id: UUID) async {
        guard isActive(id), !cancelling else { return }
        turnCancelled = true
        cancelling = true
        defer { cancelling = false; startNextFollowUp() }
        for task in toolTasks.values { task.cancel() }
        toolTasks.removeAll()
        invalidateToolObservations()
        await permissions.cancel(scope: id)
        guard await promptDispatch?.wait() == true, turnID == id, !closed else { return }
        try? await rpc.notify("session/cancel", .object(["sessionId": .string(sessionID)]))
        await transport.abortEffects()
    }

    private func handoff(turn id: UUID) async throws {
        guard !closed else { throw FxError.closed }
        guard journal != nil else { throw FxError.invalidInput("Handoff requires persistence") }
        guard isActive(id) else { return }
        handedOff = true
        failFollowUps(FxError.handedOff)
        await cancel(turn: id)
        try await journal?.check()
    }

    private func steer(turn id: UUID, text: String, inputID: String) async throws -> FxSteeringReceipt {
        guard !closed else { throw FxError.closed }
        guard isActive(id) else { throw FxError.noActiveTurn }
        guard !text.isEmpty, text.utf8.count <= 64 * 1024 else { throw FxError.invalidInput("Steering text must contain 1–65536 UTF-8 bytes") }
        guard validInputID(inputID) else { throw FxError.invalidInput("Invalid steering ID") }
        guard await promptDispatch?.wait() == true, isActive(id) else { throw FxError.noActiveTurn }
        _ = try await rpc.request("libfx/steer", .object([
            "sessionId": .string(sessionID), "text": .string(text), "id": .string(inputID),
        ]))
        try await journal?.check()
        return FxSteeringReceipt(id: inputID)
    }

    private func endForSteering(turn id: UUID) async throws {
        guard !closed else { throw FxError.closed }
        guard isActive(id), await promptDispatch?.wait() == true, isActive(id) else { return }
        _ = try await rpc.request("libfx/handoff", .object(["sessionId": .string(sessionID)]))
        try await journal?.check()
    }

    private func withdraw(turn id: UUID, inputID: String) async throws -> FxWithdrawal {
        guard !closed else { throw FxError.closed }
        guard validInputID(inputID) else { throw FxError.invalidInput("Invalid steering ID") }
        guard isActive(id) else { return .alreadyPlaced }
        guard await promptDispatch?.wait() == true, isActive(id) else { return .alreadyPlaced }
        let reply = try await rpc.request("libfx/withdraw", .object([
            "sessionId": .string(sessionID), "id": .string(inputID),
        ]))
        try await journal?.check()
        return reply["result"] == .string("withdrawn") ? .withdrawn : .alreadyPlaced
    }

    private func finish(turn id: UUID, error: (any Error)? = nil) {
        guard turnID == id else { return }
        for task in toolTasks.values { task.cancel() }
        toolTasks.removeAll()
        invalidateToolObservations()
        Task { await permissions.cancel(scope: id) }
        if let error { output?.finish(throwing: error) } else { output?.finish() }
        output = nil
        turnID = nil
        publicTurnID = nil
        if let activeFollowUpID, let receipt = followUpAcceptances.removeValue(forKey: activeFollowUpID) {
            Task { await receipt.acceptance.resolve(.failure(error ?? FxError.cancelled)) }
        }
        activeFollowUpID = nil
        startNextFollowUp()
    }

    public func checkpoint() async throws -> Data {
        guard !closed else { throw FxError.closed }
        guard turnID == nil, !cancelling, !checkpointing else { throw FxError.busy }
        checkpointing = true
        defer { checkpointing = false; startNextFollowUp() }
        let reply = try await rpc.request("libfx/checkpoint", .object(["sessionId": .string(sessionID), "checkpointMeta": checkpointMetadata.value]))
        guard let id = reply["checkpointAttachment"]?.integer, let attachmentID = UInt32(exactly: id) else {
            throw FxError.protocolViolation("Invalid checkpoint attachment")
        }
        return try await transport.takeAttachment(id: attachmentID)
    }

    public func flushPersistence() async throws { try await journal?.check() }

    /// Saves a journal snapshot through the configured checkpoint persistence store.
    public func saveCheckpoint() async throws {
        try await storeCheckpoint(finishing: nil)
    }

    private func maybeSaveCheckpoint(finishing id: UUID) async {
        guard let checkpointAfterBytes, let journal, await journal.shouldCheckpoint(afterBytes: checkpointAfterBytes),
              !closed, !handedOff, turnID == id else { return }
        do { try await storeCheckpoint(finishing: id) }
        catch {
            onLifecycleEvent?(.checkpointFailed(sessionID: sessionID, error: error))
            observation?.deliver(FxObservation(journal: .checkpointError, sessionID: sessionID, data: .object([
                "error": .string(String(describing: type(of: error))),
                "fenced": .bool((error as? FxPersistenceError) == .fenced),
            ])))
        }
    }

    private func storeCheckpoint(finishing id: UUID?) async throws {
        guard !closed else { throw FxError.closed }
        guard !handedOff else { throw FxError.handedOff }
        guard turnID == id, !cancelling, !checkpointing else { throw FxError.busy }
        guard let journal else { throw FxError.invalidInput("Persistence store is required") }
        checkpointing = true
        defer { checkpointing = false; checkpointSaveTask = nil; startNextFollowUp() }
        let task = Task { [rpc, transport, sessionID, observation, checkpointMetadata, onLifecycleEvent] in
            try await journal.check()
            let reply = try await rpc.request("libfx/snapshot", .object(["sessionId": .string(sessionID), "checkpointMeta": checkpointMetadata.value]))
            if reply["snapshotAttachment"] == .null { return }
            guard let rawID = reply["snapshotAttachment"]?.integer, let attachmentID = UInt32(exactly: rawID),
                  let rawSequence = reply["atSeq"]?.integer, let sequence = UInt64(exactly: rawSequence) else {
                throw FxError.protocolViolation("Invalid journal snapshot")
            }
            let data = try await transport.takeAttachment(id: attachmentID)
            if let through = try await journal.saveSnapshot(data, at: sequence) {
                onLifecycleEvent?(.checkpointSaved(sessionID: sessionID, cursor: through, byteCount: data.count))
                observation?.deliver(FxObservation(journal: .checkpointSaved, sessionID: sessionID, data: .object([
                    "through": .string(through), "bytes": .number(Double(data.count)),
                ])))
            }
        }
        checkpointSaveTask = task
        try await task.value
    }

    public func close() async throws {
        if let closingTask { try await closingTask.value; return }
        closed = true
        failFollowUps(FxError.closed)
        if let turnID { finish(turn: turnID, error: FxError.closed) }
        let checkpointSave = checkpointSaveTask
        let task = Task {
            let saved = await checkpointSave?.result
            await permissions.cancelAll()
            await rpc.close()
            try await journal?.check()
            try saved?.get()
        }
        closingTask = task
        try await task.value
    }
}
