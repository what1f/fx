# libfx Swift

A Swift 6 package for running the fx agent core in process through a C ABI. It provides conversation engines, durable sessions, tools, streaming, persistence, observation, and optional MCP and HTTP adapters. See [local acceptance](ACCEPTANCE.md) for the qualification scope and [validation](VALIDATION.md) for command results.

For an agent with built-in workspace tools, host approval, and a persistent conversation, use [FxAgentKit](FxAgentKit/README.md). It builds on the LibFx configuration, event, and result types described here. See [workspace tools](WORKSPACE-TOOLS.md), [tool approval](TOOL-APPROVAL.md), and [automatic compaction](COMPACTION.md) for their contracts and local verification commands.

## Build and use a local package

Requirements: macOS 14 or later, Xcode, Swift 6.2 or later, and Zig 0.17.0.

From the repository root, build the macOS arm64 and x86_64 static libraries and package them as an XCFramework:

```sh
swift/scripts/build-xcframework.sh
swift test --package-path swift --no-parallel
swift/scripts/test-consumer.sh
swift/scripts/test-consumer-x86_64.sh # Requires Rosetta on Apple silicon
```

Run separate test cases serially because they share a native runtime with 64 slots. Concurrency tests still create parallel operations within each case.

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

Cancellation returns after submitting the stop request. Await the turn's `result` before starting another turn. If the stop request fails, the result preserves that error and the engine refuses further prompts.

Unread output pauses its producer when 256 events or 1 MiB of encoded events fill the queue. An empty queue can hold one indivisible event up to the 64 MiB frame bound. Consume events or cancel the turn to release pressure; awaiting only `result` does not drain the queue. The `.outputBackpressure` lifecycle event reports occupancy, and its callback can await cancellation. Cancellation and engine close release blocked output without requiring a reader to resume.

Cancelling a Swift task that awaits `turn.result` cancels the turn and makes that waiter throw `CancellationError`.

Instructions accept up to 65,536 UTF-8 bytes. The engine checks this before loading persistence or starting a runtime. Agent configuration and session instruction overrides use the same bound; Skills and MCP include their section framing in this budget.

Omit `model` in a Gateway configuration to use the core's default model. To set options on that choice, pass `FxModel(ultrafast: false)` or another option combination with a nil `id`. Checkpoints and snapshots record the model selected by the core. An empty ID is invalid. Custom providers and subscriptions require an explicit model.

Reasoning effort names must fit in 64 UTF-8 bytes. An oversized name throws `FxError.invalidInput` before loading saved history or creating the runtime. The core validates effort names and model support.

## Connect MCP tools

