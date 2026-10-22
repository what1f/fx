import Foundation
import LibFxMCP
@_spi(Conformance) import LibFx

enum DriverOutput {
    private static let lock = NSLock()
    static func emit(_ value: JSONValue) {
        lock.withLock {
            do {
                var data = try JSONEncoder().encode(value)
                data.append(10)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch { /* A closed test pipe is handled by process teardown. */ }
        }
    }
}

private struct RelayedCheckpointStore: FxCheckpointPersistence {
    let driver: Driver
    func load() async throws -> FxPersistenceSnapshot { try await driver.load() }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        try await driver.append(expected: expected, idempotencyKey: idempotencyKey, data: data, barrier: barrier)
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws { try await driver.saveCheckpoint(checkpoint) }
}

/// Test-only protocol adapter. Engine behavior stays in LibFx.
actor Driver: FxHTTPClient, FxPersistence {
    private var fixtureTransport: FixtureTransport?
    private let inputObservations = InputObservationRelay(emit: DriverOutput.emit)
    private var mcpAdapter: FxMCPAdapter?
    private var mcpTransport: DriverMCPTransport?
    private var mcpObservations: [String: FxToolObservation] = [:]
    private var mcpCalls: [String: Task<FxToolResult, Error>] = [:]
    private var providerLabel = "gateway"
    private var agent: FxAgent?
    private var sessionStore: FxSessionStore?
    private var sessionDeliveries: [String: Task<Void, Never>] = [:]
    private var sessionReaders: [String: Task<JSONValue, any Error>] = [:]
    private var refreshTasks: [String: Task<FxSubscriptionCredentials, any Error>] = [:]
    private var sessionTurns: [String: FxSessionTurn] = [:]
    private var refreshOperations: [String: FxSubscription.RefreshOperation] = [:]
    private var refreshWaiters: [String: CheckedContinuation<FxSubscriptionCredentials, any Error>] = [:]
    private var engine: FxEngine?
    private var store: (any FxPersistence)?
    private var turns: [String: FxTurn] = [:]
    private var credentialWaiters: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var permissionWaiters: [String: CheckedContinuation<FxPermissionDecision, any Error>] = [:]
    private var nextFetchID = 1
    private var retryObservers: [String: CheckedContinuation<Void, Never>] = [:]
    private var fetchWaiters: [Int: CheckedContinuation<FxHTTPResponse, any Error>] = [:]
    private var fetchBodies: [Int: AsyncThrowingStream<Data, any Error>.Continuation] = [:]
    private var fetchStreams: [Int: AsyncThrowingStream<Data, any Error>] = [:]
    private var nextToolID = 1
    private var toolWaiters: [Int: CheckedContinuation<FxToolResult, any Error>] = [:]
    private var nextPersistenceID = 1
    private var persistenceWaiters: [Int: CheckedContinuation<JSONValue, any Error>] = [:]

    func emit(_ value: JSONValue) {
        DriverOutput.emit(value)
    }

    func handle(_ value: JSONValue) async {
        let id = value["id"] ?? .null
        do {
            let result = try await run(value)
            emit(.object(["id": id, "result": result]))
        } catch {
            var fields: [String: JSONValue] = ["message": .string(String(describing: error))]
            if case FxError.invalidInput(let message) = error {
                fields["message"] = .string(javascriptMessage(message))
                fields["category"] = .string(message == "Reasoning effort must not exceed 64 bytes" ? "range" : "type")
            }
            if case FxError.noActiveTurn = error { fields["message"] = .string("no prompt is running") }
            if case FxSessionError.messageIDInUse = error {
                fields["data"] = .object(["code": .string("FX_MESSAGE_ID_IN_USE")])
            }
            if let catalogError = error as? FxModelCatalogError {
                fields["message"] = .string(catalogError.localizedDescription)
                switch catalogError {
                case .invalidAPIKey, .malformedResponse: fields["category"] = .string("type")
                case .byteLimit, .entryLimit: fields["category"] = .string("range")
                case .httpStatus: break
                }
            }
            if case FxError.rpc(let code, let message, let data) = error {
                fields["message"] = .string(message)
                fields["rpcCode"] = .number(Double(code))
                fields["data"] = data
            }
            emit(.object(["id": id, "error": .object(fields)]))
        }
    }

    private func emitFailure(_ error: any Error, token: String) {
        var fields: [String: JSONValue] = ["failed": .string(String(describing: error)), "turnToken": .string(token)]
        if let persistenceError = error as? FxPersistenceError {
            fields["persistenceError"] = .string(String(describing: persistenceError))
        }
        emit(.object(fields))
    }

    private func deliver(_ next: FxTurn, token: String) {
        guard let engine else { return }
        turns[token] = next
        emit(.object(["turnStarted": .string(token), "turnID": .string(next.id)]))
        Task {
            do {
                for try await event in next { emit(.object(["event": encode(event), "turnToken": .string(token)])) }
                let result = try await next.result
                let recovery = await engine.recoveryState
                emit(.object([
                    "turnToken": .string(token), "completed": encode(result), "recovery": .object([
                        "resumable": .bool(await engine.hasResumableWork), "openTurnId": recovery?.turnID.map(JSONValue.string) ?? .null,
                        "runningCalls": .array((recovery?.runningCalls ?? []).map {
                            .object(["executionId": .string($0.executionID), "name": .string($0.name), "input": $0.input])
                        }),
                    ]),
                ]))
            } catch { emitFailure(error, token: token) }
            turns.removeValue(forKey: token)
        }
    }

    private func run(_ value: JSONValue) async throws -> JSONValue {
        switch value["op"]?.string {
        case "observationOpen":
            return try await inputObservations.openFixture(scope: value["scope"] ?? .null,
                callID: value["callID"]?.string ?? "", captureContent: value["captureContent"] == .bool(true))
        case "observationCancel":
            await inputObservations.invalidate(tool: 1)
            return .null
        case "fixtureReceive":
            guard let fixtureTransport else { throw FxError.closed }
            try await fixtureTransport.receive(value["message"] ?? .null)
            try await engine?.drainConformanceFrames()
            return .null
        case "fixtureTool":
            guard let fixtureTransport, let engine else { throw FxError.closed }
            let callID = value["callID"]?.string ?? ""
            let reply = try await fixtureTransport.executeTool(name: value["name"]?.string ?? "", input: value["input"] ?? .null,
                sessionID: value["sessionID"]?.string ?? "", callID: callID)
            await engine.joinConformanceTool(callID)
            if reply["error"] != nil { return .object(["cancelled": .bool(true)]) }
            return reply["result"] ?? .null
        case "mcpOpen":
            let transport = DriverMCPTransport { [weak self] data in
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
                await self?.emit(.object(["mcpSend": message]))
            }
            mcpTransport = transport
            let options = value["options"] ?? .null
            var resources: [String] = []
            var prompts: [FxMCPAdapter.Prompt] = []
            if case .array(let values) = options["resources"] { resources = values.compactMap(\.string) }
            if case .array(let values) = options["prompts"] {
                prompts = values.map { entry in
                    var arguments: [String: String]?
                    if case .object(let fields) = entry["arguments"] { arguments = fields.compactMapValues(\.string) }
                    return .init(name: entry.string ?? entry["name"]?.string ?? "", arguments: arguments)
                }
            }
            let adapter = try await FxMCPAdapter.connect(transport: transport, prefix: options["prefix"]?.string ?? "",
                resources: resources, prompts: prompts, propagateCorrelation: options["propagateCorrelation"] == .bool(true), serverName: options["serverName"]?.string)
            mcpAdapter = adapter
            return .object(["instructions": .string(adapter.instructions), "tools": .array(adapter.tools.map {
                .object(["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema, "idempotent": .bool(false)])
            })])
        case "mcpReceive":
            await mcpTransport?.receive(try JSONEncoder().encode(value["message"] ?? .null))
            return .null
        case "mcpExecute":
            guard let adapter = mcpAdapter, let tool = adapter.tools.first(where: { $0.name == value["name"]?.string }),
                  let token = value["token"]?.string else { throw FxError.closed }
            let observation = try relayedMCPObservation(value["observation"], token: token)
            if let observation { mcpObservations[token] = observation }
            let context = FxToolContext(executionID: value["executionId"]?.string ?? "mcp", sessionID: value["sessionId"]?.string ?? "mcp",
                                        turnID: value["turnId"]?.string ?? "mcp", context: value["context"], observation: observation)
            let task = Task { try await tool.execute(value["input"] ?? .object([:]), context) }
            mcpCalls[token] = task
            defer {
                mcpCalls.removeValue(forKey: token)
                mcpObservations.removeValue(forKey: token)?.invalidate()
            }
            let result = try await task.value
            return .object(["type": .string("libfx.tool-result"), "text": .string(result.text), "isError": .bool(result.isError),
                "images": .array(result.images.map { image in
                    .object(["type": .string("image"), "mimeType": .string(image.format.rawValue), "data": .string(image.data?.base64EncodedString() ?? "")])
                })])
        case "mcpInvalidate":
            if let token = value["token"]?.string { mcpObservations[token]?.invalidate() }
            return .null
        case "mcpCancel":
            if let token = value["token"]?.string { mcpCalls[token]?.cancel() }
            return .null
        case "mcpClose":
            for observation in mcpObservations.values { observation.invalidate() }
            let calls = Array(mcpCalls.values)
            for call in calls { call.cancel() }
            await mcpAdapter?.close()
            for call in calls { _ = await call.result }
            mcpCalls.removeAll(); mcpObservations.removeAll(); mcpAdapter = nil; mcpTransport = nil
            return .null
        case "open", "openAgent":
            let options = value["options"] ?? .null
            providerLabel = options["provider"]?.string ?? options["provider"]?["name"]?.string ?? "gateway"
            try validateRepresentation(options)
            var tools: [FxTool] = []
            var providerTools: [FxProviderTool] = []
            if case .array(let descriptors) = options["tools"] {
                for descriptor in descriptors {
                    let name = descriptor["name"]?.string ?? ""
                    if descriptor["providerExecuted"] == .bool(true) {
                        guard let tool = FxProviderTool(rawValue: name) else { throw FxError.invalidInput("Unsupported provider tool") }
                        providerTools.append(tool)
                        continue
                    }
                    tools.append(FxTool(
                        name: name, description: descriptor["description"]?.string ?? "",
                        inputSchema: descriptor["inputSchema"] ?? .object([:]),
                        isIdempotent: descriptor["idempotent"] == .bool(true),
                        writes: descriptor["writes"] == nil ? nil : descriptor["writes"] == .bool(true)
                    ) { [weak self] input, context in
                        guard let self else { throw FxError.closed }
                        return try await self.callTool(name, input: input, context: context)
                    })
                }
            }
            let modelOption = options["model"] ?? .null
            let model = FxModel(
                id: modelOption["id"]?.string,
                reasoningEffort: modelOption["effort"]?.string,
                fast: bool(modelOption["fast"]),
                ultrafast: bool(modelOption["ultrafast"])
            )
            var config = FxConfiguration(
                apiKey: options["apiKey"]?.string ?? "", model: model,
                instructions: options["instructions"]?.string ?? "", tools: tools, providerTools: providerTools
            )
            if let name = options["provider"]?["name"]?.string,
               let base = options["provider"]?["baseUrl"]?.string, let url = URL(string: base) {
                var models: [String: FxCustomProvider.ModelCapabilities] = [:]
                if case .object(let entries) = options["provider"]?["models"] {
                    for (id, value) in entries {
                        models[id] = .init(
                            contextWindow: value["contextWindow"]?.integer.flatMap(UInt32.init(exactly:)),
                            maxOutputTokens: value["maxOutputTokens"]?.integer.flatMap(UInt32.init(exactly:)),
                            supportsToolUse: bool(value["supportsToolUse"]), supportsVision: bool(value["supportsVision"])
                        )
                    }
                }
                let provider = try FxCustomProvider(name: name, baseURL: url, models: models)
                if options["hasCredentials"] == .bool(true) {
                    config.provider = .custom(provider, credentials: { [weak self] request in
                        guard let self else { throw FxError.closed }
                        let value = try await self.credentials(request)
                        guard let key = value["apiKey"]?.string else { throw FxError.invalidInput("Missing API key") }
                        return key
                    })
                } else { config.provider = .custom(provider) }
            }
            if let name = options["provider"]?.string, let provider = FxSubscriptionProvider(rawValue: name) {
                guard options["hasCredentials"] == .bool(true) else { throw FxError.invalidInput("Subscription credentials are required") }
                let save: (@Sendable (FxSubscriptionCredentials, FxCredentialRequest) async throws -> Void)?
                if options["hasOnCredentials"] == .bool(true) {
                    save = { [weak self] credentials, context in
                        guard let self else { throw FxError.closed }
                        _ = try await self.credentials(context, saving: credentials)
                    }
                } else { save = nil }
                let refreshLock: FxSubscription.RefreshLock?
                if options["hasRefreshLock"] == .bool(true) {
                    refreshLock = { [weak self] context, operation in
                        guard let self else { throw FxError.closed }
                        return try await self.withRefreshLock(context, operation: operation)
                    }
                } else { refreshLock = nil }
                config.provider = .subscription(FxSubscription(provider: provider, credentials: { [weak self] context in
                    guard let self else { throw FxError.closed }
                    let value = try await self.credentials(context)
                    guard let token = value["accessToken"]?.string else { throw FxError.invalidInput("Missing access token") }
                    let expiry: Date?
                    if case .number(let ms) = value["expiresAt"] { expiry = Date(timeIntervalSince1970: ms / 1000) }
                    else { expiry = nil }
                    return try FxSubscriptionCredentials(accessToken: token, refreshToken: value["refreshToken"]?.string,
                                                         accountID: value["accountId"]?.string, expiresAt: expiry)
                }, onRefresh: save, refreshLock: refreshLock))
            }
            if let url = options["gatewayChatUrl"]?.string, let endpoint = URL(string: url) { config.gatewayURL = endpoint }
            config.httpClient = self
            if let bytes = options["checkpointAfterBytes"] {
                if bytes == .null { config.checkpointAfterBytes = nil }
                else if let count = bytes.integer { config.checkpointAfterBytes = count }
                else { throw FxError.invalidInput("Invalid checkpoint interval") }
            }
            if options["hooks"] != nil, options["hooks"] != .null {
                let parent: FxObservationParent?
                if let value = options["hooks"]?["parent"], value != .null {
                    parent = try FxObservationParent(rootSessionID: value["rootSessionId"]?.string ?? "",
                        sessionID: value["sessionId"]?.string ?? "", turnID: value["turnId"]?.string ?? "", callID: value["callId"]?.string ?? "")
                } else { parent = nil }
                config.observation = FxObservationOptions(captureContent: options["hooks"]?["captureContent"] == .bool(true), parent: parent) { event in
                    DriverOutput.emit(.object(["observation": try encodeObservation(event)]))
                } onError: { error in
                    DriverOutput.emit(.object(["observationError": .string(String(describing: error))]))
                }
            }
            config.onLifecycleEvent = { event in
                DriverOutput.emit(.object(["diagnostic": encodeLifecycleEvent(event)]))
            }
            config.onTransportEvent = { [weak self] event in
                if case .retrying = event { await self?.observeRetry(event) }
                else { DriverOutput.emit(.object(["diagnostic": encodeTransportEvent(event)])) }
            }
            config.onPermission = { [weak self] request in
                guard let self else { throw FxError.closed }
                return try await self.requestPermission(request)
            }
            config.wireObserver = { [weak self] direction, message in
                await self?.emit(.object(["diagnostic": .object([
                    "type": .string(direction == .sent ? "acp.send" : "acp.receive"), "message": message,
                ])]))
            }
            if value["op"] == .string("openAgent") {
                let sessionStore = try FxSessionStore(url: options["sessionStorePath"]?.string.map { URL(fileURLWithPath: $0) })
                self.sessionStore = sessionStore
                let deliveryPolicy = try options["maximumDurationMs"]?.integer.map {
                    try FxDeliveryPolicy(maximumDuration: .milliseconds($0), reserve: .milliseconds(options["reserveMs"]?.integer ?? 30_000))
                }
                agent = try FxAgent(configuration: config, name: options["name"]?.string ?? "default", store: sessionStore,
                                    checkpoint: options["checkpoint"]?.string.flatMap { Data(base64Encoded: $0) },
                                    checkpointAfterBytes: options["checkpointAfterBytes"] == nil ? 64 * 1024 : config.checkpointAfterBytes,
                                    deliveryPolicy: deliveryPolicy)
                return .object([:])
            }
            let checkpoint = options["checkpoint"]?.string.flatMap { Data(base64Encoded: $0) }
            if let path = options["sqlitePath"]?.string {
                store = try FxSQLitePersistence(url: URL(fileURLWithPath: path))
            } else if options["hasCheckpointPersistence"] == .bool(true) {
                store = RelayedCheckpointStore(driver: self)
            } else if options["hasPersistence"] == .bool(true) { store = self }
            if options["hasRuntimeFactory"] == .bool(true) {
                guard checkpoint == nil, store == nil else {
                    throw FxError.invalidInput("Injected runtime fixtures do not support persistence")
                }
                let transport = FixtureTransport()
                fixtureTransport = transport
                engine = try await FxEngine.openForConformance(configuration: config, transport: transport)
            } else {
                engine = try await FxEngine.open(configuration: config, checkpoint: checkpoint, persistence: store)
            }
            let recovery = await engine!.recoveryState
            return .object([
                "sessionId": .string(engine!.sessionID), "resumable": .bool(await engine!.hasResumableWork),
                "openTurnId": recovery?.turnID.map(JSONValue.string) ?? .null,
                "runningCalls": .array((recovery?.runningCalls ?? []).map {
                    .object(["executionId": .string($0.executionID), "name": .string($0.name), "input": $0.input])
                }),
            ])
        case "sessionPrompt", "sessionResume", "sessionSteer":
            guard let agent, let sessionID = value["sessionID"]?.string else { throw FxError.closed }
            let session = try await agent.session(id: sessionID, options: sessionOptions(value["options"] ?? .null))
            let content: [FxPromptContent]
            if case .array(let blocks) = value["text"] {
                content = try blocks.map { block in
                    if block["type"] == .string("image") { return .image(try image(block)) }
                    guard let text = block["text"]?.string else { throw FxError.invalidInput("Unsupported prompt content") }
                    return .text(text)
                }
            } else { content = [.text(value["text"]?.string ?? "")] }
            if value["op"] == .string("sessionSteer") {
                let receipt = try await session.steer(content, id: value["messageID"]?.string ?? UUID().uuidString)
                return .object(["messageId": .string(receipt.id)])
            }
            let next: FxSessionTurn
            if value["op"] == .string("sessionResume") {
                guard let resumed = try await session.resume() else { throw FxError.noActiveTurn }
                next = resumed
            } else { next = try await session.prompt(content, id: value["messageID"]?.string ?? UUID().uuidString) }
            let token = value["turnToken"]?.string ?? next.id
            sessionTurns[token] = next
            emit(.object(["sessionAccepted": .string(token), "messageID": .string(next.id), "sessionID": .string(next.sessionID)]))
            sessionDeliveries[token] = Task {
                do {
                    for try await event in next { emit(.object(["event": encode(event), "turnToken": .string(token)])) }
                    let result = try await next.result
                    var fields: [String: JSONValue] = [
                        "id": .string(result.id), "stopReason": .string(result.stopReason.rawValue),
                        "epoch": .number(Double(result.epoch)), "isRepeated": .bool(result.isRepeated),
                    ]
                    if let usage = result.usage {
                        fields["usage"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(usage))
                    }
                    if let error = result.error { fields["error"] = .object(["message": .string(javascriptMessage(error))]) }
                    emit(.object(["turnToken": .string(token), "completed": .object(fields)]))
                } catch { emitFailure(error, token: token) }
                sessionTurns.removeValue(forKey: token)
                sessionDeliveries.removeValue(forKey: token)
            }
            return .object(["messageID": .string(next.id), "sessionID": .string(next.sessionID)])
        case "sessionCheckpoint":
            guard let agent, let id = value["sessionID"]?.string else { throw FxError.closed }
            let session = try await agent.session(id: id, options: sessionOptions(value["options"] ?? .null))
            return .string(try await session.checkpoint().base64EncodedString())
        case "sessionCancel":
            guard let agent, let id = value["sessionID"]?.string else { throw FxError.closed }
            let session = try await agent.session(id: id)
            try await session.cancel()
            return .null
        case "sessionNextEvent":
            guard let agent, let id = value["sessionID"]?.string, let token = value["readToken"]?.string else { throw FxError.closed }
            let session = try await agent.session(id: id)
            let cursor = Int64(value["cursor"]?.integer ?? 0)
            let read = Task {
                var iterator = session.events(after: cursor).makeAsyncIterator()
                guard let entry = try await iterator.next() else { return JSONValue.null }
                var fields: [String: JSONValue] = ["cursor": .number(Double(entry.cursor)), "epoch": .number(Double(entry.epoch))]
                switch entry.event {
                case .started(let id, let session):
                    fields["type"] = .string("turn_start")
                    fields["messageId"] = .string(id); fields["sessionId"] = .string(session)
                case .resumed(let id, let session):
                    fields["type"] = .string("turn_resume")
                    fields["messageId"] = .string(id); fields["sessionId"] = .string(session)
                case .yielded(let id):
                    fields["type"] = .string("turn_yield")
                    fields["messageId"] = .string(id)
                case .update(let id, let event):
                    if case .object(let update) = encode(event) { fields.merge(update) { _, new in new } }
                    fields["messageId"] = .string(id)
                case .ended(let result):
                    fields["type"] = .string("turn_end"); fields["messageId"] = .string(result.id)
                    fields["stopReason"] = .string(result.stopReason.rawValue)
                    fields["usage"] = try result.usage.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) } ?? .object([:])
                    if let error = result.error { fields["error"] = .object(["message": .string(error)]) }
                }
                return JSONValue.object(fields)
            }
            sessionReaders[token] = read
            defer { sessionReaders.removeValue(forKey: token) }
            return try await read.value
        case "sessionReadCancel":
            if let token = value["readToken"]?.string, let read = sessionReaders[token] {
                read.cancel()
                _ = await read.result
            }
            return .null
        case "refreshLockedOperation":
            guard let token = value["token"]?.string, let operation = refreshOperations.removeValue(forKey: token) else { throw FxError.closed }
            let task = Task { try await operation() }
            refreshTasks[token] = task
            defer { refreshTasks.removeValue(forKey: token) }
            return encodeCredentials(try await task.value)
        case "refreshLockResult":
            guard let token = value["token"]?.string, let waiter = refreshWaiters.removeValue(forKey: token) else { throw FxError.closed }
            refreshOperations.removeValue(forKey: token)
            do { waiter.resume(returning: try decodeCredentials(value["credentials"] ?? .null)) }
            catch { waiter.resume(throwing: error) }
            return .null
        case "inspectSession":
            guard let path = value["path"]?.string, let id = value["sessionID"]?.string else { throw FxError.invalidInput("Missing inspection target") }
            let store = try FxSessionStore(url: URL(fileURLWithPath: path))
            do {
                let inspected = try await store.inspect(sessionID: id, agent: value["agentName"]?.string ?? "default")
                let entries = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(inspected.entries))
                try await store.close()
                return .object(["records": .array(inspected.records.map { .string($0.base64EncodedString()) }), "entries": entries])
            } catch { try? await store.close(); throw error }
        case "listModels":
            let models = try await FxModel.available(apiKey: value["apiKey"]?.string ?? "", httpClient: self)
            return .array(try models.map {
                guard let id = $0.id else { throw FxModelCatalogError.malformedResponse }
                return .string(id)
            })
        case "prompt", "resume":
            guard let engine else { throw FxError.closed }
            let deadline: Date?
            if let raw = value["yieldAt"] {
                guard let milliseconds = raw.integer else { throw FxError.invalidInput("Invalid yield deadline") }
                deadline = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            } else { deadline = nil }
            if let raw = value["turnID"], raw.string == nil { throw FxError.invalidInput("Invalid turn ID") }
            let publicID = value["turnID"]?.string ?? UUID().uuidString
            let next: FxTurn
            if value["op"] == .string("resume") {
                var ids: Set<String> = []
                if case .array(let values) = value["rerun"] { ids = Set(values.compactMap(\.string)) }
                guard let resumed = try await engine.resume(rerunning: ids, yieldAt: deadline) else { return .null }
                next = resumed
            } else if case .array(let blocks) = value["text"] {
                let content = try blocks.map { block -> FxPromptContent in
                    if block["type"] == .string("image") { return .image(try image(block)) }
                    guard block["type"] == .string("text"), let text = block["text"]?.string else {
                        throw FxError.invalidInput("Unsupported prompt content")
                    }
                    return .text(text)
                }
                next = try await engine.prompt(content, id: publicID, yieldAt: deadline)
            } else { next = try await engine.prompt(value["text"]?.string ?? "", id: publicID, yieldAt: deadline) }
            deliver(next, token: value["turnToken"]?.string ?? next.id)
            return .object(["turnID": .string(next.id)])
        case "followUp":
            guard let engine else { throw FxError.closed }
            let receipt = try await engine.followUp(value["text"]?.string ?? "")
            let token = value["turnToken"]?.string ?? receipt.id
            Task {
                do {
                    try await receipt.accepted
                    emit(.object(["followUpAccepted": .string(token), "inputID": .string(receipt.id)]))
                } catch { emit(.object(["followUpRejected": .string(token), "error": .string(String(describing: error))])) }
            }
            Task {
                do { deliver(try await receipt.turn, token: token) }
                catch { emitFailure(error, token: token) }
            }
            return .object(["inputID": .string(receipt.id)])
        case "diagnosticAck":
            if let token = value["token"]?.string { retryObservers.removeValue(forKey: token)?.resume() }
            return .null
        case "cancel":
            if let token = value["turnToken"]?.string, let turn = sessionTurns[token] {
                try await turn.cancel()
                return .null
            }
            if let token = value["turnToken"]?.string, let turn = turns[token] {
                if value["reason"] == .string("handoff") { try await turn.handoff() }
                else { await turn.cancel() }
            }
            return .null
        case "steer":
            guard let token = value["turnToken"]?.string, let turn = turns[token] else { throw FxError.noActiveTurn }
            let receipt = try await turn.steer(value["text"]?.string ?? "", id: value["inputID"]?.string ?? UUID().uuidString)
            return .object(["id": .string(receipt.id)])
        case "withdraw":
            guard let token = value["turnToken"]?.string, let turn = turns[token] else { return .string(FxWithdrawal.alreadyPlaced.rawValue) }
            return .string(try await turn.withdraw(value["inputID"]?.string ?? "").rawValue)
        case "checkpoint":
            guard let engine else { throw FxError.closed }
            return .string(try await engine.checkpoint().base64EncodedString())
        case "saveCheckpoint":
            guard let engine else { throw FxError.closed }
            try await engine.saveCheckpoint()
            return .null
        case "close":
            for read in sessionReaders.values { read.cancel() }
            for read in Array(sessionReaders.values) { _ = await read.result }
            try await agent?.close()
            agent = nil
            for task in Array(sessionDeliveries.values) { await task.value }
            try await sessionStore?.close()
            sessionStore = nil
            try await engine?.close()
            engine = nil
            if let sqlite = store as? FxSQLitePersistence { try await sqlite.close() }
            store = nil
            for id in Array(fetchBodies.keys) { cancelFetch(id) }
            await inputObservations.close()
            for waiter in toolWaiters.values { waiter.resume(throwing: FxError.closed) }
            toolWaiters.removeAll()
            return .null
        case "fetchStart":
            guard let id = value["fetchID"]?.integer,
                  let waiter = fetchWaiters.removeValue(forKey: id), let body = fetchStreams.removeValue(forKey: id) else {
                throw FxError.invalidInput("Unknown fetch")
            }
            var headers: [String: String] = [:]
            if case .object(let entries) = value["headers"] { headers = entries.compactMapValues(\.string) }
            waiter.resume(returning: FxHTTPResponse(
                statusCode: value["status"]?.integer ?? 500, headers: headers, body: body,
                cancel: { [weak self] in Task { await self?.cancelFetch(id) } }
            ))
            return .null
        case "fetchChunk":
            guard let id = value["fetchID"]?.integer, let body = fetchBodies[id],
                  let text = value["data"]?.string, let bytes = Data(base64Encoded: text) else {
                throw FxError.invalidInput("Unknown fetch body")
            }
            if case .dropped = body.yield(bytes) { throw FxError.outputOverflow }
            return .null
        case "fetchEnd":
            if let id = value["fetchID"]?.integer { fetchBodies.removeValue(forKey: id)?.finish() }
            return .null
        case "fetchFailure":
            if let id = value["fetchID"]?.integer {
                let error = FxError.transport(value["error"]?.string ?? "Fetch failed")
                fetchWaiters.removeValue(forKey: id)?.resume(throwing: error)
                fetchBodies.removeValue(forKey: id)?.finish(throwing: error)
                fetchStreams.removeValue(forKey: id)
            }
            return .null
        case "permissionResult":
            if let token = value["token"]?.string, let waiter = permissionWaiters.removeValue(forKey: token) {
                waiter.resume(returning: value["optionID"]?.string.map { .select(optionID: $0) } ?? .cancel)
            }
            return .null
        case "credentialResult":
            guard let token = value["token"]?.string, let waiter = credentialWaiters.removeValue(forKey: token) else {
                throw FxError.invalidInput("Unknown credential request")
            }
            if let credentials = value["credentials"] { waiter.resume(returning: credentials) }
            else { waiter.resume(throwing: FxError.invalidInput("Credentials are unavailable")) }
            return .null
        case "observeInput":
            guard let tool = value["toolID"]?.integer, let token = value["token"]?.string else {
                throw FxError.invalidInput("Invalid input observation")
            }
            try await inputObservations.observe(tool: tool, token: token, descriptor: value["request"] ?? .null)
            return .null
        case "inputResult":
            if let token = value["token"]?.string {
                await inputObservations.resolve(token, value: value["resolution"] ?? .null, errorName: value["errorName"]?.string)
            }
            return .null
        case "toolResult":
            guard let requestID = value["toolID"]?.integer,
                  let waiter = toolWaiters.removeValue(forKey: requestID) else { throw FxError.invalidInput("Unknown tool result") }
            if let error = value["error"]?.string { waiter.resume(throwing: FxError.transport(error)) }
            else if let result = value["rich"] {
                do {
                    let images: [FxImage]
                    if case .array(let entries) = result["images"] { images = try entries.map(image) }
                    else { images = [] }
                    waiter.resume(returning: FxToolResult(
                        text: result["text"]?.string ?? "", images: images, isError: result["isError"] == .bool(true)
                    ))
                } catch { waiter.resume(throwing: error) }
            } else { waiter.resume(returning: FxToolResult(text: value["content"]?.string ?? "")) }
            return .null
        case "persistenceResult":
            guard let id = value["persistenceID"]?.integer, let waiter = persistenceWaiters.removeValue(forKey: id) else {
                throw FxError.invalidInput("Unknown persistence operation")
            }
            if let error = value["error"]?.string {
                waiter.resume(throwing: value["code"] == .string("FX_FENCED") ? FxPersistenceError.fenced : FxError.transport(error))
            } else { waiter.resume(returning: value["value"] ?? .null) }
            return .null
        default: throw FxError.invalidInput("Unknown driver operation")
        }
    }

