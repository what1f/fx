import Foundation
import Testing
@testable import LibFx

private let imagePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=")!
private final class ImageStoreFailure: Error {}

private actor ImagePreparationGate {
    private(set) var started = false
    private(set) var finished = false
    func prepare(_ image: FxImage) async throws -> FxImage {
        started = true
        defer { finished = true }
        try await Task.sleep(for: .seconds(60))
        return image
    }
    func waitForEntry() async { while !started { await Task.yield() } }
}

private actor StoredPictures: FxImagePersistence, FxCheckpointPersistence {
    let journal = FxMemoryPersistence()
    let failure: ImageStoreFailure?
    let waitsForWrites: Bool
    private(set) var images: [String: Data] = [:]
    private(set) var puts = 0
    private(set) var reads: [String] = []
    private(set) var writeStarted = false
    private(set) var writeFinished = false
    private(set) var readStarted = false
    private(set) var readFinished = false
    private var waitsForReads = false
    init(failure: ImageStoreFailure? = nil, waitsForWrites: Bool = false) {
        self.failure = failure; self.waitsForWrites = waitsForWrites
    }
    func load() async -> FxPersistenceSnapshot { await journal.load() }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String {
        try await journal.append(expected: expected, idempotencyKey: idempotencyKey, data: data, barrier: barrier)
    }
    func saveCheckpoint(_ checkpoint: FxStoredCheckpoint) async throws { try await journal.saveCheckpoint(checkpoint) }
    func storeImage(_ data: Data, named name: String) async throws {
        puts += 1; writeStarted = true
        defer { writeFinished = true }
        if waitsForWrites { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw failure }
        images[name] = data
    }
    func loadImage(named name: String) async throws -> Data? {
        reads.append(name); readStarted = true
        defer { readFinished = true }
        if waitsForReads { try await Task.sleep(for: .seconds(60)) }
        return images[name]
    }
    func remove(_ name: String) { images.removeValue(forKey: name) }
    func blockReads() { waitsForReads = true }
    func waitForWrite() async { while !writeStarted { await Task.yield() } }
    func waitForRead() async { while !readStarted { await Task.yield() } }
}

private actor ImageStoreHTTP: FxHTTPClient {
    let callsTool: Bool
    private(set) var bodies: [JSONValue] = []
    init(callsTool: Bool = false) { self.callsTool = callsTool }
    func send(_ request: URLRequest) async throws -> FxHTTPResponse {
        guard request.httpMethod == "POST" else { throw FxError.protocolViolation("Unexpected catalog fetch") }
        bodies.append(try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data()))
        let events: [JSONValue]
        if callsTool && bodies.count == 1 {
            events = [
                .object(["type": .string("tool-call"), "toolCallId": .string("picture-1"), "toolName": .string("picture"), "input": .object([:])]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("tool-calls"), "raw": .string("tool-calls")])]),
            ]
        } else {
            events = [
                .object(["type": .string("text-delta"), "delta": .string("answer")]),
                .object(["type": .string("finish"), "finishReason": .object(["unified": .string("stop"), "raw": .string("stop")])]),
            ]
        }
        let bytes = try events.reduce(into: Data()) { output, event in
            output.append(Data("data: ".utf8)); output.append(try JSONEncoder().encode(event)); output.append(Data("\n\n".utf8))
        } + Data("data: [DONE]\n\n".utf8)
        return FxHTTPResponse(statusCode: 200, body: AsyncThrowingStream { $0.yield(bytes); $0.finish() })
    }
}

