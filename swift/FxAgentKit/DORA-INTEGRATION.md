# Connect dora to FxAgentKit

Use the local Swift package in the `dora/integration` worktree. Add that worktree's `swift` directory as a local SwiftPM dependency and depend on its `FxAgentKit` product. The product reexports the LibFx configuration, tool, event, and result types. dora opens one `Agent` and keeps it for the conversation.

Build its native dependency before resolving the package:

```sh
bash swift/scripts/build-xcframework.sh
```

The generated `swift/Artifacts/CFx.xcframework` contains macOS arm64 and x86_64 slices. It stays local and is not committed. The package supports macOS 14 or later. The live acceptance consumer requires macOS 15 for its stream instrumentation.

## Open a conversation

The following function takes credentials and an approval callback from the host. The callback must suspend until the user decides. Use one active agent per database URL.

```swift
import Foundation
import FxAgentKit

func converse(
    workspace: URL,
    database: URL,
    credential: @escaping @Sendable () async throws -> String,
    decide: @escaping @Sendable (FxToolApproval.Request) async throws -> FxToolApproval.Decision
) async throws {
    let provider = try FxCustomProvider(
        name: "deepseek",
        baseURL: URL(string: "https://api.deepseek.com/v1")!,
        models: ["deepseek-flash": .init(
            contextWindow: 1_048_576,
            maxOutputTokens: 16384,
            supportsToolUse: true
        )],
        apiProtocol: .responses
    )
    var config = FxConfiguration(
        provider: .custom(provider, credentials: { _ in try await credential() }),
        model: "deepseek-flash",
        workspace: workspace
    )
    config.toolSearchEnabled = true
    let approval = FxToolApproval(onApproval: decide)
    let agent = try await Agent.open(
        configuration: config,
        persistenceURL: database,
        approval: approval,
        builtInTools: []
    )
    do {
        let turn = try await agent.prompt("Hello")
        for try await event in turn {
            if case .text(let delta) = event { print(delta, terminator: "") }
        }
        let result = try await turn.result
        guard result.stopReason == .endTurn else {
            throw result.failure ?? FxSessionFailure(message: "The reply did not finish")
        }
        try await agent.close()
    } catch {
        try? await agent.close()
        throw error
    }
}
```

The core compacts old turns when the conversation approaches its configured input window. `checkpointAfterBytes` controls journal snapshots, not context compaction. Choose model limits that match the provider. The live acceptance consumer deliberately uses a 32768-token window with a 16384-token output budget to exercise compaction sooner.

Use `.chatCompletions` with a base URL ending in `/v1` for Chat Completions. Use `.anthropicMessages` with `https://api.deepseek.com/anthropic/v1` and `deferredToolMode: .callAction` for DeepSeek Messages. This explicit compatibility mode uses fixed `tool_search` and `call_action` functions because that endpoint rejects inline tool definitions. The default `.native` mode remains available for Messages services that accept them. The SDK appends `/chat/completions`, `/responses`, or `/messages` respectively. Credentials are requested by the host transport and sent only to the configured endpoint. They are not included in native engine options or conversation persistence. The default HTTP client disables disk caching and cookie/credential storage. A host-supplied URLSession or custom HTTP client must preserve this boundary.

## Register plugin actions

Given an open `agent` and its shared `approval` actor, wrap a tool before adding it. The host assigns its effect from the implementation. A plugin's description cannot authorize its effects.

```swift
let action = FxTool(
    name: "notes_save",
    description: "Save a note",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")]),
        "additionalProperties": .bool(false)
    ]),
    isIdempotent: false,
    writes: true,
    deferred: true
) { input, _ in
    // Call the host's plugin implementation after approval.
    FxToolResult(text: input["text"]?.string ?? "")
}
let wrapped = approval.wrap(tool: action, pluginID: "notes", effect: .write)
try await agent.upsertTools([wrapped])
try await agent.appendContext("Prefer short notes.")
try await agent.removeTools(named: ["notes_save"])
```

These operations require an idle agent. `upsertTools` replaces the current schema and closure by name. Validation uses the current schema before executing the closure. Removed actions cannot execute an old closure. The approval wrapper preserves `deferred` and all descriptor fields.

Catalog changes and appended context are persisted as reminders at the end of the conversation. Open with the current plugin definitions and closures after restart. The journal preserves conversation and discovery state; it does not install plugins or serialize closures. After compaction, the core reinserts the current catalog.

Repeated searches can return the same matches. Each native request declares a tool name once, at its first discovery position, using its current schema. Updated schemas replace prior declarations in the outgoing request, and removed tools are omitted. This can invalidate the cache prefix from that position. The persisted discovery record stays unchanged. Chat Completions and Messages `.callAction` search results also use current schemas.

Responses carries discovered definitions in `tool_search_output`. Messages in `.native` mode uses inline `tool_addition` blocks and a fixed deferred placeholder, following pi. Messages in `.callAction` mode returns definitions as tool-result text and routes calls through `call_action`, using the same current-schema validation and approval wrapper. Chat Completions uses fixed `tool_search` and `call_action` functions. Service support must be verified for each endpoint; see [the local acceptance record](DORA-VALIDATION.md).

## Show events and handle approval

| Event | Host action |
| --- | --- |
| `.text` | Append reply text |
| `.reasoning` | Append thinking text to the host's thinking view |
| `.toolStarted` | Show the call identity, name, and available input |
| `.toolFinished` | Update the call with its result and `isError` status |
| `.userMessage` | Apply accepted user messages or steering updates |
| `.payload` | Handle custom harness data when such a harness is configured |

Consume each `FxTurn` once, then await `turn.result` for its stop reason, failure, and usage. A turn can make several model requests. Its usage is aggregated; use a host `FxHTTPClient` wrapper when per-request provider usage is needed. `nil` cache usage means the provider did not supply that field. A positive cache count proves a hit for that request, not a guarantee for future requests.

Read-only wrapped tools execute without prompting. Write tools ask unless their plugin has a write grant. Dangerous tools ask on every call. `.deny` prevents the original closure from running. `.allowOnce` allows that call. `.allowPlugin` grants subsequent write calls for that plugin; it permits only the current dangerous call. Call `approval.revoke(pluginID:)` to revoke a grant. Grants live in memory; dora owns any cross-launch grant storage.

`FxConfiguration.onPermission` handles core permission requests. It is separate from `FxToolApproval`, which guards Swift plugin closures. Optional workspace tools use the same approval actor. Their workspace sets path resolution and shell cwd; it is not a sandbox.

Call `await turn.cancel()` to cancel active work. Await the event stream/result and always await `agent.close()` before releasing host resources. To recover unfinished work, reopen with the same database and current tool directory, then call `agent.resume()`. A finished conversation continues with `agent.prompt` after reopening.
