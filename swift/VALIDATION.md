# Swift SDK validation

This is an implementation milestone, not full libfx parity or a release qualification.

## Environment

Local checks ran on macOS arm64 with Swift 6.4, Zig 0.17.0, and Node.js 25.9.0. Upstream SDK CI requires Node.js 24; the local Node runs do not replace that gate. The C library targets macOS 14. Runtime qualification for x86_64 remains pending.

## Implemented proof

`swift test --package-path swift` passed 39 tests against the generated XCFramework. `swift/scripts/test-consumer.sh` also built and ran an independent Release consumer with no unsafe linker flags. The tests cover:

- Fragmented UTF-8 frames, host requests, cancellation, oversized frames, and pending requests during close.
- HTTP response status, Unicode, bounded chunks, invalid responses, and cancellation before headers.
- Seventy retained closed engines without native slot exhaustion, streaming and results, checkpoint exclusion during other state transitions, and old-turn control isolation.
- One retry after a pre-header network failure; no replay after cancellation or body failure.
- Model effort and fast options reaching provider requests, plus unsupported effort rejection.
- Prompt image bytes traveling through attachments, and structured tool result images and error flags.
- Journal conversation restore, stale-writer fencing, retry deduplication, malformed and future records, and persistence failure before a model request.
- Resuming a journal stopped after its pre-request progress record, restoring history after a saved journal snapshot, and waiting for a snapshot save during close.
- Runtime observation ordering and scope, content opt-in, observer error isolation, successful journal commits, and fencing errors.
- SQLite reopen, binary and empty records, retry keys after pruning, competing writers, snapshot transaction rollback, and future-schema rejection.
- Automatic snapshots across SQLite reopen and a later journal tail, plus a failed save that preserves records and retries after the next turn.
- Stable turn IDs, completed retry deduplication, repeated yields across a disk snapshot, replacing an interrupted turn, invalid IDs and deadlines, and cancellation of a task awaiting a turn result.

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

`node swift/Tests/Conformance/run.mjs` reruns the 16 selected upstream and interoperability checks and records results under `.build/conformance-results.json`. It does not run every inventory entry.

`zig build`, the freshly built CLI's help command, Zig formatting checks for the changed files, and the public-surface audit passed. The help command proves startup only; it is not real-model agent evidence. See [C bridge validation](BRIDGE-VALIDATION.md) for the C consumer and original Node backend regression checks.

## Required remaining gates

- Full classified upstream test coverage, including the SDK's providers, follow-ups and handoff, parent and tool-local observation scopes, image processing and storage, and durable agent and session behavior.
- Additional storage integrations, durability barriers under slow storage, and systematic termination across all effect boundaries.
- Sanitizers and concurrency stress tests, especially cancellation during preparation and storage.
- Runtime proof for x86_64 and final consumer validation against the release artifact.
- Available-credential real-model integration and exact-commit CI, including macOS arm64.
- Repository final ship gate before any release-readiness claim.
