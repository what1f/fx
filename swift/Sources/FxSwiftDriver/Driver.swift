import Foundation
@_spi(Conformance) import LibFx

private enum DriverOutput {
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
    private var providerLabel = "gateway"
    private var agent: FxAgent?
    private var sessionStore: FxSessionStore?
    private var sessionDeliveries: [String: Task<Void, Never>] = [:]
    private var refreshTasks: [String: Task<FxSubscriptionCredentials, any Error>] = [:]
    private var sessionTurns: [String: FxSessionTurn] = [:]
    private var refreshOperations: [String: FxSubscription.RefreshOperation] = [:]
    private var refreshWaiters: [String: CheckedContinuation<FxSubscriptionCredentials, any Error>] = [:]
    private var engine: FxEngine?
    private var store: (any FxPersistence)?
    private var turns: [String: FxTurn] = [:]
    private var credentialWaiters: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var nextFetchID = 1
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
                fields["category"] = .string("type")
            }
            if case FxError.noActiveTurn = error { fields["message"] = .string("no prompt is running") }
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
            } catch { emit(.object(["failed": .string(String(describing: error)), "turnToken": .string(token)])) }
            turns.removeValue(forKey: token)
        }
    }

    private func run(_ value: JSONValue) async throws -> JSONValue {
        switch value["op"]?.string {
        case "open", "openAgent":
            let options = value["options"] ?? .null
            providerLabel = options["provider"]?.string ?? options["provider"]?["name"]?.string ?? "gateway"
            try validateRepresentation(options)
            var tools: [FxTool] = []
            if case .array(let descriptors) = options["tools"] {
                for descriptor in descriptors {
                    let name = descriptor["name"]?.string ?? ""
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
                id: modelOption.string ?? modelOption["id"]?.string ?? "",
                reasoningEffort: modelOption["effort"]?.string ?? options["effort"]?.string,
                fast: bool(modelOption["fast"] ?? options["fast"]),
                ultrafast: bool(modelOption["ultrafast"] ?? options["ultrafast"])
            )
            var config = FxConfiguration(
                apiKey: options["apiKey"]?.string ?? "", model: model,
                instructions: options["instructions"]?.string ?? "", tools: tools
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
                config.observation = FxObservationOptions(captureContent: options["hooks"]?["captureContent"] == .bool(true)) { event in
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .millisecondsSince1970
                    var value = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(event))
                    if case .object(var fields) = value {
                        fields["timestamp"] = .number((event.timestamp.timeIntervalSince1970 * 1000).rounded())
                        for key in ["parentSessionId", "sourceSessionId", "workId", "turnId", "executionId"] where fields[key] == nil {
                            fields[key] = .null
                        }
                        value = .object(fields)
                    }
                    DriverOutput.emit(.object(["observation": value]))
                } onError: { error in
                    DriverOutput.emit(.object(["observationError": .string(String(describing: error))]))
                }
            }
            config.wireObserver = { [weak self] direction, message in
                await self?.emit(.object(["diagnostic": .object([
                    "type": .string(direction == .sent ? "acp.send" : "acp.receive"), "message": message,
                ])]))
            }
            if value["op"] == .string("openAgent") {
                let sessionStore = try FxSessionStore(url: options["sessionStorePath"]?.string.map { URL(fileURLWithPath: $0) })
                self.sessionStore = sessionStore
                agent = try FxAgent(configuration: config, name: options["name"]?.string ?? "default", store: sessionStore)
                return .object([:])
            }
            let checkpoint = options["checkpoint"]?.string.flatMap { Data(base64Encoded: $0) }
            if let path = options["sqlitePath"]?.string {
                store = try FxSQLitePersistence(url: URL(fileURLWithPath: path))
            } else if options["hasCheckpointPersistence"] == .bool(true) {
                store = RelayedCheckpointStore(driver: self)
            } else if options["hasPersistence"] == .bool(true) { store = self }
            engine = try await FxEngine.open(
                configuration: config, checkpoint: checkpoint,
                persistence: store
            )
            let recovery = await engine!.recoveryState
            return .object([
                "sessionId": .string(engine!.sessionID), "resumable": .bool(await engine!.hasResumableWork),
                "openTurnId": recovery?.turnID.map(JSONValue.string) ?? .null,
                "runningCalls": .array((recovery?.runningCalls ?? []).map {
                    .object(["executionId": .string($0.executionID), "name": .string($0.name), "input": $0.input])
                }),
            ])
        case "sessionPrompt", "sessionResume":
            guard let agent, let sessionID = value["sessionID"]?.string else { throw FxError.closed }
            let options = value["options"] ?? .null
            let model = options["model"]
            let sessionOptions = FxSessionOptions(model: model.map {
                FxModel(id: $0.string ?? $0["id"]?.string ?? "", reasoningEffort: $0["effort"]?.string,
                        fast: bool($0["fast"]), ultrafast: bool($0["ultrafast"]))
            }, instructions: options["instructions"]?.string, context: options["context"])
            let session = try await agent.session(id: sessionID, options: sessionOptions)
            let content: [FxPromptContent]
            if case .array(let blocks) = value["text"] {
                content = try blocks.map { block in
                    if block["type"] == .string("image") { return .image(try image(block)) }
                    guard let text = block["text"]?.string else { throw FxError.invalidInput("Unsupported prompt content") }
                    return .text(text)
                }
            } else { content = [.text(value["text"]?.string ?? "")] }
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
                } catch { emit(.object(["failed": .string(String(describing: error)), "turnToken": .string(token)])) }
                sessionTurns.removeValue(forKey: token)
                sessionDeliveries.removeValue(forKey: token)
            }
            return .object(["messageID": .string(next.id), "sessionID": .string(next.sessionID)])
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
            return .array(models.map { .string($0.id) })
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
                catch { emit(.object(["failed": .string(String(describing: error)), "turnToken": .string(token)])) }
            }
            return .object(["inputID": .string(receipt.id)])
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
        case "credentialResult":
            guard let token = value["token"]?.string, let waiter = credentialWaiters.removeValue(forKey: token) else {
                throw FxError.invalidInput("Unknown credential request")
            }
            if let credentials = value["credentials"] { waiter.resume(returning: credentials) }
            else { waiter.resume(throwing: FxError.invalidInput("Credentials are unavailable")) }
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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                toolWaiters[id] = waiter
                emit(.object(["toolRequest": .object([
                    "id": .number(Double(id)), "name": .string(name), "input": input,
                    "executionId": .string(context.executionID), "sessionId": .string(context.sessionID),
                    "turnId": .string(context.turnID), "context": context.context ?? .null,
                ])]))
            }
        } onCancel: { Task { await self.cancelTool(id) } }
    }

    private func cancelTool(_ id: Int) {
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
            if let input { value["input"] = input }
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
