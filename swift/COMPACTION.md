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
let configuration = FxConfiguration(provider: .custom(provider), model: "local-model")
```

Use the model's actual limits in a host application. The small limits below belong to a deterministic fixture. No compaction threshold override is needed for this proof.

## Run the proof

Requirements: macOS, Xcode, Swift 6.2 or later, and the XCFramework built from this checkout. From the repository root:

```sh
swift/scripts/build-xcframework.sh
swift test --package-path swift --no-parallel --filter CompactionTests
swift/scripts/test-compaction-consumer.sh
```

The consumer script creates a separate Swift package, imports the public `LibFx` product, builds a release executable, and runs it. It reuses [CompactionProbe.swift](Tests/LibFxTests/CompactionProbe.swift) without `@testable`, SPI, or an injected engine transport. It fails if the executable exits unsuccessfully or writes to stderr.

The fixture replaces the model service through the public `FxHTTPClient` API. It uses `FxCustomProvider.ModelCapabilities(contextWindow: 8192, maxOutputTokens: 1024)` and the default 80% trigger. There are no live model calls or credentials. Each initial turn calls one static host tool and receives a long final reply. The tool exchange provides intermediate work for the compactor's model to summarize.

The probe checks that:

1. The native runtime sends a compaction-notes request to the configured model through the HTTP callback.
2. The SQLite journal saves a `history_replaced` event containing a `compacted_summary`, a nonzero removed-turn count, and the model's unique note.
3. The next conversation request has less context text than the largest earlier request.
4. A new prompt succeeds with the model's note in its request.
5. An exported kernel checkpoint contains the compacted state.
6. After both the engine and SQLite store close, a new store and engine recover the note from disk and answer another prompt.

The unique note appears only in the model's compaction response. User prompts, tool results, and ordinary replies do not contain it. The fixture rejects continuation requests that omit it and checks that neither continuation nor recovery generates a new note.

`checkpointAfterBytes` is `nil` throughout this run. The probe also checks that no automatic journal snapshot exists before exporting a checkpoint. Journal snapshot creation therefore cannot satisfy the compaction assertions.

## Scope of the evidence

The exercised native path is `src/acp/prompt.zig` → `src/core/agent/runtime/orchestrator.zig` → `src/core/compactor/compactor.zig`. The compactor's model caller uses the same provider transport as ordinary conversation requests. The journal records the replaced context, and a new native engine restores it through the persistence API.

The proof covers local C ABI execution, model-request routing, summary persistence, reduced context, continuation, and SQLite reopen. It does not measure a live model's summary quality, exercise process termination during a write, or qualify other architectures. CI is a separate gate.

Compaction does not require a model request for every conversation shape. When there is no intermediate work to summarize, the core can compact messages and final replies without requesting notes. This fixture includes a tool exchange specifically to exercise the model-generated summary path.