    // Reject shapes that cannot be represented by Swift's typed provider API.
    private func validateRepresentation(_ options: JSONValue) throws {
        let custom: Bool
        if case .object = options["provider"] { custom = true } else { custom = false }
        let subscription = ["codex", "grok"].contains(providerLabel) && !custom
        if !custom, !["gateway", "codex", "grok"].contains(providerLabel) {
            throw FxError.invalidInput("provider must be \"gateway\", \"codex\", \"grok\" or a custom provider")
        }
        for field in ["credentials", "onCredentials", "refreshLock"] {
            if let kind = options[field + "Type"]?.string, !["function", "undefined"].contains(kind) {
                throw FxError.invalidInput("\(field) must be a function")
            }
        }
        if options["hasRefreshLock"] == .bool(true), !subscription {
            throw FxError.invalidInput("refreshLock needs provider \"codex\" or \"grok\"")
        }
        if options["hasOnCredentials"] == .bool(true), !subscription {
            throw FxError.invalidInput("onCredentials needs provider \"codex\" or \"grok\"")
        }
        if options["hasCredentials"] == .bool(true), !subscription, !custom {
            throw FxError.invalidInput("credentials needs provider \"codex\" or \"grok\" or a custom provider")
        }
        if subscription, options["hasCredentials"] != .bool(true) {
            throw FxError.invalidInput("provider \"\(providerLabel)\" needs a credentials() function")
        }
        if case .object(let fields) = options["provider"] {
            for key in fields.keys.sorted() where !["name", "baseUrl", "models"].contains(key) {
                throw FxError.invalidInput("unknown field \(key)")
            }
            if case .object(let models) = fields["models"] {
                for model in models.values {
                    if case .object(let capabilities) = model {
                        for key in capabilities.keys.sorted() where !["contextWindow", "maxOutputTokens", "supportsVision", "supportsToolUse"].contains(key) {
                            throw FxError.invalidInput("unknown field \(key)")
                        }
                        for key in ["supportsVision", "supportsToolUse"] {
                            if let value = capabilities[key], bool(value) == nil { throw FxError.invalidInput("\(key) must be a boolean") }
                        }
                    }
                }
            }
        }
    }