private func imageConfiguration(_ http: ImageStoreHTTP, tools: [FxTool] = []) throws -> FxConfiguration {
    var config = FxConfiguration(apiKey: "fixture", model: "swift/images", tools: tools, httpClient: http, checkpointAfterBytes: 0)
    config.modelCatalog = try FxModelCatalog(response: Data(#"{"data":[{"id":"swift/images","type":"language","tags":["tool-use","vision","file-input"]}]}"#.utf8))
    return config
}

private func requestPictures(_ body: JSONValue) -> [String] {
    guard case .array(let messages) = body["prompt"] else { return [] }
    return messages.flatMap { message -> [String] in
        guard case .array(let parts) = message["content"] else { return [] }
        return parts.filter { $0["type"] == .string("file") }.compactMap { $0["data"]?["data"]?.string }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct ImagePersistenceTests {
    @Test func preparationAdmitsLargeInputAndStoresOnlyThePreparedBytes() async throws {
        let store = StoredPictures(), http = ImageStoreHTTP()
        var config = try imageConfiguration(http)
        let original = imagePNG + Data(repeating: 1, count: 5 * 1024 * 1024)
        config.prepareImage = { image in
            #expect(image.data == original)
            #expect(image.format == .jpeg)
            #expect(image.sourceReference == "host:original")
            return FxImage(data: imagePNG, format: .png, sourceReference: "host:replacement")
        }
        let engine = try await FxEngine.open(configuration: config, persistence: store)
        let turn = try await engine.prompt([.image(FxImage(data: original, format: .jpeg, sourceReference: "host:original"))])
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(requestPictures(try #require(await http.bodies.last)) == [imagePNG.base64EncodedString()])
        #expect(await store.images == [PersistedImages.name(for: imagePNG): imagePNG])
        try await engine.close()
        config.prepareImage = { _ in Issue.record("Restoration must not prepare saved bytes again"); throw FxError.closed }
        let reopened = try await FxEngine.open(configuration: config, persistence: store)
        let next = try await reopened.prompt("recall")
        #expect(try await next.result.stopReason == .endTurn)
        #expect(requestPictures(try #require(await http.bodies.last)) == [imagePNG.base64EncodedString()])
        try await reopened.close()
    }

    @Test func preparationFailurePreservesItsIdentityAndLeavesTheEngineUsable() async throws {
        let failure = ImageStoreFailure(), store = StoredPictures(), http = ImageStoreHTTP()
        var config = try imageConfiguration(http)
        config.prepareImage = { _ in throw failure }
        let engine = try await FxEngine.open(configuration: config, persistence: store)
        let turn = try await engine.prompt([.image(FxImage(data: imagePNG, format: .png))])
        do { _ = try await turn.result; Issue.record("Preparation should fail") }
        catch { #expect(error as? ImageStoreFailure === failure) }
        #expect(await http.bodies.isEmpty)
        #expect(await store.images.isEmpty)
        #expect(await store.load().journal.isEmpty)
        let next = try await engine.prompt("still usable")
        #expect(try await next.result.stopReason == .endTurn)
        try await engine.close()
    }

    @Test func durableIntakeDefersImageLimitsUntilTheWorkerPreparesItsBytes() async throws {
        let store = try FxSessionStore(), http = ImageStoreHTTP()
        let original = imagePNG + Data(repeating: 3, count: 5 * 1024 * 1024)
        var config = try imageConfiguration(http)
        config.prepareImage = { image in
            #expect(image.data == original)
            return FxImage(data: imagePNG, format: .png)
        }
        let agent = try FxAgent(configuration: config, store: store)
        let session = try await agent.session(id: "prepared")
        let turn = try await session.prompt([.image(FxImage(data: original, format: .png))], id: "picture")
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(requestPictures(try #require(await http.bodies.last)) == [imagePNG.base64EncodedString()])
        #expect(try await store.loadImage(named: PersistedImages.name(for: imagePNG), session: "prepared", agent: "default") == imagePNG)
        try await agent.close()
        config.prepareImage = { _ in Issue.record("Saved bytes must not be prepared again"); throw FxError.closed }
        let reopened = try FxAgent(configuration: config, store: store)
        let next = try await reopened.session(id: "prepared").prompt("recall", id: "text")
        #expect(try await next.result.stopReason == .endTurn)
        #expect(requestPictures(try #require(await http.bodies.last)) == [imagePNG.base64EncodedString()])
        try await reopened.close()
        try await store.close()
    }

    @Test(arguments: [false, true]) func preparationCancellationAndCloseJoinTheCallback(close: Bool) async throws {
        let gate = ImagePreparationGate(), http = ImageStoreHTTP()
        var config = try imageConfiguration(http)
        config.prepareImage = { try await gate.prepare($0) }
        let engine = try await FxEngine.open(configuration: config)
        let turn = try await engine.prompt([.image(FxImage(data: imagePNG, format: .png))])
        await gate.waitForEntry()
        if close { try await engine.close() } else { await turn.cancel() }
        if close {
            do { _ = try await turn.result; Issue.record("Closed preparation should fail") } catch {}
        } else {
            #expect(try await turn.result.stopReason == .cancelled)
            try await engine.close()
        }
        #expect(await gate.finished)
        #expect(await http.bodies.isEmpty)
    }

    @Test(arguments: [0, 1, 2]) func preparedOutputMustHaveBytesAndFitTheFinalLimits(kind: Int) async throws {
        let http = ImageStoreHTTP()
        var config = try imageConfiguration(http)
        config.prepareImage = { _ in
            if kind == 0 { return FxImage(reference: "host:output", format: .png) }
            return FxImage(data: imagePNG + Data(repeating: 0, count: kind == 1 ? 4 * 1024 * 1024 : 3 * 1024 * 1024 - imagePNG.count), format: .png)
        }
        let engine = try await FxEngine.open(configuration: config)
        let pictures = Array(repeating: FxPromptContent.image(FxImage(data: imagePNG, format: .png)), count: kind == 2 ? 2 : 1)
        let turn = try await engine.prompt(pictures)
        do { _ = try await turn.result; Issue.record("Invalid prepared output should fail") }
        catch { guard case FxError.invalidInput = error else { Issue.record("Unexpected preparation error: \(error)"); return } }
        #expect(await http.bodies.isEmpty)
        let next = try await engine.prompt("still usable")
        #expect(try await next.result.stopReason == .endTurn)
        try await engine.close()
    }

    @Test func sqlitePicturesSurviveReopeningWithSmallCheckpoints() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversation.sqlite")
        let store = try FxSQLitePersistence(url: url), http = ImageStoreHTTP()
        let bytes = imagePNG + Data(repeating: 7, count: 100_000)
        let name = PersistedImages.name(for: bytes)
        let engine = try await FxEngine.open(configuration: imageConfiguration(http), persistence: store)
        let turn = try await engine.prompt([.image(FxImage(data: bytes, format: .png))])
        #expect(try await turn.result.stopReason == .endTurn)
        try await engine.close()
        #expect(try await store.load().checkpoint?.data.count ?? Int.max < 64 * 1024)
        try await store.storeImage(bytes, named: name)
        await #expect(throws: FxError.invalidInput("Image name does not match its bytes")) {
            try await store.storeImage(Data([0]), named: name)
        }
        try await store.close()
        let reopened = try FxSQLitePersistence(url: url)
        #expect(try await reopened.loadImage(named: name) == bytes)
        let restored = try await FxEngine.open(configuration: imageConfiguration(http), persistence: reopened)
        let next = try await restored.prompt("recall")
        #expect(try await next.result.stopReason == .endTurn)
        #expect(requestPictures(try #require(await http.bodies.last)) == [bytes.base64EncodedString()])
        try await restored.close()
        try await reopened.close()
    }

    @Test func sessionPicturesAreScopedAndFenceStaleOwners() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("agent.sqlite")
        let store = try FxSessionStore(url: url)
        for session in ["first", "second"] {
            _ = try await store.accept(session: session, agent: "agent", id: "input", content: [.text("look")], options: .init())
        }
        let old = try #require(try await store.claim(session: "first", agent: "agent"))
        let name = PersistedImages.name(for: imagePNG)
        let persistence = SessionPersistence(store: store, lease: old)
        try await persistence.storeImage(imagePNG, named: name)
        try await persistence.storeImage(imagePNG, named: name)
        #expect(try await store.loadImage(named: name, session: "second", agent: "agent") == nil)
        await #expect(throws: FxSessionError.wrongAgent) {
            try await store.loadImage(named: name, session: "first", agent: "other")
        }
        try await store.release(old)
        let current = try #require(try await store.claim(session: "first", agent: "agent"))
        await #expect(throws: FxPersistenceError.fenced) { try await persistence.storeImage(imagePNG, named: name) }
        await #expect(throws: FxPersistenceError.fenced) { try await persistence.loadImage(named: name) }
        try await store.release(current)
        try await store.close()
        let reopened = try FxSessionStore(url: url)
        #expect(try await reopened.loadImage(named: name, session: "first", agent: "agent") == imagePNG)
        try await reopened.close()
    }

    @Test func namedPicturesDeduplicateTrimAndRestoreWithoutDroppedBytes() async throws {
        let store = StoredPictures(), http = ImageStoreHTTP()
        var config = try imageConfiguration(http)
        config.imageWindow = try FxImageWindow(maximumImages: 2)
        let engine = try await FxEngine.open(configuration: config, persistence: store)
        let a = imagePNG + Data([1]), b = imagePNG + Data([2]), c = imagePNG + Data([3])
        for pictures in [[a, a], [b], [c]] {
            let turn = try await engine.prompt([.text("look")] + pictures.map { .image(FxImage(data: $0, format: .png)) })
            #expect(try await turn.result.stopReason == .endTurn)
        }
        let next = try await engine.prompt("after trimming")
        #expect(try await next.result.stopReason == .endTurn)
        #expect(requestPictures(try #require(await http.bodies.last)) == [b, c].map { $0.base64EncodedString() })
        try await engine.close()
        #expect(await store.puts == 3)
        #expect(await store.images.count == 3)
        #expect(await store.load().checkpoint != nil)
        let dropped = try #require(await store.images.first { $0.value == a }?.key)
        await store.remove(dropped)
        let restored = try await FxEngine.open(configuration: config, persistence: store)
        let turn = try await restored.prompt("restored")
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(requestPictures(try #require(await http.bodies.last)) == [b, c].map { $0.base64EncodedString() })
        #expect(await store.reads.count == 2)
        #expect(!(await store.reads).contains(dropped))
        try await restored.close()
    }

    @Test func failedPictureWritePreservesItsErrorAndNeverSendsThePrompt() async throws {
        let failure = ImageStoreFailure(), store = StoredPictures(failure: failure), http = ImageStoreHTTP()
        let engine = try await FxEngine.open(configuration: imageConfiguration(http), persistence: store)
        let turn = try await engine.prompt([.image(FxImage(data: imagePNG, format: .png))])
        do { for try await _ in turn {}; Issue.record("Expected image write failure") }
        catch { #expect(error as? ImageStoreFailure === failure) }
        do { _ = try await turn.result; Issue.record("Expected image write failure") }
        catch { #expect(error as? ImageStoreFailure === failure) }
        #expect(await http.bodies.isEmpty)
        #expect(await store.load().journal.isEmpty)
        let fresh = try await engine.prompt("without a picture")
        #expect(try await fresh.result.stopReason == .endTurn)
        try await engine.close()
    }

    @Test(arguments: [false, true]) func cancellationAndCloseJoinPicturePreparation(close: Bool) async throws {
        let store = StoredPictures(waitsForWrites: true), http = ImageStoreHTTP()
        let engine = try await FxEngine.open(configuration: imageConfiguration(http), persistence: store)
        let turn = try await engine.prompt([.image(FxImage(data: imagePNG, format: .png))])
        await store.waitForWrite()
        if close {
            try await engine.close()
            do { _ = try await turn.result; Issue.record("Expected a closed turn") } catch {}
        } else {
            await turn.cancel()
            #expect(try await turn.result.stopReason == .cancelled)
            try await engine.close()
        }
        #expect(await store.writeFinished)
        #expect(await store.images.isEmpty)
        #expect(await http.bodies.isEmpty)
    }

    @Test func missingPictureNamesTheLostImageAndCancelledReadsExit() async throws {
        let store = StoredPictures(), http = ImageStoreHTTP()
        let config = try imageConfiguration(http)
        let engine = try await FxEngine.open(configuration: config, persistence: store)
        let turn = try await engine.prompt([.image(FxImage(data: imagePNG, format: .png))])
        _ = try await turn.result
        try await engine.close()
        await store.blockReads()
        let opening = Task { try await FxEngine.open(configuration: config, persistence: store) }
        await store.waitForRead()
        opening.cancel()
        do { let unexpected = try await opening.value; try await unexpected.close(); Issue.record("Expected cancelled image read") }
        catch { #expect(error is CancellationError) }
        #expect(await store.readFinished)
        let name = try #require(await store.images.keys.first)
        await store.remove(name)
        // A separate store presents the same snapshot without blocking reads.
        let lost = MissingPictureStore(snapshot: await store.load())
        do {
            let unexpected = try await FxEngine.open(configuration: config, persistence: lost)
            try await unexpected.close(); Issue.record("Expected missing image")
        } catch { #expect(error as? FxPersistenceError == .missingImage(name)) }
        #expect(await http.bodies.count == 1)
    }

    @Test(arguments: [false, true]) func toolPicturesKeepTheirBytesWhenStorageFails(fails: Bool) async throws {
        let store = StoredPictures(failure: fails ? ImageStoreFailure() : nil), http = ImageStoreHTTP(callsTool: true)
        let tool = FxTool(name: "picture", description: "Picture", inputSchema: .object(["type": .string("object")]), isIdempotent: true) { _, _ in
            FxToolResult(text: "photo", images: [FxImage(data: imagePNG, format: .png)])
        }
        let config = try imageConfiguration(http, tools: [tool])
        let engine = try await FxEngine.open(configuration: config, persistence: store)
        let turn = try await engine.prompt("use the tool")
        #expect(try await turn.result.stopReason == .endTurn)
        #expect(requestPictures(try #require(await http.bodies.last)) == [imagePNG.base64EncodedString()])
        try await engine.close()
        #expect(await store.images.count == (fails ? 0 : 1))
        let restored = try await FxEngine.open(configuration: config, persistence: store)
        let next = try await restored.prompt("remember")
        #expect(try await next.result.stopReason == .endTurn)
        #expect(requestPictures(try #require(await http.bodies.last)) == [imagePNG.base64EncodedString()])
        try await restored.close()
    }

    @Test func imageWindowRequiresValidLimitsAndImageStorage() async throws {
        for limit in [0, -1, Int.max] {
            #expect(throws: FxError.self) { try FxImageWindow(maximumImages: limit) }
            #expect(throws: FxError.self) { try FxImageWindow(maximumBytes: limit) }
        }
        var config = try imageConfiguration(ImageStoreHTTP())
        config.imageWindow = try FxImageWindow(maximumImages: 1)
        await #expect(throws: FxError.self) { try await FxEngine.open(configuration: config, persistence: FxMemoryPersistence()) }
    }
}

private struct MissingPictureStore: FxImagePersistence {
    let snapshot: FxPersistenceSnapshot
    func load() async -> FxPersistenceSnapshot { snapshot }
    func append(expected: String?, idempotencyKey: String, data: Data, barrier: Bool) async throws -> String { throw FxPersistenceError.fenced }
    func storeImage(_ data: Data, named name: String) async throws { throw FxPersistenceError.fenced }
    func loadImage(named name: String) async -> Data? { nil }
}
