# libfx-swift migration plan

Status: implementation in progress. No Swift capability is qualified until its proof is recorded below.

## Target

Build a Swift package that runs the existing fx Zig agent core in process through a C ABI. Keep model orchestration, compaction, journal formats, and recovery decisions in their current Zig owners. Provide Swift interfaces for engines, turns, tools, streaming, sessions, and persistence.

The first qualification platform is macOS arm64 with Swift 6.2 or later. Linux and other Apple targets require their own build and runtime evidence. iOS support is not implied by a macOS build.

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

Requirements updated on 2026-10-22: implement the full current libfx feature set with an idiomatic Swift API. Swift design quality and functional coverage are separate acceptance conditions. Passing upstream tests does not waive the design requirements, and passing a subset does not complete the goal. Do not reduce the scope without the user's agreement. Apply the user's latest AGENTS.md instructions throughout implementation and final review.

- Design the public API for Swift callers. Use Swift naming, value types, enums, structured concurrency, and explicit ownership where each fits. Do not translate TypeScript interfaces line by line.
- Support current libfx functionality through idiomatic Swift operations. API names and shapes may differ; required behavior must have acceptance evidence in the matrix below.
- Exclude historical TypeScript compatibility branches, deprecated API aliases, and JavaScript platform workarounds. Preserve current protocol contracts and persistence compatibility where required.
- Keep the implementation small. Add abstractions only for current behavior, ownership, or a verified test need. Do not add speculative extension systems or compatibility layers.
- Reuse upstream behavioral tests through a thin adapter. The adapter must call the Swift SDK for the behavior under test. Add Swift-native tests for concurrency, cancellation, memory ownership, and package integration.
- Do not complete the goal while required functionality or verification remains missing. Record unsupported scope and unverified gates explicitly.
- Prefer mature, widely used libraries and tools for supporting capabilities. Research comparable implementations and known solutions before introducing a new supporting abstraction; verify that each adopted approach fits the current repository.
- Use pnpm for JavaScript and TypeScript dependencies and test tooling.
- Place research checkouts under `~/github.com/{owner}/{repo}`. Use the built-in browser or the user's Chrome connection for browser operations; do not use ego-lite.
- Keep any user-facing examples, errors, and interface text concise and free of internal implementation details. Review localization when interface text changes; do not introduce hard-coded interface copy.
- Keep explanations direct and use simple, precise language. For interface work, prefer clear layout and standard controls over explanatory copy, including in prototypes and design proposals.
- Follow ASD-STE100 principles in explanations, targeting at least 80% alignment. For direct human conversation, support the user's English learning with natural American English and Chinese notes for difficult terms when useful. Respect an explicit request to use Chinese. Treat possible voice-transcription errors according to context.

Before marking this goal complete, record a final acceptance review that confirms:

1. Every current libfx capability has Swift implementation and acceptance evidence. Any missing capability keeps the goal active unless the user agrees to change the scope.
2. The public API follows Swift conventions. The review checks naming, types, concurrency, cancellation, and ownership, and rejects literal TypeScript ports, historical compatibility branches, and speculative abstractions.
3. Upstream behavioral assertions exercise the actual Swift implementation through a thin adapter. Native Swift tests and a separate package consumer verify the behavior that JavaScript tests cannot establish.
4. Required local runtime checks and CI pass for the final commit, including macOS arm64. The report distinguishes verified behavior from remaining limits.

## Contracts

C calls report errors without unwinding across the ABI. Buffers have explicit lengths, and their producer supplies the matching free operation. Handles have a documented close and destroy order. No callback may retain an unowned Swift object. A single owner serializes runtime access and shutdown.

Swift values crossing concurrency boundaries are Sendable. Cancellation must reach model transport and tool tasks. Closing rejects pending requests, terminates event streams, stops effects, and joins runtime work. Streaming has bounded buffering with an explicit overflow failure.

Persistence preserves ordered append, expected cursor checks, durability barriers, version errors, and uncertain tool outcomes. Recovery must not blindly repeat a write. Checkpoint compatibility with JavaScript is a separate acceptance gate from ordinary Swift save and load.

## Functional acceptance matrix

