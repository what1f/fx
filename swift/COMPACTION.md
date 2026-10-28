# Automatic conversation compaction

`FxEngine` uses the Zig agent runtime's automatic context compaction through the native C ABI. The default trigger is 80% of the model's usable input capacity: its context window minus the reserved output tokens. Compaction replaces older context with a compacted summary so the same conversation can continue.

For a custom provider, supply the selected model's limits:

```swift
import Foundation
import LibFx

let provider = try FxCustomProvider(
    name: "local",
    baseURL: URL(string: "http://localhost:8000/v1")!,
    models: [
        "local-model": .init(contextWindow: 32768, maxOutputTokens: 4096),
    ]
)
var configuration = FxConfiguration(provider: .custom(provider), model: "local-model")
configuration.autoCompaction = .tokens(131072)
```

Use the model's actual limits in a host application. Set `configuration.autoCompaction` to `.percent(80)` or `.tokens(positiveCount)`; percentages must be between 10 and 80. Leave it `nil` to preserve the core default and existing CLI percentage configuration. Invalid values throw `FxError.invalidInput` before the native engine opens.

The Zig core caps a token limit at 80% of usable input, which reserves room for output. For the model above, `.tokens(131072)` therefore triggers at 22937 tokens. If the context window is unknown, the specified token limit applies directly. Reopening a conversation uses the configuration supplied at open; the trigger is not part of the persisted conversation.

The Swift option travels through the existing C ABI JSON configuration as `autoCompact: {"percent": 80}` or `autoCompact: {"tokens": 131072}`. No C function signature changes. CLI configuration and `FX_AUTO_COMPACT_PERCENT` keep their existing behavior; there is no new CLI token setting.

## Turn events

The active turn emits `FxEvent.compaction(id:state:)` after the core selects content to compact. The state starts as `.started` and ends as `.completed`, `.cancelled`, or `.failed` with the same ID. A turn can contain more than one compaction. Requests that select no content emit no compaction events. Explicit turn cancellation or session closure can discard pending notifications along with the rest of that turn's output.

ACP carries these updates as `session/update` with `sessionUpdate: "context_compaction"`, an `id`, a `status` (`in_progress`, `completed`, `cancelled`, or `failed`), and an `origin` (`automatic`, `manual`, or `provider_overflow`). Running-stage updates are omitted. Operations that settle as no-op or busy after starting end as cancelled. Swift drops updates when no turn is receiving output. These notifications do not change model requests or native conversation history. Durable Swift session event records can store and replay the new event case without changing existing cases.

## Run the proof

Requirements: macOS, Xcode, Swift 6.2 or later, and the XCFramework built from this checkout. From the repository root:

```sh
swift/scripts/build-xcframework.sh
swift test --package-path swift --no-parallel --filter CompactionTests
swift/scripts/test-compaction-consumer.sh
```

The consumer script creates a separate Swift package, imports the public `LibFx` product, builds a release executable, and runs it. It reuses [CompactionProbe.swift](Tests/LibFxTests/CompactionProbe.swift) without `@testable`, SPI, or an injected engine transport. It fails if the executable exits unsuccessfully or writes to stderr.

The fixture replaces the model service through the public `FxHTTPClient` API. It uses `FxCustomProvider.ModelCapabilities(contextWindow: 8192, maxOutputTokens: 1024)` and a 3000-token trigger, below the default 5734-token threshold. Swift tests also run the default trigger and explicit `.percent(80)` setting. There are no live model calls or credentials. Each initial turn calls one static host tool and receives a long final reply. The tool exchange provides intermediate work for the compactor's model to summarize.

The probe checks that:

1. Each compaction emits one started/completed pair before the next reply content.
2. The native runtime sends a compaction-notes request to the configured model through the HTTP callback.
3. The SQLite journal saves a `history_replaced` event containing a `compacted_summary`, a nonzero removed-turn count, and the model's unique note.
4. The next conversation request has less context text than the largest earlier request.
5. A new prompt succeeds with the model's note in its request.
6. An exported kernel checkpoint contains the compacted state.
7. After both the engine and SQLite store close, a new store and engine recover the note from disk and answer another prompt.

The unique note appears only in the model's compaction response. User prompts, tool results, and ordinary replies do not contain it. The fixture rejects continuation requests that omit it and checks that neither continuation nor recovery generates a new note.

`checkpointAfterBytes` is `nil` throughout this run. The probe also checks that no automatic journal snapshot exists before exporting a checkpoint. Journal snapshot creation therefore cannot satisfy the compaction assertions.

The consumer enables the existing `context_compaction` trace through `FX_TRACE_LOG` and checks the native request token count against the 3000-token threshold. It also checks that requests rebuilt after compaction use fewer than 3000 tokens. Trace files contain only fixture data and are removed with the temporary package. Native embeddings honor the same trace environment variables as the CLI.

## Scope of the evidence

The exercised native path is `src/acp/prompt.zig` → `src/core/agent/runtime/orchestrator.zig` → `src/core/compactor/compactor.zig`. The compactor's model caller uses the same provider transport as ordinary conversation requests. The journal records the replaced context, and a new native engine restores it through the persistence API.

The proof covers local C ABI execution, model-request routing, summary persistence, reduced context, continuation, and SQLite reopen. It does not measure a live model's summary quality, exercise process termination during a write, or qualify other architectures. CI is a separate gate.

Compaction does not require a model request for every conversation shape. When there is no intermediate work to summarize, the core can compact messages and final replies without requesting notes. This fixture includes a tool exchange specifically to exercise the model-generated summary path.