    private func javascriptMessage(_ message: String) -> String {
        switch message {
        case "Invalid provider name": return "provider.name must be 1 to 64 letters, digits, underscores or hyphens, starting with a letter"
        case "Provider URL must use HTTPS or local HTTP, without credentials, query, or fragment":
            return "provider URL must use https, or http on localhost, without credentials, a query or a fragment"
        case "Output token limit must be less than the context window": return "maxOutputTokens must be less than contextWindow"
        case "API key is required": return "apiKey is required"
        case "Model is required":
            if providerLabel == "gateway" { return "Model is required" }
            if ["codex", "grok"].contains(providerLabel) {
                return "provider \"\(providerLabel)\" needs a model; fx's default model is an AI Gateway id"
            }
            return "a custom provider needs a model"
        default: return message
        }
    }

    private func persistenceRequest(_ kind: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        let id = nextPersistenceID
        nextPersistenceID += 1
        return try await withCheckedThrowingContinuation { continuation in
            persistenceWaiters[id] = continuation
            var request = fields
            request["id"] = .number(Double(id))
            request["kind"] = .string(kind)
            emit(.object(["persistenceRequest": .object(request)]))
        }
    }

    func load() async throws -> FxPersistenceSnapshot {
        let value = try await persistenceRequest("load")
        var records: [FxJournalRecord] = []
        if case .array(let entries) = value["journal"] {
            for entry in entries {
                guard let cursor = entry["cursor"]?.string, let encoded = entry["data"]?.string,
                      let data = Data(base64Encoded: encoded) else { throw FxPersistenceError.invalidJournal }
                records.append(.init(cursor: cursor, data: data))
            }
        }
        var checkpoint: FxStoredCheckpoint?
        if let saved = value["checkpoint"], saved != .null {
            guard let through = saved["through"]?.string, let encoded = saved["data"]?.string,
                  let data = Data(base64Encoded: encoded) else { throw FxPersistenceError.invalidJournal }
            checkpoint = .init(through: through, data: data)
        }
        return FxPersistenceSnapshot(checkpoint: checkpoint, journal: records, head: value["head"]?.string)
    }

    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        let value = try await persistenceRequest("append", [
            "expected": expected.map(JSONValue.string) ?? .null, "idempotencyKey": .string(idempotencyKey),
            "data": .string(data.base64EncodedString()), "barrier": .bool(barrier),
        ])
        guard let cursor = value["cursor"]?.string else { throw FxPersistenceError.invalidCursor }
        return cursor
    }

    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws {
        _ = try await persistenceRequest("saveCheckpoint", [
            "through": .string(checkpoint.through), "data": .string(checkpoint.data.base64EncodedString()),
        ])
    }

    private func sessionOptions(_ options: JSONValue) -> FxSessionOptions {
        FxSessionOptions(model: options["model"].map {
            FxModel(id: $0.string ?? $0["id"]?.string ?? "", reasoningEffort: $0["effort"]?.string,
                    fast: bool($0["fast"]), ultrafast: bool($0["ultrafast"]))
        }, instructions: options["instructions"]?.string, context: options["context"])
    }

    private func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let flag) = value else { return nil }
        return flag
    }

    private func image(_ value: JSONValue) throws -> FxImage {
        guard let mime = value["mimeType"]?.string, let format = FxImageFormat(rawValue: mime) else {
            throw FxError.invalidInput("Unsupported image format")
        }
        let reference = value["sourceRef"]?.string
        if let encoded = value["data"]?.string, let data = Data(base64Encoded: encoded) {
            return FxImage(data: data, format: format, sourceReference: reference)
        }
        if let reference { return FxImage(reference: reference, format: format) }
        throw FxError.invalidInput("Image data or reference is required")
    }

    private func requestPermission(_ request: FxPermissionRequest) async throws -> FxPermissionDecision {
        let token = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiter in
                permissionWaiters[token] = waiter
                var tool: [String: JSONValue] = ["toolCallId": .string(request.tool.id), "name": .string(request.tool.name),
                                                "title": .string(request.tool.title), "kind": .string(request.tool.kind.rawValue)]
                if case .complete(let input) = request.tool.input { tool["rawInput"] = input }
                if case .truncated(let preview) = request.tool.input { tool["inputPreview"] = .string(preview) }
                emit(.object(["permissionRequest": .object([
                    "token": .string(token), "sessionId": .string(request.sessionID), "turnId": .string(request.turnID),
                    "toolCall": .object(tool), "options": .array(request.options.map { option in
                        .object(["optionId": .string(option.id), "name": .string(option.name), "kind": .string(option.kind.rawValue)])
                    }),
                ])]))
            }
        } onCancel: { Task { await self.cancelPermission(token) } }
    }

    private func cancelPermission(_ token: String) { permissionWaiters.removeValue(forKey: token)?.resume(throwing: FxError.cancelled) }

    private func observeRetry(_ event: FxTransportEvent) async {
        let token = UUID().uuidString
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { continuation in
                retryObservers[token] = continuation
                DriverOutput.emit(.object(["diagnostic": encodeTransportEvent(event), "diagnosticToken": .string(token)]))
            }
        } onCancel: { Task { await self.finishRetryObservation(token) } }
    }

    private func finishRetryObservation(_ token: String) { retryObservers.removeValue(forKey: token)?.resume() }

    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        let id = nextFetchID
        nextFetchID += 1
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        fetchBodies[id] = continuation
        fetchStreams[id] = body
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { Task { await self?.cancelFetch(id) } }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiter in
                fetchWaiters[id] = waiter
                emit(.object(["fetchRequest": .object([
                    "id": .number(Double(id)), "url": .string(request.url!.absoluteString),
                    "method": .string(request.httpMethod ?? "GET"),
                    "headers": .object((request.allHTTPHeaderFields ?? [:]).mapValues(JSONValue.string)),
                    "body": .string((request.httpBody ?? Data()).base64EncodedString()),
                ])]))
            }
        } onCancel: { Task { await self.cancelFetch(id) } }
    }

    private func cancelFetch(_ id: Int) {
        fetchWaiters.removeValue(forKey: id)?.resume(throwing: FxError.cancelled)
        fetchBodies.removeValue(forKey: id)?.finish(throwing: FxError.cancelled)
        fetchStreams.removeValue(forKey: id)
        emit(.object(["fetchCancelled": .number(Double(id))]))
    }

    private func credentials(_ request: FxCredentialRequest, saving: FxSubscriptionCredentials? = nil) async throws -> JSONValue {
        let token = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiter in
                credentialWaiters[token] = waiter
                emit(.object(["credentialRequest": .object([
                    "token": .string(token), "provider": .string(request.provider), "sessionId": request.sessionID.map(JSONValue.string) ?? .null,
                    "saving": saving.map { credentials in .object([
                        "accessToken": .string(credentials.accessToken), "refreshToken": credentials.refreshToken.map(JSONValue.string) ?? .null,
                        "accountId": credentials.accountID.map(JSONValue.string) ?? .null,
                        "expiresAt": credentials.expiresAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null,
                    ]) } ?? .null,
                ])]))
            }
        } onCancel: { Task { await self.cancelCredentials(token) } }
    }

    private func encodeCredentials(_ value: FxSubscriptionCredentials) -> JSONValue {
        .object(["accessToken": .string(value.accessToken), "refreshToken": value.refreshToken.map(JSONValue.string) ?? .null,
                 "accountId": value.accountID.map(JSONValue.string) ?? .null,
                 "expiresAt": value.expiresAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null])
    }

    private func decodeCredentials(_ value: JSONValue) throws -> FxSubscriptionCredentials {
        guard let token = value["accessToken"]?.string else { throw FxError.invalidInput("Refresh lock returned no credentials") }
        let expiry: Date?
        if case .number(let ms) = value["expiresAt"] { expiry = Date(timeIntervalSince1970: ms / 1000) } else { expiry = nil }
        return try FxSubscriptionCredentials(accessToken: token, refreshToken: value["refreshToken"]?.string,
                                             accountID: value["accountId"]?.string, expiresAt: expiry)
    }

    private func withRefreshLock(_ context: FxCredentialRequest, operation: @escaping FxSubscription.RefreshOperation) async throws -> FxSubscriptionCredentials {
        let token = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiter in
                refreshOperations[token] = operation
                refreshWaiters[token] = waiter
                emit(.object(["refreshLockRequest": .object(["token": .string(token), "provider": .string(context.provider),
                    "sessionId": context.sessionID.map(JSONValue.string) ?? .null])]))
            }
        } onCancel: { Task { await self.cancelRefreshLock(token) } }
    }

    private func cancelRefreshLock(_ token: String) {
        refreshTasks.removeValue(forKey: token)?.cancel()
        refreshOperations.removeValue(forKey: token)
        refreshWaiters.removeValue(forKey: token)?.resume(throwing: FxError.cancelled)
    }

    private func cancelCredentials(_ token: String) {
        credentialWaiters.removeValue(forKey: token)?.resume(throwing: FxError.cancelled)
    }

    private func callTool(_ name: String, input: JSONValue, context: FxToolContext) async throws -> FxToolResult {
        let id = nextToolID
        nextToolID += 1
        let observation = try await inputObservations.register(id, scope: context.observation)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiter in
                toolWaiters[id] = waiter
                emit(.object(["toolRequest": .object([
                    "id": .number(Double(id)), "name": .string(name), "input": input,
                    "executionId": .string(context.executionID), "sessionId": .string(context.sessionID),
                    "turnId": .string(context.turnID), "context": context.context ?? .null,
                    "observation": observation ?? .null,
                ])]))
            }
        } onCancel: { Task { await self.cancelTool(id) } }
    }

    private func cancelTool(_ id: Int) async {
        await inputObservations.cancel(tool: id)
        toolWaiters.removeValue(forKey: id)?.resume(throwing: FxError.cancelled)
        emit(.object(["toolCancelled": .number(Double(id))]))
    }

    private func encode(_ event: FxEvent) -> JSONValue {
        switch event {
        case .text(let delta): return .object(["type": .string("text_delta"), "delta": .string(delta)])
        case .reasoning(let delta): return .object(["type": .string("reasoning_delta"), "delta": .string(delta)])
        case .userMessage(let text, let id):
            var value: [String: JSONValue] = ["type": .string("user_message"), "text": .string(text)]
            if let id { value["id"] = .string(id) }
            return .object(value)
        case .toolStarted(let id, let name, let input):
            var value: [String: JSONValue] = ["type": .string("tool_start"), "id": .string(id), "name": .string(name)]
            switch input {
            case .complete(let input): value["input"] = input
            case .truncated(let preview):
                value["inputTruncated"] = .bool(true)
                value["inputPreview"] = .string(preview)
            case nil: break
            }
            return .object(value)
        case .toolFinished(let id, let name, let content, let isError):
            var value: [String: JSONValue] = ["type": .string("tool_end"), "id": .string(id), "name": .string(name), "isError": .bool(isError)]
            if let content { value["content"] = .string(content) }
            return .object(value)
        }
    }

    private func encode(_ result: FxTurnResult) -> JSONValue {
        var usage: [String: JSONValue] = [:]
        for (name, value) in [
            ("inputTokens", result.usage.inputTokens), ("outputTokens", result.usage.outputTokens),
            ("cacheReadTokens", result.usage.cacheReadTokens), ("cacheWriteTokens", result.usage.cacheWriteTokens),
            ("reasoningTokens", result.usage.reasoningTokens),
        ] { if let value { usage[name] = .number(Double(value)) } }
        return .object(["stopReason": .string(result.stopReason.rawValue), "usage": .object(usage)])
    }
}

