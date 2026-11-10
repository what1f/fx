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

Use `.chatCompletions` with a base URL ending in `/v1` for Chat Completions. Use `.anthropicMessages` with `https://api.deepseek.com/anthropic/v1` for DeepSeek Messages. The SDK appends `/chat/completions`, `/responses`, or `/messages` respectively. Messages starts with native inline definitions. When a request contains deferred content and returns HTTP 400 or 422, fx retries the same turn using reference declarations, then `call_tool`. Only a successful retry saves the lower mode. The mode belongs to the session and survives journal and checkpoint recovery; hosts do not configure it.

Credentials are requested by the host transport and sent only to the configured endpoint. They are not included in native engine options or conversation persistence. The default HTTP client disables disk caching and cookie/credential storage. A host-supplied URLSession or custom HTTP client must preserve this boundary.

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

Repeated searches can return the same matches. Each native request declares a tool name once, at its first discovery position, using that saved schema. Catalog updates append current definitions as context and never replace historical schemas. Use the fixed `call_tool` function for updated arguments. Removed tools remain in historical context but cannot execute. Searches save only newly declared tools; repeated searches still return current information. The serializer filters duplicate declarations in saved histories without modifying the stored records. Compaction establishes a new declaration baseline.

Responses carries discovered definitions in `tool_search_output`. Messages native mode uses inline `tool_addition` blocks, a fixed deferred placeholder, and the inline-tools beta header. Reference mode appends first saved definitions to top-level `tools` with `defer_loading: true` and returns text plus `tool_reference` blocks; it sends no inline-tools beta header. Removed tools retain their saved declarations so historical references remain valid, but cannot execute. Call-tool mode returns definitions as text and invokes current definitions through `call_tool(name, args)`. Chat Completions uses fixed `tool_search` and `call_tool` functions. All modes retain `call_tool` from the first deferred request. Messages combines adjacent user messages, including parallel tool results and user interruptions, and places all tool results first. Native additions follow that combined group. See [the acceptance record](DORA-VALIDATION.md).

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

## Deferred-mode cache boundaries

Within a mode, instructions, resident tools, first saved schemas and history remain stable. Reference declarations append in first-discovery order, including after catalog removal and recovery. Reference needs no placeholder: an empty deferred declaration list is valid before the first search. The native placeholder is retained only in native mode. Each successful downgrade reserializes the retained history and replaces the mode-specific declarations; this is an approved boundary, at most twice per session. The resident `call_tool` declaration is present throughout, so fallback does not introduce a new resident tool. The rename itself changes that resident schema once when adopting this build.

This is a breaking update: provider mode configuration is removed, and the invocation tool has a new name. Saved calls with the previous name replay unchanged; execution has no alias or migration. New calls must use `call_tool`. A host must remove the deleted Swift initializer argument and any saved provider configuration field before using this build.

Summary requests share the session's negotiation and persistence callback. A summary that first triggers fallback commits the learned mode once; subsequent summary and main requests reuse it, including when no compacted context is installed. The parent instructions and resident declarations stay unchanged within that mode.