| Area | Upstream test owners | Required Swift proof | Status |
| --- | --- | --- | --- |
| Startup, configuration, model catalog | test-minimal-api, test-agent-bootstrap, test-list-models | Equivalent validation and isolation | Partial: startup, model options, explicit model discovery, validated supplied Gateway catalogs with vision/reasoning and endpoint-isolation proof, and the complete upstream bootstrap file; full minimal API coverage pending |
| Stream and results | test-core-output, test-native-core-stream | Deltas, finish reasons, usage, provider errors | Partial: Unicode, text, reasoning and result smoke |
| Tools | test-host-tools, test-tool-contract, test-agent-tool-start, test-agent-reserved-tool-names, test-agent-provider-tools | Advertisements, calls, bounded display input, results, errors, parallel admission | Implemented for these owners: complete host-tools, tool-contract, provider search and reserved-name files; tool-start assertions with canonical preview-oracle normalization; native read-overlap and writer-barrier tests with model-order results and public context identity; returned, described and localized tool errors reach the model with nonempty text; Swift boundary, executor and persisted-event tests |
| Permission requests | test-core-output and SDK control-message contract | Typed host decisions, default denial, cancellation and session isolation | Partial: public typed callback, offered-option validation, scoped cancellation, bounded display input, journal and durable-lease checks, and scripted RPC tests; upstream runtime-factory fixture and real native permission-trigger evidence pending; host tools authorize their own effects |
| Cancellation and shutdown | test-core-cancel, test-host-tool-cancel, test-native-host-tool-late-settle | No late callbacks, deadlocks, or stranded requests | Partial: upstream host-tool cancellation and native lifecycle tests |
| Steering | test-agent-steering | Interrupt, wait, join, withdraw, handoff | Partial: upstream engine steering, withdrawal, old-turn isolation, persisted handoff and queued follow-ups across Swift/JS engines; seven selected durable steering scenarios, including image handoff and cancellation, plus two worker SIGKILL boundaries; full durable suite pending |
| Model options and providers | test-agent-effort, test-agent-fast, test-agent-ultrafast-options, test-agent-custom, test-agent-codex, test-agent-grok | Matching request behavior and validation | Partial: complete upstream effort, fast, ultrafast, custom-provider, Codex and Grok files, default Gateway selection and resolved checkpoint metadata, shared rotations and host locks, error redaction and Foundation redirect isolation; sign-in helpers and remaining model-option suites pending |
| Images and limits | test-agent-images, test-instruction-limits, test-native-core-image-framing | Input, tool images, UTF-8, frame bounds | Partial: binary input, asynchronous host image preparation, named image storage and final size checks; the upstream input/preparation and checkpoint sections pass through Swift with their original assertions, including concurrent exports, prompt/export ordering, callback reentrancy and restore bounds. Full image-owner qualification, including remaining admission cases, is pending |
| Journal and checkpoints | test-journal, test-checkpoint | Swift and JS restore in both directions | Implemented for these owners: bidirectional checkpoint and journal proof, explicit and automatic snapshot save and restore, read-only session exports and new-agent seeds with images, metadata mismatch notifications and five upstream durable checkpoint scenarios; all 77 upstream native/native journal cases pass, including named prompt/tool images, count/byte windows, large checkpoints and recovery beyond 4096 images; native tests verify image cancellation, SQLite recovery and session isolation; saved-reply replay, original store error identity and typed load rejection verified; all five upstream checkpoint scenarios pass with original assertions for text, reasoning, provider-terminal tools and images |
| Durable sessions | test-durable, test-durable-core, test-durable-provider-crash, test-world-persistence | Queue, deduplication, crash recovery, fencing | Partial: SQLite persistence, stable turn IDs, cooperative yield and repeated resume across Swift/JS snapshots, latest completed ID deduplication, cross-process writer fencing and two SIGKILL recovery boundaries; agent/session intake, event replay, local ownership, ordered workers, resumable turn views and three worker SIGKILL boundaries tested; full agent/session suites pending |
| Delivery scheduling | test-durable | Safe yield, active cutoff, bounded retries, one logical turn | Partial: local duration policy, checkpointed yields, safe tool reruns, ambiguous-write suppression, persistent step cutoff counts, five unchanged upstream selections, and cooperative preparation deadlines with retained intake and explicit retry; external queue delivery and slow-storage stress pending |
| Hooks | test-hooks | Event scopes and observation isolation | Implemented for this owner: full upstream assertions through Swift, runtime and journal observations, content opt-in, error isolation, JS comparison and hooks-enabled steering; parent identity projection and tool-local MCP scopes with native child-engine and durable-session proof; typed input-wait helpers with per-event UTF-8 budgets, collection limits, cancellation and result preservation have native and Release-consumer proof; cross-process input waits and child identity have JS/Swift differential proof, including original object/error identity, observer failures and late cancellation; cross-process MCP spans, correlation and cancellation have differential proof; standalone Swift helper cancellation, child options, original effect identity and already-cancelled scopes have upstream and differential proof |
| Request diagnostics | test-agent-request-context, test-agent-transport-retry | Request identity, privacy, retry counts, latency and streaming activity | Implemented for these owners: public Swift metadata and sampled body progress, eight native tests, Release consumer, and both complete upstream files; cancellation awaited from the retry observer prevents another request |
| MCP and skills | test-mcp-adapter, test-skills-adapter | Host adapters and cancellation | Partial: typed skills and local YAML files; optional MCP module using the official Swift SDK, bounded catalogs and context, cancellation, images and errors. Upstream skills records/disk and MCP stdio/HTTP native modes pass; native MCP spans retain remote identities and correlation, contain observer errors, and end once on cancellation; full upstream hooks assertions pass through Swift |
| Swift package | Swift native tests and clean consumer | Import, link, release build, lifecycle and concurrency | Partial: XCFramework and independent release consumer on arm64; CI pending |

