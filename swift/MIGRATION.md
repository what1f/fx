# libfx-swift migration plan

Status: implementation in progress. No Swift capability is qualified until its proof is recorded below.

## Target

Build a Swift package that runs the existing fx Zig agent core in process through a C ABI. Keep model orchestration, compaction, journal formats, and recovery decisions in their current Zig owners. Provide Swift interfaces for engines, turns, tools, streaming, sessions, and persistence.

The first qualification platform is macOS arm64 with Swift 6. Linux and other Apple targets require their own build and runtime evidence. iOS support is not implied by a macOS build.

## Architecture

1. Extract the native runtime from the Node-API entry point into a shared Zig owner. Preserve queue limits, attachment limits, fetch cancellation, and shutdown rules.
2. Expose that runtime through a versioned C ABI with opaque handles and explicit byte ownership. The Node backend continues using the same runtime.
3. Implement a Swift transport and JSON-RPC client. Bridge HTTP through Foundation, tools through async closures, and output through asynchronous streams.
4. Provide `FxEngine` for one conversation. Add `FxAgent`, `FxSession`, and durable storage without substituting a JavaScript implementation for Swift behavior.
5. Add a JavaScript test adapter that forwards public operations to a Swift executable. Forward tool requests back to test closures. Preserve upstream assertions and use the actual Swift SDK for all engine behavior.

## Swift design principles

Use typed configuration, events, results, and errors with async/await and AsyncSequence. Keep JSON-RPC and JSON field names internal, except JSON values for tool schemas and dynamic tool inputs. Use actors where mutable state requires serialization. The JavaScript adapter translates API shape and reuses assertions; it must not implement missing Swift behavior. Target the current protocol only. Do not copy historical JavaScript compatibility branches or platform fallbacks.

### Required goal acceptance conditions

These conditions are binding requirements for the active libfx-swift goal. Evaluate completion against both these conditions and the functional acceptance matrix below.

Goal requirement update: the user's Swift design requirements and repository instructions are part of this goal's completion contract. Apply them to all remaining implementation and reviews. Functional parity, Swift API quality, and verification must all pass before the goal can be completed.

The user's Swift requirements are mandatory acceptance criteria: follow Swift best practices, avoid a literal TypeScript port, omit historical TypeScript compatibility logic, and avoid overdesign. Cover current libfx behavior with working Swift functionality and recorded tests. Matching TypeScript API names or shapes is not a completion criterion.

Before completing the goal, review both functional coverage and Swift API design. Passing upstream tests does not waive the Swift design requirements. A missing current libfx capability remains unfinished work; do not redefine it as out of scope without the user's agreement.

Treat the user's current repository instructions as execution requirements throughout this goal. A passing JavaScript conformance suite alone does not establish completion: the Swift implementation must also pass its native ownership, concurrency, recovery, and package-consumer gates.

- Design the public API for Swift callers. Use Swift naming, value types, enums, structured concurrency, and explicit ownership where each fits. Do not translate TypeScript interfaces line by line.
- Support current libfx functionality through idiomatic Swift operations. API names and shapes may differ; required behavior must have acceptance evidence in the matrix below.
- Exclude historical TypeScript compatibility branches, deprecated API aliases, and JavaScript platform workarounds. Preserve current protocol contracts and persistence compatibility where required.
- Keep the implementation small. Add abstractions only for current behavior, ownership, or a verified test need. Do not add speculative extension systems or compatibility layers.
- Reuse upstream behavioral tests through a thin adapter. The adapter must call the Swift SDK for the behavior under test. Add Swift-native tests for concurrency, cancellation, memory ownership, and package integration.
- Do not complete the goal while required functionality or verification remains missing. Record unsupported scope and unverified gates explicitly.
- Prefer mature, widely used libraries and tools for supporting capabilities. Research comparable implementations and known solutions before introducing a new supporting abstraction; verify that each adopted approach fits the current repository.
- Use pnpm for JavaScript and TypeScript dependencies and test tooling.
- Keep any user-facing examples, errors, and interface text concise and free of internal implementation details. Review localization when interface text changes; do not introduce hard-coded interface copy.
- Keep explanations direct and use simple, precise language. For interface work, prefer clear layout and standard controls over explanatory copy, including in prototypes and design proposals.

## Contracts

C calls report errors without unwinding across the ABI. Buffers have explicit lengths, and their producer supplies the matching free operation. Handles have a documented close and destroy order. No callback may retain an unowned Swift object. A single owner serializes runtime access and shutdown.

Swift values crossing concurrency boundaries are Sendable. Cancellation must reach model transport and tool tasks. Closing rejects pending requests, terminates event streams, stops effects, and joins runtime work. Streaming has bounded buffering with an explicit overflow failure.

Persistence preserves ordered append, expected cursor checks, durability barriers, version errors, and uncertain tool outcomes. Recovery must not blindly repeat a write. Checkpoint compatibility with JavaScript is a separate acceptance gate from ordinary Swift save and load.

## Functional acceptance matrix