Add the `LibFxMCP` product when you need MCP. It uses the [official Swift MCP SDK](https://github.com/modelcontextprotocol/swift-sdk) for connection and protocol handling. Configure a fresh official transport with your server URL and authentication:

```swift
import LibFx
import LibFxMCP
import MCP

// key and serverURL come from your app's configuration.
let transport = HTTPClientTransport(endpoint: serverURL)
let mcp = try await FxMCPAdapter.connect(transport: transport, prefix: "mcp_")
let configuration = FxConfiguration(apiKey: key, instructions: mcp.instructions, tools: mcp.tools)
// Close your engine before disconnecting its MCP tools.
await mcp.close()
```

The adapter connects and owns one client. You may pass a fresh `MCP.Client` through `client:` to use your app's identity, capabilities, and handlers; do not connect it first. Pass resource URIs with `resources:` and named prompts with `prompts: [.init(name: "review", arguments: ["topic": "changes"])]` to include text context. Binary context receives an omission marker. Set `propagateCorrelation: true` to send a fresh `libfx/correlationId` with each tool request; this does not request progress notifications.

The catalog accepts up to 64 tools across at most 64 pages. Names are mapped to unique ASCII names of at most 64 characters, while calls use the original server names. Text instructions, including framing, are limited to 64 KiB. Remote idempotency hints do not enable automatic replay. Tool results retain text, structured JSON, supported images, and the server's error flag. Audio is not included in tool results. Cancelling a tool task sends an advisory MCP cancellation; the server may already have performed the effect. Closing disconnects the client, stops pending requests, and prevents later calls. Repeated close calls await the same shutdown.

When engine observation is enabled, MCP calls emit `mcp.start`, optional `mcp.request`, and `mcp.end` events within the owning tool scope. Events retain the original remote tool name and the initialized server name; pass `serverName:` to override the server label. Correlation metadata is separate from the MCP request ID. Cancellation ends the observation once and does not prove that a remote effect was undone.

## Compose skills

Use `FxSkill` for host-supplied instructions, inline resources, and tools. `FxSkills` validates and combines records in order:

```swift
let skills = try FxSkills([
    FxSkill(name: "review", description: "Review changes", instructions: "Check correctness first.",
            resources: [.init(uri: "memory://review", text: "Prefer focused changes.")])
])
let configuration = FxConfiguration(apiKey: key, instructions: skills.instructions, tools: skills.tools)
```

The collection accepts at most 64 unique names and 64 KiB of rendered UTF-8 instructions, including resource text and framing. It throws `FxSkillError` for a duplicate name or exceeded limit. Tool closures and their order are preserved; the engine validates tool names when it opens. Resources stay inline and their URIs are not fetched.

Load a local `SKILL.md` with `try await FxSkill.load(from: fileURL, resources: resources, tools: tools)`, then pass the result to `FxSkills`. File loading uses Foundation and [Yams](https://github.com/jpsim/Yams) to decode YAML frontmatter. It reads `name` and `description` and ignores other metadata. Quoted and multiline YAML values are supported. Without a name, it uses the filename without its extension. Plain Markdown without frontmatter retains its text. Invalid UTF-8, unterminated frontmatter, or invalid metadata throws `FxSkillFileError`; filesystem errors propagate. Loading checks task cancellation around the file read and parsing. It does not fetch referenced files or execute scripts.

## Observe HTTP requests

Set `onTransportEvent` in `FxConfiguration` to receive typed request metadata:

```swift
let configuration = FxConfiguration(apiKey: key, onTransportEvent: { event in
    if case .response(let request, let response) = event {
        print(request.id, response.statusCode, response.elapsed)
    }
})
```

Events include `.started`, `.response`, `.activity`, `.failed`, and `.retrying`. Each request has a UUID and a number that starts at one for each turn. Retries count as separate requests. Responses include selected request, generation, model, and provider identifiers when available. A response event means headers arrived; it does not mean the body completed. Activity events report nonempty chunk bytes and cumulative bytes for that request, at most once every 250 milliseconds. They are progress samples, so the last sample need not include every byte. Credential refresh requests made inside a subscription are not separate transport events.

The SDK removes URL credentials, query parameters, and fragments. It excludes bodies, credential headers, and raw error descriptions. Selected response values mask the credentials used for that request and are bounded to 512 UTF-8 bytes. Host-defined endpoint paths and model names remain visible. The transport awaits your callback before advancing; keep it short and cooperate with cancellation. Awaiting turn cancellation from `.retrying` prevents the next request. No events are delivered after the engine closes.

## Discover models and steer a turn

```swift
let models = try await FxModel.available(apiKey: key)
let receipt = try await turn.steer("Focus on the tests")
let withdrawal = try await turn.withdraw(receipt.id)
```

Model discovery does not create an engine. Steering joins the current turn at a safe boundary and carries an ID in the user-message event. A withdrawal returns `.withdrawn` if the model has not received that input, or `.alreadyPlaced` otherwise. With persistence, these operations wait for their journal records. Controls on an old turn cannot change a newer turn.

To use a saved Gateway model-list response, set a catalog before opening the engine:

```swift
var configuration = FxConfiguration(apiKey: key, model: "provider/model")
configuration.modelCatalog = try FxModelCatalog(response: savedCatalogData)
let engine = try await FxEngine.open(configuration: configuration)
```

The response must be a JSON object with a `data` array of entries with nonempty string IDs. The catalog preserves provider metadata, including vision and reasoning capabilities, and accepts at most 10,000 entries and 4 MiB. It replaces the Gateway model-list GET request; other requests use the configured HTTP client.

## Use a custom provider

Use a model service through `FxProvider.custom`. Set `apiProtocol` to `.chatCompletions` (the default), `.responses`, or `.anthropicMessages`. For Messages endpoints that reject inline tool definitions, set `deferredToolMode: .callAction` to keep discovery and invocation on fixed functions:

```swift
let provider = try FxCustomProvider(
    name: "local",
    baseURL: URL(string: "http://localhost:8000/v1")!,
    models: ["local-model": .init(
        contextWindow: 32768, maxOutputTokens: 4096, supportsToolUse: true
    )]
)
let engine = try await FxEngine.open(configuration: FxConfiguration(
    provider: .custom(provider, credentials: { request in
        key
    }),
    model: "local-model"
))
```

The asynchronous credentials closure receives the provider name and engine session ID and returns an API key. Omit it for a service that needs no key. Cancellation of the turn cancels a pending credential lookup. Keys are added only to the provider's configured model endpoint and remain outside core configuration and saved records. Rejected keys are not refreshed or resent. Error details are bounded and mask the key, including JSON-escaped copies.

The default Foundation HTTP client uses an ephemeral session with response caching, cookie storage, and credential storage disabled. It follows redirects only for unauthenticated GET and HEAD requests. A custom `FxHTTPClient` must preserve that credential scope when handling redirects. Custom providers support HTTPS and HTTP on loopback addresses. Use `FxProvider.subscription` for Codex or Grok subscriptions.

## Sign in to a subscription

Use `FxSignIn` with `.codex` for ChatGPT or `.grok` for Grok. Device authorization supplies a URL and user code for your interface:

```swift
let signIn = FxSignIn(provider: .grok)
let device = try await signIn.startDeviceAuthorization()
// Show device.verificationURL and device.userCode in your interface.
let credentials = try await signIn.completeDeviceAuthorization(device)
```

`pollDeviceAuthorization` checks once and returns nil while approval is pending. `completeDeviceAuthorization` waits between checks, slows polling when requested, stops at expiry and responds to task cancellation.

For a browser flow, call `startAuthorization`, open its `url` in the user's browser, then pass the copied callback address to `completeAuthorization(_:callback:)`. The SDK checks the state and exchanges the code with PKCE. It does not open a browser or run a callback server. Both authorization values are `Codable`; their encoded forms contain secrets. Keep them private and out of logs.

Save the returned credentials in your host's credential store. `refreshCredentials` exchanges them explicitly when needed outside an engine. A Grok refresh checks the account before returning new credentials. `FxSubscriptionCredentials.normalized(for:)` reads account routing metadata and expiry from token claims when those fields were omitted; it does not verify the token.

## Use subscription credentials

Share one `FxSubscription` across engines that use the same credential store:

```swift
let subscription = FxSubscription(provider: .codex, credentials: { context in
    try FxSubscriptionCredentials(
        accessToken: accessToken,
        refreshToken: refreshToken
    )
})
let engine = try await FxEngine.open(configuration: FxConfiguration(
    provider: .subscription(subscription),
    model: "gpt-6.1-sol"
))
```

Use `.grok` for a Grok subscription. Credentials can include an explicit `accountID` and `expiresAt`. Otherwise, the SDK reads routing metadata from the token's claims. This does not verify the token. An opaque token requires an explicit account ID. The credential request includes the provider and an optional session ID; catalog requests can lack a session identity.

Provide `onRefresh` to persist rotated credentials in your host's credential store. Refresh runs within five minutes of expiry, or once after a 401 when a refresh token exists. Sessions using the shared actor reuse a rotation and each receive its save callback. A failed save can be retried without spending the old refresh token again. A Grok refresh verifies the account through userinfo before saving or sending the new token.

For multiple processes or servers, supply `refreshLock`. Hold the account lock while awaiting the operation, and return its result. The SDK reloads credentials under that lock before exchanging a refresh token. Cancellation removes one waiting request; when the last waiter leaves, it cancels the refresh and pending save callback. Host closures and HTTP clients must cooperate with task cancellation.

The full durable agent/session provider suites remain pending.

## Observe host lifecycle events

Set `FxConfiguration.onLifecycleEvent` to receive typed `FxLifecycleEvent` values for journal restoration, saved snapshots, automatic snapshot failures, checkpoint metadata differences, and delivery deadlines. The callback works without `FxObservationOptions` and does not enable runtime hooks or content capture. Snapshot failures retain the original Swift error. `FxJournalRestoration` reports the restored cursor, sequence, turn IDs, counts, and checkpoint presence; mismatch events identify changed `FxCheckpointField` values and the saved and current `FxCheckpointIdentity`.

Callbacks are synchronous and can run concurrently across engines or session workers. Keep them short and protect shared state. The event enum and its payloads are `Sendable`; see Swift's [concurrency contract](https://docs.swift.org/latest/documentation/swift/sendable/). Use `onTransportEvent` for HTTP request diagnostics and `FxObservationOptions` for runtime and tool observations.

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

Pass tools through `FxConfiguration.tools`. A tool can return text, images, and an explicit error flag through `FxToolResult`. Its context carries a stable execution ID for effect deduplication, the session ID, and the public turn ID. Tool closures must cooperate with task cancellation.

`writes` controls admission separately from `isIdempotent`. When omitted, non-idempotent tools act as writers and idempotent tools as readers. Readers can run together until a writer. A writer waits for all preceding calls and blocks later calls until it finishes; results retain the model's call order. Set `writes: true` for an idempotent tool that changes state, or `writes: false` for a read-only tool whose result is not safe to replay.

Thrown errors become tool error results. The engine uses `LocalizedError.errorDescription` when supplied, otherwise the error's string description. An empty description or empty error result becomes `Tool <name> failed without a message` so the model receives usable text.

A `.toolStarted` event carries an optional `FxToolInput`: `.complete(JSONValue)` when the compact input fits in 64 KiB, or `.truncated(preview:)` with a bounded UTF-8 JSON prefix. Previews use sorted object keys and can end before the JSON value is complete. The event uses the core's redacted display input; the tool closure receives the complete execution arguments separately. Session event storage preserves this distinction across reopening.

Pass `providerTools: [.webSearch]` to `FxConfiguration` to advertise search executed by the model service. It has no host closure. Search calls and results appear as ordinary tool events and remain in checkpoint and journal history. Availability depends on the model service. Provider and host tool names share one namespace; duplicate names are rejected.

Images use `Data` and a supported format. Each prompt accepts up to eight images, at most 3.75 MiB each and 6 MiB together, subject to the encoded request limit. If a byte limit is exceeded, images with a source reference retain their reference and omit their bytes. The SDK checks image signatures; the core checks dimensions and model capabilities.

Call `try configuration.validatePrompt(content)` to check input before opening an engine. Validation runs no image preparation or network requests. With `prepareImage` configured, byte limits and signatures are checked after preparation when the prompt runs. Image count, references and text frame limits still apply during validation.

Tool image results use the same per-image limit and allow up to eight images. Their base64 data and rich JSON content must each fit 8 MiB. Referenced images omit bytes when needed to fit these limits. If the outer RPC response exceeds 8 MiB, the SDK first omits referenced image bytes, then returns a tool error if the response still cannot fit.

Set `configuration.prepareImage` to resize or convert prompt images before admission. The asynchronous closure receives an `FxImage` and must return nonempty bytes and a supported format. The original source reference is retained. Size limits apply to the prepared bytes, so the input may exceed those limits. Reference-only images and restored conversation images do not call the closure. Preparation runs before image storage or a model request; a thrown error fails the turn with the original error. The closure must cooperate with cancellation. Cancelling a turn or closing the engine cancels preparation, and closing waits for it to exit.

Cancelling a Swift task awaiting `turn.steer` stops that waiter and releases its pending queue reservation. It leaves the turn and other steering waiters running. A steer already accepted by the core can still take effect.

## Resolve core permission requests

Set `FxConfiguration.onPermission` to handle a permission request from the core. The asynchronous callback receives a `FxPermissionRequest` with the public session and turn IDs, tool details, bounded display input, and offered options. Return `.select(optionID:)` with one of those option IDs, or `.cancel`. Each option has a typed kind for allowing or rejecting once or for the session; your app can use that kind to localize its controls.

A missing callback, callback error, malformed request, or unoffered selection denies the request. The SDK does not copy callback errors into replies. Callback tasks are cancelled when their turn ends, is cancelled, or closes. A late callback cannot approve a later turn. Durable workers check their lease before and after the callback. Keep callbacks cancellable so your approval interface can dismiss pending work.

This callback handles core permission requests. Host tool closures remain responsible for authorizing their own effects. Declaring a host tool does not automatically route its execution through this callback.

## Observe runtime events

Set `FxConfiguration.observation` to receive semantic events:

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

Callbacks run synchronously. Concurrent tools can deliver callbacks from different tasks, with ordering preserved within each observed operation. Keep callbacks short and send asynchronous work to your own task or actor. An `onEvent` error is sent to `onError` without failing the turn or journal. Journal observations report restores, successful appends, and append failures.

When observation is enabled, a host tool receives `context.observation`. Pass its `childOptions()` to a child engine's `FxConfiguration.observation` to retain the root session and parent session, turn, and call identifiers. Existing native descendant ancestry is preserved. Durable tool context uses the caller's message ID as `context.turnID`; observation scopes retain the runtime turn ID used by the parent events.

Use `context.observation?.mcp(server:tool:correlationID:isError:operation:)` to observe an MCP effect owned by your host. The optional `LibFxMCP` module applies this helper automatically. It calls the effect once and preserves its result or error even when an observer throws. Cancellation or tool completion ends open spans once, and a retained scope emits no new operations after the tool ends. The full upstream hooks suite remains pending.

Use `observation.wait(_:resolution:failure:operation:)` to wrap your existing input callback. `FxWaitRequest` describes an approval, question, MCP form, or MCP URL wait. Map your callback's result to `FxWaitResolution` with `resolution:`; the original result is returned unchanged. Use `failure:` to classify host-specific timeout errors. Thrown errors retain their original identity, and cancellation ends the span once without replacing a late answer.

Wait content is omitted by default. With content capture enabled, each start or end event shares a 64 KiB UTF-8 text budget. Questions, options per question, and answers each retain at most 128 entries. `contentTruncated` reports omitted content or entries. These limits affect observations only; the input callback and caller retain their full values.

## Persist a conversation

Pass a store conforming to `FxPersistence` when opening the engine. Its records are opaque bytes. The store must reject a stale expected cursor and honor durability barriers. Appends run in order and combine events received while a write is pending. Replay-safe read-only tools can start before a non-barrier append completes. Effectful tools wait for their intent to be stored. Turn completion and `flushPersistence()` wait for pending writes and commit notifications. `FxSQLitePersistence` stores one conversation per local database file using the system SQLite library. Separate connections use transactions to reject stale writers. Close the store after its engines close.

```swift
let store = try FxSQLitePersistence(url: databaseURL)
```

Choose a file URL in your application's storage directory. `FxMemoryPersistence` provides an in-memory reference implementation for tests; it does not survive process exit.

`FxSQLitePersistence` and durable session storage keep image bytes separately, using their SHA-256 names in journal records and snapshots. Repeated images share the same stored bytes within a conversation. A custom store can adopt `FxImagePersistence` to provide the same behavior. Stores that implement only `FxPersistence` or `FxCheckpointPersistence` continue to save images inline.

Set `configuration.imageWindow = try FxImageWindow(maximumImages: 100, maximumBytes: 20 * 1024 * 1024)` to restrict retained conversation images. This requires image persistence. The core removes older images from the conversation and leaves a note in their place; it does not delete stored blobs. Restoring loads the images still required by the saved conversation. A missing blob throws `FxPersistenceError.missingImage` with its name. Custom image reads and writes must cooperate with task cancellation.

A failed prompt-image write rejects the turn before sending it to the model. If storage rejects an image returned by a tool, that image remains inline so the completed tool result is preserved.

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

Use `prompt(_:id:yieldAt:)` to give a turn a stable identity and an optional `Date` deadline. IDs contain 1–128 ASCII letters, digits, periods, underscores, or hyphens. Each turn exposes its ID through `FxTurn.id`. With persistence, retrying an interrupted ID resumes its saved input; retrying the most recently completed ID returns an empty completed turn without another model request. Starting a different ID replaces the interrupted turn. This deduplication covers the most recently completed ID, not all historical IDs.

Yielding requires persistence. Pass `yieldAt` to `prompt` or `resume` to stop at a safe boundary and return `.yielded`. Each invocation allows at least one model request before checking the deadline, including an expired deadline. Yielding does not interrupt an active request or tool. Resume the saved turn with `resume()` or its original ID. If your host already retains the streamed output, call `resume(replayingOutput: false)` to avoid delivering it twice. New output still streams normally. Durable sessions apply this policy automatically because their event log retains previous updates. Automatic snapshots also preserve yielded turns.

To transfer an active persisted turn to another engine, call `try await turn.handoff()`, await its cancelled result, and close the old engine. Handoff stops model and cooperative tool work while preserving the saved progress and pending steering. The old engine stops accepting journal records and cannot start or resume turns or save snapshots; those operations throw `FxError.handedOff`. Open a new engine with the same store and call `resume()`. Inspect its recovery calls before choosing any explicit reruns. A handoff on an old turn cannot affect a newer turn.

Queue text as a separate turn with `followUp`:

```swift
let queued = try await engine.followUp("Then summarize the changes")
try await queued.accepted
let next = try await queued.turn
for try await event in next { /* Display the event. */ }
_ = try await next.result
```

New follow-ups run in queue order after the active turn, or start immediately when the engine is idle. With persistence, `accepted` waits until the journal stores the input; without persistence, acceptance lasts only in memory. Cancelling a task waiting for acceptance or turn start does not remove the input. Close and handoff reject waiters whose turns have not started. After reopening, `resume()` first continues an interrupted turn, then starts one saved follow-up per call. Saved follow-ups wait for explicit resume and do not block new follow-ups queued in the current engine.

For an idle engine, `checkpoint()` returns opaque bytes that another Swift or JavaScript engine can restore. Provide either checkpoint bytes or a persistence store at creation.

Concurrent `checkpoint()` calls run in order. Each queued call checks that the engine is still idle before exporting. A prompt started during an export waits for that export before sending its request; queued exports then fail with `FxError.busy` while the prompt is active. Cancelling a queued export leaves the other calls intact. Closing rejects pending exports. Explicit restore checkpoints must be nonempty and no larger than 4 MiB.

With a store conforming to `FxCheckpointPersistence`, call `saveCheckpoint()` to save a journal snapshot through the last committed cursor. The store may then prune the covered journal prefix. Closing waits for a snapshot save already in progress. Journal snapshots differ from the export returned by `checkpoint()`; let the SDK create them.

The core can defer a snapshot while queued inputs remain unplaced or the session exceeds snapshot bounds. This leaves the journal intact. Automatic saving tries again after a later turn.

Exports and journal snapshots record the SDK format version, tool configuration hash, and model ID. Restoring with different metadata emits `.checkpointMismatch` through `FxObservationOptions`; restoration continues. Swift hashes sorted tool descriptors with SHA-256, including replay and write flags. Tool order and JSON object key order do not change the hash. JavaScript uses a different hash format, so crossing SDKs can report a tool-hash mismatch even for equivalent tools.

Journal and checkpoint interoperability have local tests. Automatic snapshots run after completed turns when the store supports `FxCheckpointPersistence`. `FxConfiguration.checkpointAfterBytes` defaults to 1 MiB; use `0` to attempt a snapshot after every turn, or `nil` to save only on explicit calls. A turn settles after its automatic snapshot attempt. A failed automatic save keeps the journal, emits `.checkpointError` when observation is enabled, and retries at a later turn. Successful saves emit `.checkpointSaved`.

Local process tests cover forced termination after a saved snapshot and after an ambiguous external write. Full crash-boundary coverage remains pending.


## Queue durable sessions

Use `FxSessionStore` for multiple conversations in one local SQLite database. Omit its URL for in-memory operation. Keep the store open until all agents using it have closed.

```swift
let store = try FxSessionStore(url: sessionsURL)
let agent = try FxAgent(configuration: configuration, name: "assistant", store: store)
let session = try await agent.session(id: "conversation-1")
let turn = try await session.prompt("Review the changes", id: "request-1")
for try await event in turn {
    if case .text(let delta) = event { print(delta, terminator: "") }
}
let result = try await turn.result
try await agent.close()
try await store.close()
```

A session view does not create stored data. `prompt` returns after durable acceptance, and inputs run in order within a session. Retrying a stored message ID returns its existing work and sets `isRepeated`; it does not replace the saved input. Each turn iterator replays its own durable events independently. Cancelling a reader leaves the work running. Call `turn.cancel()` to cancel that input, or `session.cancel()` to cancel the currently started input. `agent.close()` stops intake and waits for accepted work.

To share named agents, create `FxAgentRouter(store:)` and call `try await router.makeAgent(configuration:name:)`, `makeAgent(harness:name:)` with a conversation executor, or the typed overload with an `FxDurableHarness`. The router uses that store and keeps weak registrations; retain each agent until you close it. Compatible copies of a name can coexist and close independently. A different configuration throws `FxAgentAdmissionError.incompatibleConfiguration(name:)` before intake.

Kernel configuration values are compared automatically; for custom harnesses, tools, credentials, permissions, HTTP clients, queues, or retry classifiers, supply the same `compatibilityID` only when their behavior is compatible. Without an ID, an opaque configuration can create its first instance but cannot admit another copy. An ID does not override differences in known values such as models, instructions, tool schemas, or checkpoints. Observer callbacks do not affect compatibility.

The first accepted input fixes the session's owner. Views from other registered agents route prompts, steering, resume, cancellation, checkpoints and persisted replay to that owner, including concurrent first intake and duplicate IDs. If the owner is unavailable, newly accepted work stays pending and the call throws `FxAgentRoutingError.unavailableAgent`. Register a replacement with the same name and resume. The owner validates saved inputs before opening an executor; rejection ends that input once while later valid work continues. `router.deliver(_:)` selects the wakeup's named agent; retain the wakeup for retry if the target is unavailable. Routers do not discover agents in another store or process.

Direct agents and routers use `store.agentAdmission`. A store owns one admission domain by default. To coordinate separate connections to one logical SQLite store, create an `FxAgentAdmission` and pass it as `FxSessionStore(url:agentAdmission:)` to every connection. Host storage adapters expose one stable domain and proxies forward the underlying domain. There is no global registry: separate store objects with separate domains do not coordinate configuration admission, even if their database URL is the same. Admission does not persist configuration or compare other processes.

Separate hosts can register the same named harness in their own routers and share a SQLite database. Ownership serializes their deliveries and message IDs deduplicate accepted work. Each host must provide compatible harness behavior; the router does not compare closures or discover remote registrations.

When this agent owns the active turn, steering and cancellation also wait until its worker has checked the stored update. Updates owned by another process are discovered asynchronously. A steering receipt confirms acceptance; the user-message event confirms that the model received the guidance.

SQLite uses process locks by default. To allow takeover from a worker that remains alive but stops renewing, create a new database with a lease policy:

```swift
let policy = try FxSessionLeasePolicy(duration: .seconds(30), renewalInterval: .seconds(10))
let store = try FxSessionStore(url: sessionsURL, leasePolicy: policy)
```

Ownership mode is fixed when the database is created. Timed stores use the shared host's wall clock for expiry, and the agent uses a separate monotonic deadline to stop local work conservatively. Renewal failure or expiry fences the worker, cancels its active turn and leaves unfinished input available for another owner. A custom `FxRenewableSessionStorage` must atomically validate owner, epoch and expiry on every leased write. Already dispatched external effects still need service-side idempotency or fencing.

To recover from transient host storage errors while opening a session, pass an `openingRetryPolicy` when creating the agent. For example, `try FxOpeningRetryPolicy { ($0 as? URLError)?.code == .networkConnectionLost }` retries a host storage connection loss. Retries are disabled by default. The policy releases ownership before retrying the same accepted input, has a bounded retry count and delay, and preserves the final host error when exhausted. Missing images, corrupt journals, ownership failures, cancellation and errors after opening do not enter the classifier.

Set `FxSessionOptions` on a session view to capture the model, instructions, tool context and custom executor `settings` for subsequent inputs. `settings: JSONValue?` is separate from `context` and defaults to nil. Custom executors receive both during validation and opening; saved inputs retain both across resume and database reopening. Tools receive the logical session ID, public message ID, and captured context. `session.events(after:)` reads persisted entries by cursor and waits for later entries. Cancel its consuming task to stop reading.

Use `try await session.steer("Focus on the tests", id: "guidance-1")` to add durable guidance. Text joins the running turn at its next safe boundary and can interrupt a streaming response. When the session is idle, guidance starts a turn. A steer containing an image ends the current turn and runs as a new turn; later text can join that turn. Acceptance waits for storage, and retrying the same steering ID leaves the original input unchanged. Prompt and steering IDs share a namespace; reusing an ID for the other kind throws `FxSessionError.messageIDInUse`.

Cancelling a turn preserves guidance that the model has not received. The worker groups that guidance into subsequent work. A joined steer appears as a user-message event with its public ID in the owner's turn; it does not produce a separate turn-start event. Recovery uses persisted core acceptance and placement records to avoid submitting accepted guidance again.

Call `session.resume()` after reopening to get a turn view for pending work. It returns `nil` when no input needs to run. Local workers use a file lock and a persisted ownership epoch; journal and event writes reject an old owner within the write transaction. Recovery automatically reruns only tools declared idempotent. If the core committed completion before the host could save the result, recovery returns `.unknown` without issuing another model request.

An agent attempts a journal snapshot after a completed turn once new records reach 64 KiB. Set `FxAgent`'s `checkpointAfterBytes:` to another threshold, `0` to attempt after every turn, or `nil` to disable automatic saves. This setting is separate from the engine interval in `FxConfiguration`.

To continue a long turn across bounded worker deliveries, pass a delivery policy:

```swift
let policy = try FxDeliveryPolicy(maximumDuration: .seconds(60), reserve: .seconds(10))
let agent = try FxAgent(configuration: configuration, store: store, deliveryPolicy: policy)
```

The worker asks the core to yield at a safe boundary when the reserve begins. It saves a snapshot, releases ownership, and continues the same turn in another local delivery. If a request or tool remains active, it hands off before the deadline, leaving half the reserve, up to two seconds, for cleanup. A zero-duration policy permits one safe step before yielding. A zero reserve disables the active cutoff. The policy defaults to no time limit when omitted.

The durable event sequence includes `.yielded` and `.resumed`, with one final `.ended` for the whole turn. Safe tools can resume with their original execution IDs; ambiguous writes remain stopped. After three consecutive deadline cutoffs at the same step, a tool is no longer rerun, or a stalled model turn is cancelled. Counts survive reopening the store and reset when the core advances to another step. Active cutoffs emit `.sessionDeadline` observations. Host transports and tools must cooperate with cancellation. Without a queue, the agent schedules the next delivery locally.

To publish work to an external queue, implement `FxSessionQueue` and pass it as `queue:` to both the sending agent and the worker. Published wakeups contain the agent name, session ID, and accepted input ID, without prompt content or credentials. Both agents must use the same durable store. The host owns queue transport and routes messages to the matching agent.

```swift
let worker = try FxAgent(configuration: configuration, name: "assistant",
                         store: store, deliveryPolicy: policy, queue: queue)
let outcome = try await worker.deliver(wakeup)
switch outcome {
case .complete: break // Acknowledge the queue message.
case .retry(let delay): break // Retain it and redeliver after this delay.
}
```

Here, `queue` is your `FxSessionQueue` implementation, and `wakeup` is the decoded queue message. `enqueue` must return when the queue accepts the message, without waiting for execution. `prompt`, `steer`, and `resume` wait for publishing after durable acceptance. If publishing fails, the saved input remains: retry its original ID or call `resume`. Acceptance and publishing are separate operations, so a process failure between them requires host recovery of pending work.

A delivery policy covers the entire external delivery, including queued inputs. A busy owner returns `.retry`; duplicate messages for finished work return `.complete`. Retain and redeliver messages when `deliver` throws. Cancelling its awaiting task leaves durable execution running. In queue mode, `close()` waits for active deliveries and leaves other accepted inputs in storage for a later worker. The SDK does not implement a cloud queue client.

For authenticated redelivery before lease expiry, create a queue-aware store with `leasePolicy:` and `queueSource:`, configure the agent's `queueAuthority:`, and pass a fresh `FxQueueDeliveryContext` from your authenticated callback to `deliver(_:context:)`. The authority verifies callback metadata and binds it to the wakeup. Its source must identify the account, tenant, and store. Equal-attempt replacement is disabled unless the provider guarantees that the new callback replaces the old execution. Plain decoded messages retain ordinary lease rules. The HTTP handler accepts the same host-created context through `handle(_:body:context:)`.

### Receive HTTP wakeups

Add the optional `LibFxHTTP` product and Apple `HTTPTypes` product to your server target. `FxHTTPWakeHandler` accepts an `HTTPRequest` and body bytes from your existing server. Register each store's `FxAgentRouter` under an explicit route key. Your queue publisher can encode its received wakeup directly:

```swift
import Foundation
import LibFxHTTP
import HTTPTypes

let body = try JSONEncoder().encode(FxHTTPWakeRequest(store: "main", wakeup: wakeup))
let handler = FxHTTPWakeHandler(routes: ["main": router])
let response = try await handler.handle(request, body: body)
```

Here, `router` is your store's router, and `request` comes from your server. Keep its workers alive while serving requests and limit body collection to 16 KiB. The handler runs only input already stored under that store and session; request content cannot create a prompt or cancel work. Unknown inputs return 200 without execution. Completed deliveries return 200, pending retries return 503 with `Retry-After`, and delivery errors return 500. The optional `onError` callback receives the original error; HTTP responses have empty bodies. Cancelled requests throw while the durable worker continues. Retain messages after a non-success response or disconnected request. A manually constructed session wakeup without `inputID` cannot be encoded as an HTTP wake request.

Release writes receive one immediate retry after a host error. The `.storageFailed` lifecycle notification retains that error. Cancellation, `FxError`, `FxSessionError`, and `FxPersistenceError`, including fencing, do not retry. A second failure propagates without replaying executor effects; retain an external delivery for later recovery.

When the active cutoff expires while the engine is opening, the worker cancels preparation, waits for cleanup, and stops with `FxSessionError.preparationTimedOut`. The accepted input remains pending without a final result. Fix the underlying service, then call `session.resume()` to retry its original ID. The worker does not retry preparation automatically; `agent.close()` reports the failure if it remains unresolved. HTTP clients, credential callbacks, and asynchronous persistence loads must cooperate with cancellation. A callback that ignores cancellation delays cleanup and the timeout result.

Call `try await session.checkpoint()` to export the conversation, including stored images, without changing the session or taking ownership from its worker. Export reads a consistent stored snapshot and sends no model request. While a worker runs, the export includes only progress already stored. Pass the bytes as `checkpoint:` to a new `FxAgent` to seed new sessions. Existing stored sessions retain their own history. Exporting an unused session creates no stored data.

### Supply a session executor

Pass an implementation of `FxSessionHarness` to `FxAgent(harness:store:)` to run conversation turns without the Zig engine. The default `configuration:` initializer uses the same worker with the Zig executor. Both use the same session views, queue deliveries, ownership checks, cancellation and persisted output.

The harness validates session settings and input, prepares seed checkpoints, and opens an `FxHarnessSession` from `FxHarnessContext`. A session reports its interrupted or completed turn, starts or resumes a turn, exports checkpoints and joins pending writes on close. Each `FxHarnessTurn` supplies a bounded event stream, its result, and cancellation, handoff and steering operations. Check `context.checkOwnership()` before external effects and after awaiting permission.

Implement `flushPersistence()` to acknowledge pending journal writes independently of the running turn. The default throws an unsupported error; it does not acknowledge writes.

A terminal result must acknowledge its durable journal writes. After that result is saved, the next input can start while the previous executor closes. `agent.close()` joins all executor cleanup tasks and reports their errors; cleanup errors do not replace already stored turn results.

Use `context.persistence.append(expected:idempotencyKey:data:marks:barrier:)` for custom records, supplying an empty marks array when the record changes no routing state. Marks and bytes commit atomically; a retry must keep both unchanged. Append `.completed(runtimeTurnID)` with the terminal record before reporting the turn's result. A fresh harness can read `snapshot.completedTurnID` to implement its `completedTurnID` property without decoding its opaque bytes. This identity survives checkpoint compaction. Checkpoint bytes belong to the harness and are not wrapped in the Zig format. The conversation interface uses `FxPromptContent`, `FxSessionOptions` and `FxEvent`.

Throw `FxHarnessError.stopped` from a running turn when its executor exits. The worker closes it, joins pending journal writes and opens a replacement. Three stops end an input that never started, or cancel a recorded open turn. Two further stops during cancellation permanently halt that session; queued inputs receive errors without opening another executor. Stop counts and the halt survive database reopening. An opening failure ends the public input once without consuming this budget. If its old turn still needs cancellation, later work cleans it up with its original settings first. A completion record that lands before close finishes prevents rerunning completed work.

### Run typed data workloads

Use `FxDurableAgent<Input, Update>` with an `FxDurableHarness` when inputs and updates are application data rather than conversation blocks. Both types conform to `Codable` and `Sendable`. The harness opens an `FxDurableHarnessSession`, whose turns provide typed updates and a terminal `FxTurnResult`. It uses the same worker, storage, ownership, queue, cancellation and stopped-executor recovery as conversations.

Call `session.submit(_:id:)` to accept work and iterate the returned `FxDurableTurn<Update>`. `session.events(after:)` replays typed start inputs, updates and terminal results with their stored cursor and epoch. `steer(_:id:)` ends an active turn and queues the supplied input as a separate turn, returning its typed view. The encoded input, context and settings share an 8 MiB admission limit, including explicit model and instruction overrides. Admission runs before storage or queue publication. Each encoded update also has an 8 MiB limit; native conversation frame, image and instruction limits still apply. The adapter pulls updates without adding a producer task or buffer; the harness still controls its own stream buffering. The [calculation fixture](Tests/LibFxTests/CalculationHarness.swift) shows a complete executor with structured inputs, binary data, opaque journal records and checkpoints using public imports.

Durable results expose `failure`, an `FxSessionFailure` with `message`, `name`, optional upstream `code` and optional numeric `rpcCode`. The `error` convenience returns its message. A custom executor can throw `FxSessionFailure` directly or return it in `FxTurnResult.failure`; both retain its fields in the durable result. Host storage errors retain their original error object and leave work pending instead of becoming terminal execution failures.

The agent/session surface is still partial. Remote service integrations and full upstream durable-session qualification remain pending. Complete upstream custom-provider, Codex, and Grok test files have local proof. The session store's host event format is Swift-specific; core journal and checkpoint interoperability is a separate tested contract.

## Update deferred host tools

Set `deferred: true` on an `FxTool` to keep its definition out of the initial model request. The core exposes `tool_search` and loads matching definitions when the model searches. Use `try await engine.upsertTools([tool])` to add or replace deferred tools, and `try await engine.removeTools(named: [name])` to remove them. Set `configuration.toolSearchEnabled = true` before opening an empty catalog that you plan to populate later.

Updates require an idle engine and reject a concurrent prompt, checkpoint, or catalog update with `FxError.busy`. A rejected batch leaves the previous catalog in place. Resident tools and provider tools cannot be replaced through these methods. Calls use the current host closure and validate arguments against its current JSON Schema. A schema mismatch returns a tool error with the current definition; a removed tool cannot invoke its old closure.

The catalog holds at most 256 tools. The combined resident, provider, and discovery-tool count is at most 64. Deferred actions do not consume that prefix budget. Each description and schema is limited to 65,536 bytes, and one search result can carry at most 65,536 bytes of definitions. Keep schema keywords compatible with [JSONSchema.swift](https://github.com/kylef/JSONSchema.swift), which validates host arguments. Remote schema references are unsupported, and newer draft keywords have incomplete coverage in that dependency.

Journal events and checkpoints retain activation metadata, including across automatic context compaction. On reopen, provide the current catalog and closures in `FxConfiguration`. Catalog changes append persisted reminders, but the journal does not serialize the executable catalog or closures. Saved activation names that no longer exist are ignored. Definitions remain at their discovery position in the conversation; catalog changes do not rewrite the top-level tool list. This preserves the serialized tool prefix, but does not establish service-side cache hits.

Run `swift/scripts/test-runtime-catalog-consumer.sh` after building the XCFramework to exercise automatic compaction, schema replacement, removal, SQLite reopen, and checkpoint restoration from a separate package using public APIs.

Deferred actions keep the request's top-level tool list fixed. Chat Completions uses
`tool_search` to fetch definitions and `call_action(name, args)` to invoke them.
Responses sends definitions in `tool_search_output` items and calls actions natively.
The host still supplies current definitions and closures when reopening an engine.

`try await engine.appendContext(text)` appends a system reminder while idle. With
persistence enabled, it waits for the journal write. Catalog updates also append
reminders; they do not rewrite earlier messages. Compaction injects the current
catalog again. Fetch definitions again when they are absent from the context.
These paths have local fixtures; service acceptance and cache hits need separate
provider validation. Anthropic Messages supports text, tools, and streamed thinking with signature replay through `apiProtocol: .anthropicMessages`. Images and redacted thinking are not supported in this path. See [the AgentKit integration guide](FxAgentKit/DORA-INTEGRATION.md).
