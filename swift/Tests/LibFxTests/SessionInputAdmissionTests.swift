import Foundation
import Testing
@testable import LibFx

private actor AdmissionQueue: FxSessionQueue {
    var messages: [FxSessionWakeup] = []
    func enqueue(_ wakeup: FxSessionWakeup) { messages.append(wakeup) }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct SessionInputAdmissionTests {
    private let limit = 8 * 1024 * 1024

    private func jsonBytes<Value: Encodable>(_ value: Value) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value).count
    }

    @Test(arguments: [-1, 0, 1])
    func typedJSONAndContextAndSettingsShareOneInclusiveLimit(delta: Int) async throws {
        let database = try FxSessionStore(), storage = SessionStorageProxy(database), queue = AdmissionQueue()
        let agent = try FxDurableAgent(harness: CalculationHarness(), store: storage, queue: queue)
        let context = JSONValue.string(String(repeating: "c", count: 2 * 1024 * 1024))
        let settings = JSONValue.string(String(repeating: "s", count: 2 * 1024 * 1024))
        let options = FxSessionOptions(context: context, settings: settings)
        let empty = CalculationInput(values: [1], labels: ["padding": ""])
        let payloadBytes = limit + delta - (try jsonBytes(context)) - (try jsonBytes(settings))
        let input = CalculationInput(values: [1], labels: ["padding": String(repeating: "a", count: payloadBytes - (try jsonBytes(empty)))])
        let session = try await agent.session(id: "boundary", options: options)
        if delta <= 0 {
            let turn = try await session.submit(input, id: "one")
            #expect(!turn.isRepeated)
            #expect(await storage.calls == ["accept"])
            #expect(await queue.messages == [FxSessionWakeup(agent: "default", sessionID: session.id, inputID: "one")])
            let lease = try #require(try await database.claim(session: session.id, agent: "default"))
            let stored = try #require(try await database.input(lease, id: "one"))
            #expect(stored.options == options)
            guard case .payload(let data) = stored.content.first else { Issue.record("Missing data input"); return }
            #expect(data.count == payloadBytes)
            try await database.release(lease)
        } else {
            await #expect(throws: FxError.self) { try await session.submit(input, id: "one") }
            #expect(await storage.calls.isEmpty)
            #expect(await queue.messages.isEmpty)
            #expect(try await database.owner(session: session.id) == nil)
        }
        try await agent.close(); try await database.close()
    }

    @Test func settingsAboveOneMiBAreUsableByARealTypedExecutor() async throws {
        let store = try FxSessionStore(), agent = try FxDurableAgent(harness: CalculationHarness(), store: store)
        let options = FxSessionOptions(settings: .object(["description": .string(String(repeating: "中", count: 400_000))]))
        let session = try await agent.session(id: "large-settings", options: options)
        let turn = try await session.submit(CalculationInput(values: [2, 3]), id: "one")
        var totals: [Int] = []
        for try await update in turn { totals.append(update.total) }
        #expect(totals == [2, 5])
        #expect(try await turn.result.stopReason == .endTurn)
        try await agent.close(); try await store.close()
    }

    @Test func directStoreAndOfflineSteeringRejectCombinedOversizeWithoutSavingInput() async throws {
        let store = try FxSessionStore(), router = FxAgentRouter(store: store), queue = AdmissionQueue()
        let owner = try await router.makeAgent(harness: CalculationHarness(), name: "owner", queue: queue)
        _ = try await owner.session(id: "offline").submit(CalculationInput(values: [1]), id: "seed")
        try await owner.close()
        let sender = try await router.makeAgent(harness: CalculationHarness(), name: "sender")
        let options = FxSessionOptions(context: .string(String(repeating: "x", count: limit - 1)))
        let view = try await sender.session(id: "offline", options: options)
        await #expect(throws: FxError.self) { try await view.steer(CalculationInput(values: [2]), id: "rejected") }
        let lease = try #require(try await store.claim(session: view.id, agent: "owner"))
        #expect(try await store.input(lease, id: "rejected") == nil)
        try await store.release(lease)
        await #expect(throws: FxError.self) {
            try await store.accept(session: "direct", agent: "owner", id: "one", content: [.payload(Data("0".utf8))], options: options)
        }
        #expect(try await store.owner(session: "direct") == nil)
        try await sender.close(); try await store.close()
    }

    @Test func jsonEscapesAndUnicodeUseEncodedBytesWithoutStorageEnvelopeOverhead() throws {
        let context = JSONValue.string("中/\"\\\n")
        let settings = JSONValue.object(["flag": .bool(true)])
        let carried = try jsonBytes(context) + jsonBytes(settings)
        let payload = Data(repeating: 0x20, count: limit - carried)
        try SessionInputAdmission.validate([.payload(payload)], options: .init(context: context, settings: settings))
        #expect(throws: FxError.self) {
            try SessionInputAdmission.validate([.payload(payload + Data([0x20]))], options: .init(context: context, settings: settings))
        }
        // Explicit JSON null takes four bytes; an absent value takes none.
        try SessionInputAdmission.validate([.payload(Data(repeating: 0x20, count: limit))], options: .init())
        #expect(throws: FxError.self) {
            try SessionInputAdmission.validate([.payload(Data(repeating: 0x20, count: limit))], options: .init(context: .null))
        }
    }

    @Test func modelAndInstructionOverridesCountWithoutRelaxingNativeInstructionLimits() async throws {
        let options = FxSessionOptions(model: FxModel(id: "fixture/model"), instructions: "rules")
        struct Overrides: Encodable { let model: FxModel?; let instructions: String? }
        let carried = try jsonBytes(Overrides(model: options.model, instructions: options.instructions))
        try SessionInputAdmission.validate([.payload(Data(repeating: 0x20, count: limit - carried))], options: options)
        #expect(throws: FxError.self) {
            try SessionInputAdmission.validate([.payload(Data(repeating: 0x20, count: limit - carried + 1))], options: options)
        }
        let store = try FxSessionStore(), agent = try FxAgent(configuration: FxConfiguration(apiKey: "fixture", model: "fixture/model"), store: store)
        await #expect(throws: FxError.self) {
            try await agent.session(id: "native", options: .init(instructions: String(repeating: "x", count: 65_537)))
        }
        #expect(try await store.owner(session: "native") == nil)
        try await agent.close(); try await store.close()
    }
}
