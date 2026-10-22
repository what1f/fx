# libfx Swift

A Swift 6 package for running the fx agent core in process through a C ABI. The SDK is under development. See [the migration plan](MIGRATION.md) for required scope and [validation](VALIDATION.md) for the checks performed so far.

## Build and use a local package

Requirements: macOS 14 or later, Xcode, Swift 6.2 or later, and Zig 0.17.0.

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

Cancelling a Swift task that awaits `turn.result` cancels the turn and makes that waiter throw `CancellationError`.

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

## Use a custom provider

Use an OpenAI Chat Completions service through `FxProvider.custom`:

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

The asynchronous credentials closure receives the provider name and engine session ID and returns an API key. Omit it for a service that needs no key. Cancellation of the turn cancels a pending credential lookup. Keys are added only to the provider's chat endpoint and remain outside core configuration and saved records. Rejected keys are not refreshed or resent. Error details are bounded and mask the key, including JSON-escaped copies.

The default Foundation HTTP client follows redirects only for unauthenticated GET and HEAD requests. A custom `FxHTTPClient` must preserve that credential scope when handling redirects. Custom providers support HTTPS and HTTP on loopback addresses. Use `FxProvider.subscription` for Codex or Grok subscriptions.

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

The SDK supplies authentication and token refresh for existing credentials. Sign-in helpers and the full durable agent/session provider suites remain pending.

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

Images use `Data` and a supported format. Each prompt accepts up to eight images, at most 3.75 MiB each and 6 MiB together, subject to the encoded request limit. The core checks image content and model capabilities. Image resizing and external image storage are not implemented yet.

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

Use `prompt(_:id:yieldAt:)` to give a turn a stable identity and an optional `Date` deadline. IDs contain 1–128 ASCII letters, digits, periods, underscores, or hyphens. Each turn exposes its ID through `FxTurn.id`. With persistence, retrying an interrupted ID resumes its saved input; retrying the most recently completed ID returns an empty completed turn without another model request. Starting a different ID replaces the interrupted turn. This deduplication covers the most recently completed ID, not all historical IDs.

Yielding requires persistence. Pass `yieldAt` to `prompt` or `resume` to stop at a safe boundary and return `.yielded`. Each invocation allows at least one model request before checking the deadline, including an expired deadline. Yielding does not interrupt an active request or tool. Resume the saved turn with `resume()` or its original ID. Automatic snapshots also preserve yielded turns.

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

Set `FxSessionOptions` on a session view to capture the model, instructions, and tool context for subsequent inputs. Tools receive the logical session ID, public message ID, and captured context. `session.events(after:)` reads persisted entries by cursor and waits for later entries. Cancel its consuming task to stop reading.

Use `try await session.steer("Focus on the tests", id: "guidance-1")` to add durable guidance. Text joins the running turn at its next safe boundary and can interrupt a streaming response. When the session is idle, guidance starts a turn. A steer containing an image ends the current turn and runs as a new turn; later text can join that turn. Acceptance waits for storage, and retrying the same steering ID leaves the original input unchanged. Prompt and steering IDs share a namespace; reusing an ID for the other kind throws `FxSessionError.messageIDInUse`.

Cancelling a turn preserves guidance that the model has not received. The worker groups that guidance into subsequent work. A joined steer appears as a user-message event with its public ID in the owner's turn; it does not produce a separate turn-start event. Recovery uses persisted core acceptance and placement records to avoid submitting accepted guidance again.

Call `session.resume()` after reopening to get a turn view for pending work. It returns `nil` when no input needs to run. Local workers use a file lock and a persisted ownership epoch; journal and event writes reject an old owner within the write transaction. Recovery automatically reruns only tools declared idempotent. If the core committed completion before the host could save the result, recovery returns `.unknown` without issuing another model request.

An agent attempts a journal snapshot after a completed turn once new records reach 64 KiB. Set `FxAgent`'s `checkpointAfterBytes:` to another threshold, `0` to attempt after every turn, or `nil` to disable automatic saves. This setting is separate from the engine interval in `FxConfiguration`.

To continue a long turn across bounded worker deliveries, pass a delivery policy:

```swift
let policy = try FxDeliveryPolicy(maximumDuration: .seconds(60), reserve: .seconds(10))
let agent = try FxAgent(configuration: configuration, store: store, deliveryPolicy: policy)
```

The worker asks the core to yield at a safe boundary when the reserve begins. It saves a snapshot, releases ownership, and continues the same turn in another local delivery. If a request or tool remains active, it hands off before the deadline, leaving half the reserve, up to two seconds, for cleanup. Each delivery allows at least one model request. A zero reserve disables this active cutoff. The policy defaults to no time limit when omitted.

The durable event sequence includes `.yielded` and `.resumed`, with one final `.ended` for the whole turn. Safe tools can resume with their original execution IDs; ambiguous writes remain stopped. After three consecutive deadline cutoffs at the same step, a tool is no longer rerun, or a stalled model turn is cancelled. Counts survive reopening the store and reset when the core advances to another step. Active cutoffs emit `.sessionDeadline` observations. Host transports and tools must cooperate with cancellation. This policy continues work locally; it does not provide an external queue or serverless delivery adapter.

When the active cutoff expires while the engine is opening, the worker cancels preparation, waits for cleanup, and stops with `FxSessionError.preparationTimedOut`. The accepted input remains pending without a final result. Fix the underlying service, then call `session.resume()` to retry its original ID. The worker does not retry preparation automatically; `agent.close()` reports the failure if it remains unresolved. HTTP clients, credential callbacks, and asynchronous persistence loads must cooperate with cancellation. A callback that ignores cancellation delays cleanup and the timeout result.

Call `try await session.checkpoint()` to export the conversation, including stored images, without changing the session or taking ownership from its worker. Export reads a consistent stored snapshot and sends no model request. While a worker runs, the export includes only progress already stored. Pass the bytes as `checkpoint:` to a new `FxAgent` to seed new sessions. Existing stored sessions retain their own history. Exporting an unused session creates no stored data.

The agent/session surface is still partial. External scheduling and storage adapters and full upstream durable-session qualification remain pending. Complete upstream custom-provider, Codex, and Grok test files have local proof. The session store's host event format is Swift-specific; core journal and checkpoint interoperability is a separate tested contract.
