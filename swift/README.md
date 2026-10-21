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

## Persist a conversation

Pass a store conforming to `FxPersistence` when opening the engine. Its records are opaque bytes. The store must reject a stale expected cursor and honor durability barriers. `FxMemoryPersistence` provides an in-memory reference implementation; it does not survive process exit.

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

For an idle engine, `checkpoint()` returns opaque bytes that another Swift or JavaScript engine can restore. Provide either checkpoint bytes or a persistence store at creation. Journal and checkpoint interoperability have local tests. Automatic checkpoint storage, durable agents and sessions, and process-crash qualification remain pending.
