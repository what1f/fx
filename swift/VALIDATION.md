# Swift SDK validation

This is an implementation milestone, not full libfx parity or a release qualification.

## Environment

Local checks ran on macOS arm64 with Swift 6.4, Zig 0.17.0, and Node.js 25.9.0. Upstream SDK CI requires Node.js 24; the local Node runs do not replace that gate. The C library targets macOS 14. Runtime qualification for x86_64 remains pending.

## Implemented proof

`swift test --package-path swift` passed 82 tests against the generated XCFramework. `swift/scripts/test-consumer.sh` also built and ran an independent Release consumer with no unsafe linker flags. The tests cover:

- Fragmented UTF-8 frames, host requests, cancellation, oversized frames, and pending requests during close.
- HTTP response status, Unicode, bounded chunks, invalid responses, and cancellation before headers.
- Seventy retained closed engines without native slot exhaustion, streaming and results, checkpoint exclusion during other state transitions, and old-turn control isolation.
- One retry after a pre-header network failure; no replay after cancellation or body failure.
- Model effort and fast options reaching provider requests, plus unsupported effort rejection.
- Custom provider configuration and real core requests, credentials scoped by endpoint and session, anonymous services, rejected keys, invalid credentials, cancellation during credential lookup, and mixed slash, quote, and Unicode error redaction.
- Codex and Grok through the real core, JWT routing metadata, 401 and pre-expiry refresh, token omission and malformed rotation, form encoding, shared refresh and per-session saves, late rejection, host locks, account isolation, save failure recovery, and cancellation of one or all refresh waiters and a save callback.
- Prompt image bytes traveling through attachments, and structured tool result images and error flags.
- Journal conversation restore, stale-writer fencing, retry deduplication, malformed and future records, and persistence failure before a model request.
- Resuming a journal stopped after its pre-request progress record, restoring history after a saved journal snapshot, and waiting for a snapshot save during close.
- Runtime observation ordering and scope, content opt-in, observer error isolation, successful journal commits, and fencing errors.
- SQLite reopen, binary and empty records, retry keys after pruning, competing writers, snapshot transaction rollback, and future-schema rejection.
- Automatic snapshots across SQLite reopen and a later journal tail, plus a failed save that preserves records and retries after the next turn.
- Stable turn IDs, completed retry deduplication, repeated yields across a disk snapshot, replacing an interrupted turn, invalid IDs and deadlines, and cancellation of a task awaiting a turn result.
- Handoff during a tool call, preservation of journal progress and pending steering, rejection of later prompts, resumes, and snapshot saves, persistence requirements, and stale-turn isolation.
- Follow-up acceptance and ordered automatic turns, idle acceptance, explicit recovery of held inputs, independent current inputs, cancellation of one waiter, close and failed storage rejecting both waiters, tool turn IDs, and snapshots deferred without errors until queued inputs are placed.

The initial agent/session implementation adds 12 native tests. They cover durable ordered intake, historical message-ID deduplication, per-reader replay, scoped queued cancellation, graceful close, competing local connections and agents, stale-owner rejection, snapshot rollback, wrong-agent rejection, and persisted tool context and public identities. Two recovery fixtures distinguish a started input with no core dispatch from a completed core turn with no saved host result. The former runs normally; the latter returns `.unknown` without another model call. These fixtures simulate those boundaries in process; they are not SIGKILL qualification of the new session store.