@main struct FxSwiftDriver {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "skill-file" {
            struct Input: Decodable { let path: String; let resources: [FxSkill.Resource]? }
            struct Output: Encodable {
                let name: String; let description: String; let instructions: String; let resources: [FxSkill.Resource]
            }
            do {
                let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
                let skill = try await FxSkill.load(from: URL(fileURLWithPath: input.path), resources: input.resources ?? [])
                FileHandle.standardOutput.write(try JSONEncoder().encode(Output(name: skill.name, description: skill.description,
                    instructions: skill.instructions, resources: skill.resources)))
            } catch {
                FileHandle.standardError.write(Data("Skill file loading failed: \(error)\n".utf8))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.dropFirst().first == "skills" {
            struct Record: Decodable {
                let name: String
                let description: String?
                let instructions: String
                let resources: [FxSkill.Resource]?
            }
            do {
                let records = try JSONDecoder().decode([Record].self, from: FileHandle.standardInput.readDataToEndOfFile())
                let skills = try FxSkills(records.map {
                    FxSkill(name: $0.name, description: $0.description ?? "", instructions: $0.instructions,
                            resources: $0.resources ?? [])
                })
                FileHandle.standardOutput.write(try JSONEncoder().encode(["instructions": skills.instructions]))
            } catch {
                FileHandle.standardError.write(Data("Skill configuration failed: \(error)\n".utf8))
                exit(1)
            }
            return
        }
        let driver = Driver()
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                Task { await driver.handle(value) }
            }
        } catch { await driver.emit(.object(["fatal": .string(String(describing: error))])) }
        // A graceful caller sends close before ending input. EOF without that
        // request means the host died; do not wait for callbacks from a dead host.
    }
}