Image persistence verification (2026-10-22): normal conformance passes 64/64 runner entries, including all 77 journal cases in one invocation. This replaces eight journal selection entries with the complete owner. Native tests pass 202 tests, including image-store cancellation, SQLite reopening, session isolation and stale-owner fencing. All native tests and the 29 newly selected journal cases pass under Address Sanitizer and Thread Sanitizer. The independent Release consumer verifies the public image protocol, image window and SQLite recovery. Normal runtime smoke and session checkpoint interoperability pass after restoring the normal driver build. Zig archive internals are not fully sanitizer-instrumented.

CI run 39720143588 failed two durable steering cases: a queued steer missed the next request, and a cancelled turn returned `end_turn`. A new native regression reproduces missed steering against the previous implementation without a fixed delay. Local steering and cancellation now wake the owning worker and await its next storage check; remote workers retain polling. The regression and both failing upstream cases pass after the fix under Address Sanitizer and Thread Sanitizer. Normal conformance passes 65/65 entries, including the complete checkpoint owner. Final native sanitizer runs pass 204 tests. Exact-final-commit CI is still required. The earlier isolated Thread Sanitizer delivery-cancellation failure remains unexplained.

The complete upstream hooks file passes with its assertions retained. The injected-runtime descendant/authority block runs through the production Swift engine and RPC reader using package-only transport injection. Both standalone helper fixtures now use actual Swift tool observation and child options. The loader awaits frame delivery and helper cancellation acknowledgements before the original assertions; it also closes the added foreign resources. The bridge supplies omitted wire metadata, selected-model handshake metadata, already-initialized MCP fixture envelopes, and JavaScript-only callback validation. Swift owns engine dispatch, scope authority, input waits, MCP spans and terminal states. The separate helper comparison checks already-cancelled scopes, late cyclic result identity, original error identity and effect call counts. This qualifies the hooks owner, not the remaining migration matrix.

Image preparation verification (2026-10-22): `FxConfiguration.prepareImage` runs a cancellable asynchronous host callback before final image admission and storage. The original reference is retained; prepared bytes and format are used for model requests and persisted images. Thirteen native image tests cover large inputs, final limits, original errors, cancellation, close, durable intake and recovery without preparing saved bytes again. Normal conformance passes 66/66 runner entries; 209 native tests and the upstream input/preparation section pass under Address Sanitizer and Thread Sanitizer. The independent Release consumer verifies public preparation with a 5 MiB input and SQLite recovery. The complete image owner remains partial; the loader selects only its input/preparation section and retains those assertions.

Checkpoint concurrency verification (2026-10-22): Swift serializes exports through attachment consumption, removes cancelled queued calls, rejects pending calls on close and delays a later prompt until the current export finishes. Queued exports recheck turn state before sending. Native tests cover 32 concurrent exports, prompt/export ordering, cancellation, close and explicit restore size bounds. The upstream image prefix now includes catalog diagnostics, image restore, 16 concurrent exports, prompt/export ordering and eight reentrant callback exports with its original assertions. Normal conformance passes 66/66 entries; 213 native tests and this expanded image prefix pass under Address Sanitizer and Thread Sanitizer. An independent Release consumer verifies 16 concurrent image exports. Full image-owner qualification remains pending at synchronous input admission and later cases.

CI run 39723162395 failed in Address Sanitizer with `TooManyRuntimes` while the main and MCP test modules ran together. Its Swift 6.2 runner executes both modules in one test process; the local Swift 6.4 runner uses separate processes. CI and the documented test command now pass `--no-parallel` explicitly to avoid unrelated cases exhausting the shared 64-slot runtime. All 213 native tests pass locally with this flag in normal, Address Sanitizer and Thread Sanitizer runs; the normal driver smoke passes after restoring its build. Parallel operations inside concurrency tests remain enabled. Exact-head CI remains pending. This harness change does not expand runtime capacity or establish a fix for the earlier isolated delivery-cancellation failure.

A generated inventory records every upstream SDK test file. Each test must be classified as reusable, adapted, or platform-specific with a reason. Platform-specific exclusions include Node/Wasm loading, npm packaging, browser terminal rendering, and Vercel deployment packaging. These exclusions do not silently remove engine behavior.

## Verification strategy

Run the unchanged Node backend tests after shared-runtime changes. Run the reusable upstream scenarios through both backends against the same scripted HTTP services. Compare semantic events and provider requests after normalizing random identifiers and timestamps. Preserve causal ordering without imposing a total order on concurrent tools.

The JavaScript test bridge must wait for process and output-stream closure and reject nonzero exits, unexpected signals and stderr on normal operations. Synthetic driver fault injection verifies this gate separately from SDK behavior; intentional crash tests retain their explicit termination assertions.

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