| Area | Upstream test owners | Required Swift proof | Status |
| --- | --- | --- | --- |
| Startup, configuration, model catalog | test-minimal-api, test-agent-bootstrap, test-list-models | Equivalent validation and isolation | Partial: startup, model options, explicit model discovery and the complete upstream bootstrap file; full minimal API coverage pending |
| Stream and results | test-core-output, test-native-core-stream | Deltas, finish reasons, usage, provider errors | Partial: Unicode, text, reasoning and result smoke |
| Tools | test-host-tools, test-tool-contract, test-agent-tool-start, test-agent-reserved-tool-names, test-agent-provider-tools | Advertisements, calls, bounded display input, results, errors, parallel admission | Partial: complete host-tools, provider search and reserved-name files; tool-start assertions with canonical preview-oracle normalization; Swift boundary, executor and persisted-event tests; full contract and parallel admission coverage pending |
| Permission requests | test-core-output and SDK control-message contract | Typed host decisions, default denial, cancellation and session isolation | Partial: unhandled core requests are denied and host tools authorize their own effects; public permission callback pending |
| Cancellation and shutdown | test-core-cancel, test-host-tool-cancel, test-native-host-tool-late-settle | No late callbacks, deadlocks, or stranded requests | Partial: upstream host-tool cancellation and native lifecycle tests |
| Steering | test-agent-steering | Interrupt, wait, join, withdraw, handoff | Partial: upstream engine steering, withdrawal, old-turn isolation, persisted handoff and queued follow-ups across Swift/JS engines; seven selected durable steering scenarios, including image handoff and cancellation, plus two worker SIGKILL boundaries; full durable suite pending |
| Model options and providers | test-agent-effort, test-agent-fast, test-agent-ultrafast-options, test-agent-custom, test-agent-codex, test-agent-grok | Matching request behavior and validation | Partial: complete upstream effort, fast, ultrafast, custom-provider, Codex and Grok files, default Gateway selection and resolved checkpoint metadata, shared rotations and host locks, error redaction and Foundation redirect isolation; sign-in helpers and remaining model-option suites pending |
| Images and limits | test-agent-images, test-instruction-limits, test-native-core-image-framing | Input, tool images, UTF-8, frame bounds | Partial: binary input; resizing and image storage pending |
| Journal and checkpoints | test-journal, test-checkpoint | Swift and JS restore in both directions | Partial: bidirectional checkpoint and journal proof, explicit and automatic snapshot save and restore, read-only session exports and new-agent seeds with images, metadata mismatch notifications and five upstream durable checkpoint scenarios; full suite pending |
| Durable sessions | test-durable, test-durable-core, test-durable-provider-crash, test-world-persistence | Queue, deduplication, crash recovery, fencing | Partial: SQLite persistence, stable turn IDs, cooperative yield and repeated resume across Swift/JS snapshots, latest completed ID deduplication, cross-process writer fencing and two SIGKILL recovery boundaries; agent/session intake, event replay, local ownership, ordered workers, resumable turn views and three worker SIGKILL boundaries tested; full agent/session suites pending |
| Delivery scheduling | test-durable | Safe yield, active cutoff, bounded retries, one logical turn | Partial: local duration policy, checkpointed yields, safe tool reruns, ambiguous-write suppression, persistent step cutoff counts, five unchanged upstream selections, and cooperative preparation deadlines with retained intake and explicit retry; external queue delivery and slow-storage stress pending |
| Hooks | test-hooks | Event scopes and observation isolation | Partial: runtime and journal observations, content opt-in, error isolation, JS comparison and hooks-enabled steering; parent and tool-local scopes pending |
| Request diagnostics | test-agent-request-context, test-agent-transport-retry | Request identity, privacy, retry counts, latency and streaming activity | Implemented for these owners: public Swift metadata and sampled body progress, eight native tests, Release consumer, and both complete upstream files; cancellation awaited from the retry observer prevents another request |
| MCP and skills | test-mcp-adapter, test-skills-adapter | Host adapters and cancellation | Pending |
| Swift package | Swift native tests and clean consumer | Import, link, release build, lifecycle and concurrency | Partial: XCFramework and independent release consumer on arm64; CI pending |

A generated inventory records every upstream SDK test file. Each test must be classified as reusable, adapted, or platform-specific with a reason. Platform-specific exclusions include Node/Wasm loading, npm packaging, browser terminal rendering, and Vercel deployment packaging. These exclusions do not silently remove engine behavior.

## Verification strategy

Run the unchanged Node backend tests after shared-runtime changes. Run the reusable upstream scenarios through both backends against the same scripted HTTP services. Compare semantic events and provider requests after normalizing random identifiers and timestamps. Preserve causal ordering without imposing a total order on concurrent tools.

Add Swift-native tests for C buffer ownership, repeated close, object destruction, concurrent cancellation, malformed frames, and resource cleanup. Use Address Sanitizer and Thread Sanitizer in supported builds. Force process exit at tool and journal boundaries; check safe recovery and uncertain write handling.

Run real-model smoke tests only with available credentials. Report unavailable credentials as an unverified gate. Build and run a clean Swift Package consumer using the packaged artifacts. Follow repository CI and runtime qualification before declaring the SDK complete.

## Delivery sequence

- [ ] Shared native runtime and C ABI, with Node regression proof.
- [ ] Swift package, transport, JSON-RPC, lifecycle tests.
- [ ] Engine, streaming, tools, cancellation, initial upstream adapter tests.
- [ ] Providers, images, steering, hooks, context and checkpoints.
- [ ] Durable sessions, crash recovery, MCP and skills adapters.
- [ ] Full classified conformance report, real runtime proof, clean consumer and CI.

A milestone is progress, not completion of the migration. Keep the goal active while required scope remains.
