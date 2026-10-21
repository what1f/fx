# libfx Swift

A Swift 6 package for running the fx agent core in process through a C ABI. The SDK is under development. See [the migration plan](MIGRATION.md) for required scope and [validation](VALIDATION.md) for the checks performed so far.

## Build and use a local package

Requirements: macOS 14 or later, Xcode, Swift 6, and Zig 0.17.0.

From the repository root, build the macOS arm64 and x86_64 static libraries and package them as an XCFramework:

```sh
swift/scripts/build-xcframework.sh
swift test --package-path swift
swift/scripts/test-consumer.sh
```

The generated XCFramework is in `swift/Artifacts/CFx.xcframework` and is excluded from Git. Add the prepared `swift` directory as a local Swift package dependency in Xcode, or use `.package(path: "../fx/swift")` in another package. The package uses a SwiftPM binary target and has no unsafe linker flags. A published remote package and other platform artifacts remain pending.

## Run a conversation

```swift
import LibFx

let engine = try await FxEngine.open(configuration: FxConfiguration(
    apiKey: key,
    model: FxModel(id: "provider/model", reasoningEffort: "high")
))
do {
    let turn = try await engine.prompt("Explain this function")
    for try await event in turn {
        if case .text(let delta) = event { print(delta, terminator: "") }
    }
    let result = try await turn.result
    print(result.stopReason)
    try await engine.close()
} catch {
    try? await engine.close()
    throw error
}
```

Read a turn's events once. Await `result` to observe its completion. Call `cancel()` on the turn to stop model requests and cooperative tool tasks. Call `close()` on the engine to release the core; repeated close calls await the same shutdown and report the same persistence failure, if any.

## Discover models and steer a turn

```swift
let models = try await FxModel.available(apiKey: key)
let receipt = try await turn.steer("Focus on the tests")
let withdrawal = try await turn.withdraw(receipt.id)
```

Model discovery does not create an engine. Steering joins the current turn at a safe boundary and carries an ID in the user-message event. A withdrawal returns `.withdrawn` if the model has not received that input, or `.alreadyPlaced` otherwise. With persistence, these operations wait for their journal records. Controls on an old turn cannot change a newer turn.

## Provide tools and images

```swift
let lookup = FxTool(
    name: "lookup",
    description: "Look up a document",
    inputSchema: .object(["type": .string("object")]),
    isIdempotent: true
) { input, context in
    try Task.checkCancellation()
    return FxToolResult(text: "Document contents")
}

let image = FxImage(data: pngBytes, format: .png)
let turn = try await engine.prompt([.text("Describe this image"), .image(image)])
```

Pass tools through `FxConfiguration.tools`. A tool can return text, images, and an explicit error flag through `FxToolResult`. Its context carries a stable execution ID for effect deduplication and the session ID. Tool closures must cooperate with task cancellation.

Images use `Data` and a supported format. Each prompt accepts up to eight images, at most 3.75 MiB each and 6 MiB together, subject to the encoded request limit. The core checks image content and model capabilities. Image resizing and external image storage are not implemented yet.

## Observe runtime events

Set `FxConfiguration.observation` to receive semantic events in delivery order:

```swift
configuration.observation = FxObservationOptions { event in
    if event.kind == .modelEnded {
        print(event.sessionID, event.stepIndex, event.data)
    }
} onError: { error in
    print(error)
}
```

Events have typed kinds, session and execution identifiers, a `Date` timestamp, and event-specific JSON data. Content is omitted by default. Set `captureContent: true` to include bounded prompt, model, and tool content. Treat captured content as conversation data.

Callbacks run synchronously before the next event is handled. Keep them short and send asynchronous work to your own task or actor. An `onEvent` error is sent to `onError` without failing the turn or journal. Journal observations report restores, successful appends, and append failures. Parent observation scopes and tool-local MCP observations remain pending.

## Persist a conversation

Pass a store conforming to `FxPersistence` when opening the engine. Its records are opaque bytes. The store must reject a stale expected cursor and honor durability barriers. `FxSQLitePersistence` stores one conversation per local database file using the system SQLite library. Separate connections use transactions to reject stale writers. Close the store after its engines close.

```swift
let store = try FxSQLitePersistence(url: databaseURL)
```

Choose a file URL in your application's storage directory. `FxMemoryPersistence` provides an in-memory reference implementation for tests; it does not survive process exit.

```swift
let engine = try await FxEngine.open(configuration: configuration, persistence: store)
if let recovery = await engine.recoveryState {
    // Inspect recovery.runningCalls before explicitly selecting any for rerun.
    if let turn = try await engine.resume() {
        for try await event in turn { /* Display the event. */ }
        _ = try await turn.result
    }
}
```

A resumed turn does not repeat ambiguous tools by default. Use `resume(rerunning:)` only after deciding that the selected execution IDs can run again. The SDK exposes interrupted calls through `recoveryState` and reports skipped calls in the event stream.

For an idle engine, `checkpoint()` returns opaque bytes that another Swift or JavaScript engine can restore. Provide either checkpoint bytes or a persistence store at creation.

With a store conforming to `FxCheckpointPersistence`, call `saveCheckpoint()` to save a journal snapshot through the last committed cursor. The store may then prune the covered journal prefix. Closing waits for a snapshot save already in progress. Journal snapshots differ from the export returned by `checkpoint()`; let the SDK create them.

Journal and checkpoint interoperability have local tests. Automatic snapshots run after completed turns when the store supports `FxCheckpointPersistence`. `FxConfiguration.checkpointAfterBytes` defaults to 1 MiB; use `0` to attempt a snapshot after every turn, or `nil` to save only on explicit calls. A turn settles after its automatic snapshot attempt. A failed automatic save keeps the journal, emits `.checkpointError` when observation is enabled, and retries at a later turn. Successful saves emit `.checkpointSaved`.

Local process tests cover forced termination after a saved snapshot and after an ambiguous external write. Full crash-boundary coverage and durable agent and session APIs remain pending.