private func encodeTransportEvent(_ event: FxTransportEvent) -> JSONValue {
    func milliseconds(_ elapsed: Duration) -> JSONValue {
        .number(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
    func optional(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
    var fields: [String: JSONValue]
    switch event {
    case .started(let request):
        fields = ["type": .string("transport.start"), "attempt": .number(Double(request.number)),
                  "method": .string(request.method), "endpoint": optional(request.endpoint?.absoluteString), "model": optional(request.modelID)]
    case .response(let request, let response):
        fields = ["type": .string("transport.response"), "attempt": .number(Double(request.number)),
                  "status": .number(Double(response.statusCode)), "elapsedMs": milliseconds(response.elapsed),
                  "requestId": optional(response.requestID), "generationId": optional(response.generationID),
                  "model": optional(response.modelID), "provider": optional(response.provider)]
    case .failed(let request, let elapsed, let reason):
        fields = ["type": .string("transport.error"), "attempt": .number(Double(request.number)),
                  "elapsedMs": milliseconds(elapsed), "error": .string(reason == .cancelled ? "AbortError" : "Error")]
    case .activity(let request, let chunkBytes, let totalBytes):
        fields = ["type": .string("transport.activity"), "attempt": .number(Double(request.number)),
                  "chunkBytes": .number(Double(chunkBytes)), "totalBytes": .number(Double(totalBytes))]
    case .retrying(let request):
        fields = ["type": .string("transport.retry"), "attempt": .number(Double(request.number)),
                  "nextAttempt": .number(Double(request.number + 1))]
    }
    return .object(fields)
}
