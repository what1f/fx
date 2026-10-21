import Foundation

/// One conversation backed by the native fx core. Call close when the conversation ends.
public actor FxEngine {
    public nonisolated let sessionID: String
    private let rpc: RPCClient
    private let transport: NativeTransport
    private let tools: [String: FxTool]
    private let journal: JournalWriter?
    private let observation: FxObservationOptions?
    private var recovery: FxRecoveryState?
    private var turnID: UUID?
    private var output: AsyncThrowingStream<FxEvent, any Error>.Continuation?
    private var toolTasks: [String: Task<Void, Never>] = [:]
    private var toolNames: [String: String] = [:]
    private var closed = false
    private var cancelling = false
    private var turnCancelled = false
    private var promptDispatch: PromptDispatch?
    private var checkpointing = false
    private var checkpointSaveTask: Task<Void, any Error>?
    private var closingTask: Task<Void, any Error>?

    private init(sessionID: String, rpc: RPCClient, transport: NativeTransport, tools: [String: FxTool], journal: JournalWriter?, observation: FxObservationOptions?) {
        self.sessionID = sessionID
        self.rpc = rpc
        self.transport = transport
        self.tools = tools
        self.journal = journal
        self.observation = observation
    }

    public static func open(configuration: FxConfiguration, checkpoint: Data? = nil, persistence: (any FxPersistence)? = nil) async throws -> FxEngine {
        guard checkpoint == nil || persistence == nil else {
            throw FxError.invalidInput("Use a checkpoint or a persistence store, not both")
        }
        let loaded: LoadedJournal?
        if let persistence { loaded = try LoadedJournal(try await persistence.load()) }
        else { loaded = nil }
        guard !configuration.model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FxError.invalidInput("Model is required")
        }
        var tools: [String: FxTool] = [:]
        for tool in configuration.tools {
            guard !tool.name.isEmpty, tools[tool.name] == nil, case .object = tool.inputSchema else {
                throw FxError.invalidInput("Tool names must be unique and schemas must be objects")
            }
            tools[tool.name] = tool
        }
        let transport = try NativeTransport(options: configuration.nativeOptions, httpClient: configuration.httpClient)
        let rpc = RPCClient(transport: transport, observer: configuration.wireObserver)
        do {
            try await transport.start()
            await rpc.start()
            _ = try await rpc.request("initialize", .object([
                "protocolVersion": .number(1),
                "clientCapabilities": .object([
                    "libfx": .object([
                        "tools": .array(configuration.tools.map(\.descriptor)),
                        "instructions": .string(configuration.instructions),
                    ]),
                ]),
            ]))
            var sessionOptions: [String: JSONValue] = [:]
            if let observation = configuration.observation {
                sessionOptions["hooks"] = .object(["captureContent": .bool(observation.captureContent)])
            }
            let session = try await rpc.request("libfx/new", .object(sessionOptions))
            guard let id = session["sessionId"]?.string else {
                throw FxError.protocolViolation("Missing session identifier")
            }
            if configuration.observation != nil, session["_meta"]?["fx"]?["hooksVersion"] != .number(1) {
                throw FxError.protocolViolation("Runtime does not support observation")
            }
            let journal = persistence.map { JournalWriter(store: $0, head: loaded?.head, lastSequence: loaded?.lastSequence ?? 0) }
            let engine = FxEngine(sessionID: id, rpc: rpc, transport: transport, tools: tools, journal: journal, observation: configuration.observation)
            await rpc.setHandler { [weak engine] message in await engine?.handle(message) }
            if let checkpoint {
                try await transport.putAttachment(checkpoint, id: 1)
                _ = try await rpc.request("libfx/restore", .object([
                    "sessionId": .string(id), "checkpointAttachment": .number(1),
                ]))
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
                await engine.setRecovery(opened)
                configuration.observation?.deliver(FxObservation(journal: .journalRestored, sessionID: id, data: .object([
                    "cursor": loaded.head.map(JSONValue.string) ?? .null,
                    "lastSeq": .number(Double(loaded.lastSequence)),
                    "resumable": opened["resumable"] ?? .bool(false),
                    "openTurnId": opened["openTurnId"] ?? .null, "lastTurnId": opened["lastTurnId"] ?? .null,
                ])))
            }
            return engine
        } catch {
            await rpc.close()
            throw error
        }
    }

    public func prompt(_ text: String) throws -> FxTurn {
        try prompt([.text(text)])
    }

    public func prompt(_ content: [FxPromptContent]) throws -> FxTurn {
        guard !closed else { throw FxError.closed }
        guard recovery == nil else { throw FxError.invalidInput("Resume the interrupted turn before starting another prompt") }
        return try startTurn(content)
    }

    public var recoveryState: FxRecoveryState? { recovery }

    /// Continues an interrupted turn. Unlisted ambiguous calls are not repeated.
    public func resume(rerunning executionIDs: Set<String> = []) throws -> FxTurn? {
        guard !closed else { throw FxError.closed }
        guard let recovery else { return nil }
        guard executionIDs.isSubset(of: Set(recovery.runningCalls.map(\.executionID))) else {
            throw FxError.invalidInput("Unknown recovery execution identifier")
        }
        return try startTurn([], resuming: true, rerunning: executionIDs)
    }

    private func setRecovery(_ opened: JSONValue) {
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

    private func startTurn(_ content: [FxPromptContent], resuming: Bool = false, rerunning: Set<String> = []) throws -> FxTurn {
        guard !closed else { throw FxError.closed }
        guard turnID == nil, !cancelling, !checkpointing else { throw FxError.busy }
        guard resuming || content.contains(where: {
            switch $0 {
            case .text(let text): return !text.isEmpty
            case .image: return true
            }
        }) else {
            throw FxError.invalidInput("Prompt must not be empty")
        }
        var blocks: [JSONValue] = []
        var images: [Data] = []
        var imageCount = 0
        for block in content {
            switch block {
            case .text(let text): blocks.append(.object(["type": .string("text"), "text": .string(text)]))
            case .image(let image):
                imageCount += 1
                try image.validate()
                var fields = image.fields
                if let data = image.data {
                    guard data.count <= 5 * 1024 * 1024 / 4 * 3 || image.sourceReference != nil else {
                        throw FxError.invalidInput("Prompt image exceeds the size limit")
                    }
                    if data.count <= 5 * 1024 * 1024 / 4 * 3 {
                        images.append(data)
                        fields["_meta"] = .object(["fx": .object(["attachment": .number(Double(images.count))])])
                    }
                }
                blocks.append(.object(fields))
            }
        }
        guard imageCount <= 8, images.reduce(0, { $0 + $1.count }) <= 6 * 1024 * 1024 else {
            throw FxError.invalidInput("Prompt images exceed the count or size limit")
        }
        let encodedImageBytes = images.reduce(0) { $0 + (($1.count + 2) / 3) * 4 }
        guard try JSONEncoder().encode(JSONValue.array(blocks)).count + encodedImageBytes <= 8 * 1024 * 1024 - 1024 else {
            throw FxError.invalidInput("Prompt exceeds frame limit")
        }
        let id = UUID()
        turnID = id
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
                for (index, bytes) in images.enumerated() {
                    try await transport.putAttachment(bytes, id: UInt32(index + 1))
                }
                if turnCancelled {
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
                    params["_meta"] = .object(["fx": .object([
                        "continueRecovery": .bool(true), "freshOutput": .bool(true),
                        "rerun": .array(rerunning.sorted().map(JSONValue.string)),
                    ])])
                }
                let result = try await rpc.request("session/prompt", .object(params), onSent: { await dispatch.resolve(sent: true) })
                try await journal?.check()
                try Task.checkCancellation()
                recovery = nil
                self.finish(turn: id)
                return FxTurnResult(
                    stopReason: FxTurnResult.StopReason(rawValue: result["stopReason"]?.string ?? "") ?? .unknown,
                    usage: FxUsage(result["usage"])
                )
            } catch {
                await dispatch.resolve(sent: false)
                await transport.discardAttachments()
                self.finish(turn: id, error: error)
                throw error
            }
        }
        return FxTurn(
            events: events, completion: task,
            cancelAction: { [weak self] in await self?.cancel(turn: id) },
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
            do { observation.deliver(try FxObservation(raw: message.params)) }
            catch { observation.onError(error) }
        } else if message.method == "libfx/journal_append", message.params["sessionId"]?.string == sessionID, let journal {
            do {
                let events = message.params["events"] ?? .null
                try await journal.append(events, barrier: message.params["barrier"] == .bool(true))
                if case .array(let batch) = events, !batch.isEmpty {
                    let cursor = await journal.head
                    observation?.deliver(FxObservation(journal: .journalCommitted, sessionID: sessionID, data: .object([
                        "cursor": cursor.map(JSONValue.string) ?? .null,
                        "firstSeq": batch.first?["seq"] ?? .null, "lastSeq": batch.last?["seq"] ?? .null,
                        "eventCount": .number(Double(batch.count)),
                    ])))
                }
            } catch {
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
            if let event = event(for: message.params["update"] ?? .null), let output {
                if case .dropped = output.yield(event) {
                    output.finish(throwing: FxError.outputOverflow)
                    if let turnID { await cancel(turn: turnID) }
                }
            }
        } else if message.method == "libfx/tool_call", let requestID = message.id {
            let params = message.params
            let callID = params["toolCallId"]?.string ?? ""
            let expectedTurn = turnID
            guard isActive(expectedTurn), params["sessionId"]?.string == sessionID else {
                try? await rpc.respond(id: requestID, error: .protocolViolation("Tool call does not belong to the active conversation"))
                return
            }
            let name = params["name"]?.string ?? ""
            let context = FxToolContext(executionID: callID, sessionID: params["sessionId"]?.string ?? sessionID)
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
                await self.removeTool(callID)
            }
        } else if message.method == "session/request_permission", let id = message.id {
            // Host tools must authorize their own effects. Unhandled core permission requests are denied.
            try? await rpc.respond(id: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])]))
        } else if let id = message.id {
            try? await rpc.respond(id: id, error: .protocolViolation("Unsupported host request: \(message.method)"))
        }
    }

    private func event(for update: JSONValue) -> FxEvent? {
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
            return .toolStarted(id: id, name: name, input: update["rawInput"])
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
    private func removeTool(_ id: String) { toolTasks.removeValue(forKey: id) }

    private func cancel(turn id: UUID) async {
        guard isActive(id), !cancelling else { return }
        turnCancelled = true
        cancelling = true
        defer { cancelling = false }
        for task in toolTasks.values { task.cancel() }
        toolTasks.removeAll()
        guard await promptDispatch?.wait() == true, turnID == id, !closed else { return }
        try? await rpc.notify("session/cancel", .object(["sessionId": .string(sessionID)]))
        await transport.abortEffects()
    }

    private func steer(turn id: UUID, text: String, inputID: String) async throws -> FxSteeringReceipt {
        guard !closed else { throw FxError.closed }
        guard isActive(id) else { throw FxError.noActiveTurn }
        guard !text.isEmpty, text.utf8.count <= 64 * 1024 else { throw FxError.invalidInput("Steering text must contain 1–65536 UTF-8 bytes") }
        guard await promptDispatch?.wait() == true, isActive(id) else { throw FxError.noActiveTurn }
        _ = try await rpc.request("libfx/steer", .object([
            "sessionId": .string(sessionID), "text": .string(text), "id": .string(inputID),
        ]))
        try await journal?.check()
        return FxSteeringReceipt(id: inputID)
    }

    private func withdraw(turn id: UUID, inputID: String) async throws -> FxWithdrawal {
        guard !closed else { throw FxError.closed }
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
        if let error { output?.finish(throwing: error) } else { output?.finish() }
        output = nil
        turnID = nil
    }

    public func checkpoint() async throws -> Data {
        guard !closed else { throw FxError.closed }
        guard turnID == nil, !cancelling, !checkpointing else { throw FxError.busy }
        checkpointing = true
        defer { checkpointing = false }
        let reply = try await rpc.request("libfx/checkpoint", .object(["sessionId": .string(sessionID)]))
        guard let id = reply["checkpointAttachment"]?.integer, let attachmentID = UInt32(exactly: id) else {
            throw FxError.protocolViolation("Invalid checkpoint attachment")
        }
        return try await transport.takeAttachment(id: attachmentID)
    }

    public func flushPersistence() async throws { try await journal?.check() }

    /// Saves a journal snapshot through the configured checkpoint persistence store.
    public func saveCheckpoint() async throws {
        guard !closed else { throw FxError.closed }
        guard turnID == nil, !cancelling, !checkpointing else { throw FxError.busy }
        guard let journal else { throw FxError.invalidInput("Persistence store is required") }
        checkpointing = true
        defer { checkpointing = false; checkpointSaveTask = nil }
        let task = Task { [rpc, transport, sessionID] in
            try await journal.check()
            let reply = try await rpc.request("libfx/snapshot", .object(["sessionId": .string(sessionID)]))
            guard let rawID = reply["snapshotAttachment"]?.integer, let attachmentID = UInt32(exactly: rawID),
                  let rawSequence = reply["atSeq"]?.integer, let sequence = UInt64(exactly: rawSequence) else {
                throw FxError.protocolViolation("Invalid journal snapshot")
            }
            let data = try await transport.takeAttachment(id: attachmentID)
            try await journal.saveSnapshot(data, at: sequence)
        }
        checkpointSaveTask = task
        try await task.value
    }

    public func close() async throws {
        if let closingTask { try await closingTask.value; return }
        closed = true
        if let turnID { finish(turn: turnID, error: FxError.closed) }
        let checkpointSave = checkpointSaveTask
        let task = Task {
            let saved = await checkpointSave?.result
            await rpc.close()
            try await journal?.check()
            try saved?.get()
        }
        closingTask = task
        try await task.value
    }
}
