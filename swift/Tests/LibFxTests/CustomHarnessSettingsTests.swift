import Foundation
import Testing
import LibFx

private actor SettingsQueue: FxSessionQueue {
    func enqueue(_ wakeup: FxSessionWakeup) {}
}

private actor SettingsObservations {
    struct Open: Sendable, Equatable {
        let inputID: String?
        let options: FxSessionOptions
    }
    var opens: [Open] = []
    func record(_ context: FxHarnessContext) {
        opens.append(Open(inputID: context.inputID, options: context.options))
    }
}

private enum SettingsError: Error, Equatable { case refused }

private struct SettingsHarness: FxDurableHarness {
    typealias Input = CalculationInput
    typealias Update = CalculationUpdate
    let observations: SettingsObservations
    func validate(options: FxSessionOptions) throws {
        if options.settings?["reject"] == .bool(true) { throw SettingsError.refused }
    }
    func validate(_ input: Input, options: FxSessionOptions) throws {
        if options.settings?["rejectInput"] == .bool(true) { throw SettingsError.refused }
        try CalculationHarness().validate(input, options: options)
    }
    func prepareCheckpoint(_ data: Data, options: FxSessionOptions) async throws -> Data {
        try CalculationHarness().prepareCheckpoint(data, options: options)
    }
    func open(_ context: FxHarnessContext) async throws -> any FxDurableHarnessSession<Input, Update> {
        await observations.record(context)
        return try await CalculationHarness().open(context)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct CustomHarnessSettingsTests {
    @Test func rejectedSettingsDoNotCreateAStoredSession() async throws {
        let store = try FxSessionStore()
        let observations = SettingsObservations()
        let agent = try FxDurableAgent(harness: SettingsHarness(observations: observations), store: store)
        let rejected = FxSessionOptions(settings: .object(["reject": .bool(true)]))
        await #expect(throws: SettingsError.refused) { try await agent.session(id: "settings-invalid-view", options: rejected) }
        await #expect(throws: FxSessionError.notFound) { try await store.snapshot(session: "settings-invalid-view", agent: "default") }
        var session = try await agent.session(id: "settings-invalid-input")
        session.options = rejected
        await #expect(throws: SettingsError.refused) { try await session.submit(CalculationInput(values: [1]), id: "one") }
        await #expect(throws: FxSessionError.notFound) { try await store.snapshot(session: session.id, agent: "default") }
        let inputRejected = try await agent.session(id: "settings-invalid-validation", options: .init(settings: .object(["rejectInput": .bool(true)])))
        await #expect(throws: SettingsError.refused) { try await inputRejected.submit(CalculationInput(values: [1]), id: "one") }
        await #expect(throws: FxSessionError.notFound) { try await store.snapshot(session: inputRejected.id, agent: "default") }
        #expect(await observations.opens.isEmpty)
        try await agent.close(); try await store.close()
    }

    @Test func eachInputRetainsSettingsAndContextAcrossSQLiteRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.sqlite")
        let store = try FxSessionStore(url: url), observations = SettingsObservations()
        let harness = SettingsHarness(observations: observations)
        let first = try FxDurableAgent(harness: harness, store: store, queue: SettingsQueue())
        let one = FxSessionOptions(context: .object(["request": .string("first")]), settings: .object(["scale": .number(2)]))
        let two = FxSessionOptions(context: .array([.string("second")]), settings: .object(["scale": .number(7)]))
        let session = try await first.session(id: "saved-settings", options: one)
        _ = try await session.submit(CalculationInput(values: [2, 3, 4]), id: "one")
        let next = try await first.session(id: session.id, options: two)
        _ = try await next.submit(CalculationInput(values: [5]), id: "two")
        let wakeup = FxSessionWakeup(agent: "default", sessionID: session.id)
        let policy = try FxDeliveryPolicy(maximumDuration: .zero, reserve: .zero)
        #expect(try await first.deliver(wakeup, policy: policy) == .retry(after: .zero))
        try await first.close(); try await store.close()

        let reopened = try FxSessionStore(url: url)
        let second = try FxDurableAgent(harness: harness, store: reopened, queue: SettingsQueue())
        let replacement = FxSessionOptions(context: .null, settings: .string("new view"))
        _ = try await second.session(id: session.id, options: replacement)
        _ = try await second.deliver(wakeup)
        #expect(try await reopened.result(session: session.id, agent: "default", id: "one")?.stopReason == .endTurn)
        #expect(try await reopened.result(session: session.id, agent: "default", id: "two")?.stopReason == .endTurn)
        let opens = await observations.opens
        #expect(opens == [
            .init(inputID: "one", options: one),
            .init(inputID: "one", options: one),
            .init(inputID: "two", options: two),
        ])
        try await second.close(); try await reopened.close()
    }

    @Test func callerValuesAreCopiedAndOptionsCodableKeepsSettingsSeparate() async throws {
        var fields: [String: JSONValue] = ["labels": .array([.string("original")])]
        let original = FxSessionOptions(context: .string("context"), settings: .object(fields))
        let store = try FxSessionStore(), observations = SettingsObservations()
        let agent = try FxDurableAgent(harness: SettingsHarness(observations: observations), store: store)
        let session = try await agent.session(id: "settings-copy", options: original)
        fields["labels"] = .array([.string("changed")])
        var changed = original
        changed.settings = .object(fields)
        changed.context = .string("changed context")
        #expect(session.options == original)
        #expect(changed.settings != original.settings && changed.context != original.context)
        #expect(try await session.submit(CalculationInput(values: [1]), id: "one").result.stopReason == .endTurn)
        #expect(await observations.opens == [.init(inputID: "one", options: original)])
        let restored = try JSONDecoder().decode(FxSessionOptions.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(try JSONDecoder().decode(FxSessionOptions.self, from: Data("{}".utf8)).settings == nil)
        #expect(FxSessionOptions().settings == nil)
        try await agent.close(); try await store.close()
    }
}
