# FxAgentKit

`FxAgentKit` provides one agent conversation on top of `LibFx`. It adds workspace tools and host approval, and owns the engine and its persistence connection. Provider configuration, prompts, streamed events, turn results, and cancellation use the existing LibFx types.

Add the `FxAgentKit` and `LibFx` products from this Swift package to your application target. Use the package's existing [native build setup](../README.md#build-and-use-a-local-package).

## Create an agent

Set `AI_GATEWAY_API_KEY`, replace `provider/model` with your model ID, and choose the workspace and database paths. The database URL is an explicit host choice.

```swift
import Foundation
import LibFx
import FxAgentKit
let config = FxConfiguration(apiKey: ProcessInfo.processInfo.environment["AI_GATEWAY_API_KEY"]!, model: "provider/model", workspace: URL(fileURLWithPath: "/path/to/workspace"))
let agent = try await Agent.open(configuration: config, persistenceURL: URL(fileURLWithPath: "/path/to/app-data/conversation.sqlite"))
let turn = try await agent.prompt("Read the project and describe it.")
for try await event in turn { if case .text(let text) = event { print(text, terminator: "") } }
let result = try await turn.result
try await agent.close()
```

By default, the agent includes `read_file`, `write_file`, `edit_file`, and `shell`. Reads run without approval. Writes, edits, and shell calls are denied until the host grants approval. Relative file paths resolve from `configuration.workspace`; shell commands use it as their working directory. Workspace tools also accept absolute file paths.

Consume the `FxTurn` event stream before awaiting its result, as shown above, so the runtime can drain streamed output. `await turn.cancel()` cancels a running turn. Always await `agent.close()` when the host stops using the agent, including after an error. Concurrent and repeated calls share one teardown, which closes the engine before closing the owned SQLite connection. New prompts and resume calls fail with `FxError.closed` once closing begins.

## Approve effects

Pass an `FxToolApproval` actor to `Agent.open(configuration:persistenceURL:approval:builtInTools:)`. Its asynchronous handler receives plugin identity, tool name, input, tool context, and the effect classification. Return `.allowOnce`, `.allowPlugin`, or `.deny`. Your host supplies any approval interface.

The following excerpt assumes `approvalHandler` is your host's `@Sendable (FxToolApproval.Request) async throws -> FxToolApproval.Decision` closure:

```swift
let approval = FxToolApproval(onApproval: approvalHandler)
let agent = try await Agent.open(configuration: config, persistenceURL: databaseURL, approval: approval)
```

Built-in tools share this approval actor under plugin ID `"workspace"`. File writes and edits use `.write`, so an `.allowPlugin` decision covers later writes for that plugin. Every shell call uses `.dangerous` and requests approval, even when the plugin has a write grant. For dangerous calls, `.allowPlugin` allows only the current call. The SDK does not parse shell commands to grant permission.

`agent.approval` exposes the same actor for `allowedPlugins`, `allow(pluginID:)`, and `revoke(pluginID:)`. Grants live in memory; the host owns their persistence. Restoring conversation history does not restore approval grants. A pending approval cannot restore a grant revoked while it was waiting.

## Add plugin tools or choose built-ins

`configuration.tools` is preserved. These plugin tools are **not automatically approved**: wrap each effectful plugin closure with the shared actor before adding it. The host assigns plugin IDs and effect levels based on the implementation; untrusted plugin declarations do not authorize effects.

Given an existing `FxTool` named `pluginTool`:

```swift
var pluginConfig = config
pluginConfig.tools.append(approval.wrap(tool: pluginTool, pluginID: "notes", effect: .write))
let agent = try await Agent.open(configuration: pluginConfig, persistenceURL: databaseURL,
                                approval: approval, builtInTools: [.readFile, .writeFile])
```

Use `builtInTools: []` to disable built-ins. Tool names share LibFx's namespace, so duplicate names fail opening. Reuse the same approval actor and wrapped tools in other host entry points. `FxConfiguration.onPermission` continues to handle core permission requests; it does not authorize these Swift closures.

## Continue after restart

With a `persistenceURL`, the agent stores its conversation in `FxSQLitePersistence`. Opening a new agent with the same URL restores prior messages for the next prompt. Without a URL, it uses `FxMemoryPersistence`, which lasts only for that agent instance. Use one active agent per database URL; this API does not route multiple sessions or coordinate background workers.

Call `try await agent.resume()` after opening to recover an unfinished turn. It returns the existing `FxTurn` type, or `nil` when there is no unfinished work. Consume a resumed turn's events and result in the same way as a new turn. LibFx's recovery rules continue to protect ambiguous tool calls from automatic repetition. To hand off an active turn while preserving unfinished work, call `try await turn.handoff()` before closing, then resume from a new agent instance.

Long-context compaction remains part of the existing core agent runtime. FxAgentKit does not add a separate summarizer or rewrite its configuration. `checkpointAfterBytes` controls persistence snapshots, not the model's context-compaction threshold. Use `upsertTools`, `removeTools(named:)`, and `appendContext` while the agent is idle. Set `toolSearchEnabled` before opening an initially empty catalog. Approval wrappers preserve `FxTool.deferred`. Reopen with the current tool definitions and closures; the journal stores conversation and activation state, not executable plugins. See [the dora integration guide](DORA-INTEGRATION.md).

## Run the public consumer

From the repository root, run:

```bash
swift/scripts/test-tool-approval-consumer.sh
```

This development check builds a separate package using public imports. It runs `Agent` through a native engine with fixture HTTP responses, verifies allowed and denied host effects, then starts two separate processes to verify SQLite conversation recovery. The second process checks that its model request contains the first process's user message and assistant reply. It needs no model credentials and rejects runtime stderr output. Package dependency resolution can require network access.
