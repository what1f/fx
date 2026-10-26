# Workspace tools

`FxAgentKit` supplies optional host tools for UTF-8 files and foreground shell commands. They run in your process through `FxTool` closures. The SDK does not start the fx CLI or a terminal UI.

Use `Agent.open` to assemble the default workspace tools and approval policy automatically; see the Agent SDK getting-started guide. The lower-level composition below lets you select tools and pass them directly to a LibFx engine:

```swift
import Foundation
import LibFx
import FxAgentKit

let approval = FxToolApproval { request in
    // Ask your host UI and return its decision.
    await confirm(request)
}
let workspace = URL(fileURLWithPath: "/Users/example/Plugins/MyPlugin")
let tools = FxWorkspaceTools(
    workspace: workspace, approval: approval, pluginID: "my-plugin"
).tools([.readFile, .writeFile, .editFile, .shell])
let configuration = FxConfiguration(apiKey: apiKey, tools: tools, workspace: workspace)
let engine = try await FxEngine.open(configuration: configuration)
let turn = try await engine.prompt("Read the plugin's settings")
for try await event in turn {
    if case .text(let text) = event { print(text, terminator: "") }
}
let result = try await turn.result
try await engine.close()
```

The example assumes your host defines `apiKey` and an async `confirm` function that returns `FxToolApproval.Decision`. The constructor requires an approval policy and plugin ID. Every returned tool applies that policy internally. You can append your plugin tools to the same `configuration.tools` array.

Read-only tools do not prompt. File writes and edits use the `.write` effect, which can use a remembered plugin grant. Shell uses `.dangerous`, which requests approval for every invocation. A denied or cancelled approval does not execute the closure. See [Tool approval](TOOL-APPROVAL.md) for grant lifetime and revocation.

## Tool contracts

Model-facing names and parameters follow pi's read/bash/edit/write surface:

| Selection | Model tool | Input | Result |
| --- | --- | --- | --- |
| `.readFile` | `read` | `path`, optional 1-based `offset` and `limit` | Numbered UTF-8 lines (at most 400 lines and 50 KiB), or typed image content resized to at most 1568 pixels per side |
| `.writeFile` | `write` | `path`, `content` | Writes the complete UTF-8 content atomically; missing parent directories are created |
| `.editFile` | `edit` | `path`, `oldText`, `newText` | Replaces one exact byte match atomically; empty, missing, duplicate, and overlapping matches are rejected |
| `.shell` | `bash` | `command`, optional positive `timeout` in seconds (at most 86400) | JSON text containing `exit_code`, combined `output`, and `output_truncated`; nonzero exit marks the tool result as an error |

Text files are limited to 4 MiB. Reads reject invalid UTF-8 and NUL bytes. Edits preserve unmatched bytes, including line endings. No whitespace normalization or fuzzy matching occurs.

Bash uses `/bin/bash`, inherits the host process environment, and starts in the configured workspace. It does not read interactive shell startup files. It supplies no interactive input, TTY, or background session handle. stdout and stderr share one pipe. The owner continues draining after the retained 50 KiB window fills. Invalid output bytes use replacement characters.

Cancellation sends TERM to the verified process group, then KILL after 500 ms, including descendants whose shell has already exited. The call waits for its owned shell to exit and for the escalation before reporting cancellation. The launch waits until the owner has verified and recorded the group before executing the supplied command.

## Workspace and access

The workspace is a base for relative file paths and the shell's working directory. It is **not a sandbox**. Absolute paths and relative paths containing `..` can access files outside it. Commands inherit the host process's operating-system access. Approval controls whether a tool runs; it does not restrict what an approved command can access.

## Verify through the public SDK

From the repository root:

```sh
swift/scripts/build-xcframework.sh
swift test --package-path swift --no-parallel --filter WorkspaceTools
swift/scripts/test-workspace-tools-consumer.sh
```

The consumer builds a separate Release package and imports only public APIs. It creates a native SDK instance with a fixture HTTP provider, executes read/write/edit/shell alongside a plugin tool, and checks that subsequent model requests contain their results. It also verifies that a rejected shell command creates no file and that cancelling a turn stops its owned shell. It does not use private test transports or live credentials.