`FxSessionStore` stores intake, events, and core journals in one SQLite database. Ownership checks and writes share an immediate transaction, following [SQLite's documented isolation rules](https://www.sqlite.org/isolation.html). A separate local file lock covers the worker lifetime. The Release consumer also imports the public agent/session API, runs a durable turn, replays its events, and checks historical-ID deduplication. Full upstream agent/session coverage, cross-process session-worker termination, steering, deadlines, and checkpoint export remain pending.

The independent Release consumer also exercised the default Foundation client against a local HTTP server. It completed an authenticated custom-provider turn, rejected authenticated and token-body 307 redirects, and verified that the redirect target received no request. The Release consumer also used the public subscription API for a Grok turn. The custom-provider conformance scenario compared JavaScript and Swift engine requests, host-tool round trips, missing credentials, rejected keys, and plain and JSON-escaped credential redaction. The full upstream custom-provider file still requires agent/session driver support and qualification.

The subscription conformance check reads the engine sections from the upstream provider files and runs their assertions unchanged against JavaScript and Swift. It selects Codex sections 1 through 3 and Grok sections 1 through 4, before the durable-session marker. It changes the SDK import and native artifact path only and removes unused agent imports. The selected assertions cover request headers, model traffic, expiry and rejection refresh, saved credentials, secret isolation, and Grok account changes. Later agent/session, shared-agent, and options sections remain unqualified by this check. Swift-native tests separately exercise shared refresh and the host lock contract.

A full regression run exposed two cancellation races. A cancelled result waiter could receive an RPC error before its post-await cancellation check, and explicit turn cancellation could settle as the core's `Cancelled` RPC error. Result waiting now checks cancellation on both success and failure; an explicitly cancelled active turn normalizes that core error to `.cancelled` after checking journal failures. The native result-waiter test repeats the real-core interaction 20 times.

The following upstream tests passed through the Swift test driver with their assertions unchanged:

```sh
node --no-warnings --loader ./swift/Tests/Conformance/loader.mjs sdk/tests/test-host-tools.mjs native
node --no-warnings --loader ./swift/Tests/Conformance/loader.mjs sdk/tests/test-agent-step-limit.mjs native
node --no-warnings --loader ./swift/Tests/Conformance/loader.mjs sdk/tests/test-host-tool-cancel.mjs native
node --no-warnings --loader ./swift/Tests/Conformance/loader.mjs sdk/tests/test-agent-steering.mjs native
node --no-warnings --loader ./swift/Tests/Conformance/loader.mjs sdk/tests/test-agent-steering.mjs native --hooks
node --no-warnings --loader ./swift/Tests/Conformance/loader.mjs sdk/tests/test-list-models.mjs
```

These five files, including a second steering run with hooks enabled, pass through the Swift driver. Both surface labels in the model-discovery fixture are redirected to Swift; this does not qualify a browser runtime. The adapter translates typed Swift errors to JavaScript error classes for those assertions. `test-agent-effort.mjs` passed its valid and unsupported capability cases, then stopped on a JavaScript error-class assertion. `test-agent-images.mjs` passed initial image transport cases, then stopped at the unimplemented resize hook. Neither file is counted as passed.

Additional executable checks passed:

- `smoke.mjs`: local HTTP server, Unicode and reasoning, host tool execution, checkpoint restore, and repeated close.
- `checkpoint-interoperability.mjs`: JS to Swift to JS, preserving earlier turns and image bytes.
- `journal-interoperability.mjs`: Swift to JS to Swift using one persistence store.
- `recovery.mjs`: journal truncated at tool intent; ambiguous writes remain stopped by default, while explicit rerun preserves execution ID.
- `turn-control.mjs`: withdrawal while a tool is running, plus controls from an old turn leaving a new turn unaffected.
- `observation.mjs`: JavaScript and Swift comparison of event kinds, scopes, parallel tool causality, tool failure, content opt-in, and committed journal cursors.
- `automatic-checkpoint.mjs`: Swift to JS to Swift using automatic journal snapshots and excluding covered journal prefixes on load.
- `sqlite-crash.mjs`: actual driver SIGKILL after a saved snapshot and after an external write whose result was not returned; recovery preserves earlier history and skips the ambiguous write.
- `sqlite-fencing.mjs`: two core processes with one database; the stale writer stops before its model request.
- `turn-identity.mjs`: reference JavaScript and Swift behavior, plus alternating implementations across yielded snapshots; preserves original input and completed tool results, resumes the original ID, and deduplicates retries of the most recently completed ID.
- `handoff.mjs`: Swift and JavaScript in both source and target roles; the source makes no later journal writes or automatic snapshots, the target receives the pending steer and skips the ambiguous write, and the source's turn-end observation marks the handoff.
- `follow-up.mjs`: reference JavaScript and Swift automatic queues, durable acceptance and exactly one placement per input, plus recovery in both source and target roles; held inputs wait for explicit resume while current inputs run independently.

`node swift/Tests/Conformance/run.mjs` reruns the 20 selected upstream and interoperability checks and records results under `.build/conformance-results.json`. It does not run every inventory entry.

`swift test --package-path swift --sanitize=thread` passed all 82 Swift tests without a sanitizer warning. The first focused run reported concurrent access to the native handle during shutdown. The transport now waits for the [Dispatch source's cancellation handler](https://developer.apple.com/documentation/dispatch/dispatch_source_set_cancel_handler) and destroys the handle on its actor. This check instruments Swift code; the precompiled Zig archive is not instrumented. The Swift CI workflow repeats the check after conformance testing.

`zig build`, the freshly built CLI's help command, Zig formatting checks for the changed files, and the public-surface audit passed. The help command proves startup only; it is not real-model agent evidence. See [C bridge validation](BRIDGE-VALIDATION.md) for the C consumer and original Node backend regression checks.

## Required remaining gates

- Full classified upstream test coverage, including complete provider agent/session suites and sign-in helpers, durable image handoff, parent and tool-local observation scopes, image processing and storage, and full durable agent and session behavior.
- Additional storage integrations, durability barriers under slow storage, and systematic termination across all effect boundaries.
- Address Sanitizer, instrumentation of the native core, and concurrency stress tests, especially cancellation during preparation and storage.
- Runtime proof for x86_64 and final consumer validation against the release artifact.
- Available-credential real-model integration and exact-commit CI, including macOS arm64.
- Repository final ship gate before any release-readiness claim.
