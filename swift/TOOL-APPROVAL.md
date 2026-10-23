# Host tool approval

Use `FxToolApproval` to authorize plugin effects before a host `FxTool.execute` closure runs. `FxConfiguration.onPermission` handles permission requests from the core. Host closures authorize their own effects, as described in [the Swift SDK permission contract](README.md#resolve-core-permission-requests). This wrapper implements that host responsibility and leaves core permission policy unchanged.

This wrapper covers only Swift host closures passed through `wrap`. For Swift workspace tools, wrap file reads as `.readOnly`, file writes and edits as `.write`, and every shell call as `.dangerous`. Keep shell approval unconditional; do not infer permission from command text. Core permission requests continue to use `onPermission`.

The host assigns each tool's `pluginID` and `FxToolEffect` after checking its implementation and capabilities. Do not trust a plugin to classify its own effects. The `writes` and `isIdempotent` properties retain their scheduling meanings; they do not grant permission.

## Wrap a tool

The following excerpt assumes `saveTool` is an existing `FxTool`. Replace the callback body with your host's approval flow. The callback can inspect `request.pluginID`, `toolName`, `input`, `context`, and `effect`.

```swift
import LibFx

let approval = FxToolApproval { request in
    // Return the host's decision after presenting or evaluating this request.
    return .deny
}
let approvedSave = approval.wrap(tool: saveTool, pluginID: "notes", effect: .write)
// Include approvedSave in FxConfiguration.tools.
```

| Effect | Execution rule |
| --- | --- |
| `.readOnly` | Executes without calling the approval callback. |
| `.write` | Calls the callback unless this plugin has a write grant. |
| `.dangerous` | Calls the callback for every invocation, including plugins with write grants. |

The callback returns `.allowOnce`, `.allowPlugin`, or `.deny`. An `.allowPlugin` decision for a write tool grants later write calls for the same plugin, including other tools. It does not cover another plugin. For a dangerous tool, `.allowPlugin` allows only the current call and creates no grant.

A denial throws `FxToolApproval.Failure.denied`. Callback errors propagate unchanged. Neither outcome calls the original closure. The wrapper checks task cancellation before approval and after the callback returns, then checks again before calling the original closure. Cancellation during approval prevents execution and grant creation, even if the callback later returns an allow decision. Swift uses [cooperative cancellation](https://docs.swift.org/latest/documentation/the-swift-programming-language/concurrency/): callbacks must cooperate with cancellation to stop waiting promptly, and the original closure must handle cancellation once execution starts.

An allowed call forwards the full input and `FxToolContext`, invokes the original closure once, and preserves its result or error without retries. The wrapped tool keeps the original name, description, schema, `isIdempotent`, and `writes` values.

## Share and persist grants

Reuse the same approval actor across the host's agent, GUI, trigger, and cross-plugin entry points. Each entry point must call the wrapped tool. Calling the original closure directly skips this host authorization step.

Wrapping is explicit. `FxEngine` does not inspect effect metadata or add an approval gate automatically. Construct each `FxTool`, wrap it with the host-approved plugin identity and effect, and register the returned tool in `FxConfiguration.tools`.

`allowedPlugins` returns a snapshot of the current write grants. The actor stores grants only in memory. Your host owns persistence, plugin identity validation, and any approval interface. To restore a previously approved grant, call `allow(pluginID:)`. This method also lets a trusted host grant write access explicitly.

```swift
// After loading and validating a host-managed saved grant:
await approval.allow(pluginID: "notes")
let pluginsToSave = await approval.allowedPlugins

// After the user revokes access:
await approval.revoke(pluginID: "notes")
```

`revoke(pluginID:)` removes the plugin's write grant. A pending approval that started before revocation can still allow that individual call, but cannot restore a long-term grant. Revocation does not cancel a call already executing. Persist grant changes through the host's storage policy; reading a snapshot does not write it to disk or synchronize it with another process. A new approval actor starts without grants.

## Run the public API smoke check

From the repository root, with the Swift toolchain and `swift/Artifacts/CFx.xcframework` available, run:

```bash
swift/scripts/test-tool-approval-consumer.sh
```

This script is a development acceptance tool. It builds a separate consumer package against this checkout using public API imports. It starts a native `FxEngine` with a fixture HTTP client and runs both approval outcomes. The allowed call writes a temporary file exactly once. The denied call produces an error tool result without executing the closure or creating the file. Both turns continue through the model fixture and close the engine. The script also fails if the consumer writes to stderr. It needs no model credentials and removes its temporary package and files when it exits. Package dependency resolution can require network access.
