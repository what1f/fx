# Swift SDK validation

This is an implementation milestone, not full libfx parity or a release qualification.

## Environment

Local checks ran on macOS arm64 with Swift 6.4, Zig 0.17.0, and Node.js 25.9.0. Upstream SDK CI requires Node.js 24; the local Node runs do not replace that gate. The C library targets macOS 14. Runtime qualification for x86_64 remains pending.

## Implemented proof

`swift test --package-path swift` passed 20 tests against the generated XCFramework. `swift/scripts/test-consumer.sh` also built and ran an independent Release consumer with no unsafe linker flags. The tests cover:

- Fragmented UTF-8 frames, host requests, cancellation, oversized frames, and pending requests during close.
- HTTP response status, Unicode, bounded chunks, invalid responses, and cancellation before headers.
- Seventy retained closed engines without native slot exhaustion, streaming and results, and checkpoint exclusion during other state transitions.
- Model effort and fast options reaching provider requests, plus unsupported effort rejection.
- Prompt image bytes traveling through attachments, and structured tool result images and error flags.
- Journal conversation restore, stale-writer fencing, retry deduplication, malformed and future records, and persistence failure before a model request.
- Resuming a journal stopped after its pre-request progress record.

The following upstream tests passed through the Swift test driver with their assertions unchanged:

```sh
node --no-warnings --loader ./swift/Tests/Conformance/loader.mjs sdk/tests/test-host-tools.mjs native
node --no-warnings --loader ./swift/Tests/Conformance/loader.mjs sdk/tests/test-agent-step-limit.mjs native
node --no-warnings --loader ./swift/Tests/Conformance/loader.mjs sdk/tests/test-host-tool-cancel.mjs native
```

All three passed again after the journal and XCFramework packaging changes. `test-agent-effort.mjs` passed its valid and unsupported capability cases, then stopped on a JavaScript error-class assertion. `test-agent-images.mjs` passed initial image transport cases, then stopped at the unimplemented resize hook. Neither file is counted as passed.

Additional executable checks passed:

- `smoke.mjs`: local HTTP server, Unicode and reasoning, host tool execution, checkpoint restore, and repeated close.
- `checkpoint-interoperability.mjs`: JS to Swift to JS, preserving earlier turns and image bytes.
- `journal-interoperability.mjs`: Swift to JS to Swift using one persistence store.
- `recovery.mjs`: journal truncated at tool intent; ambiguous writes remain stopped by default, while explicit rerun preserves execution ID.

`node swift/Tests/Conformance/run.mjs` reruns the selected upstream and interoperability checks and records results under `.build/conformance-results.json`. It does not run every inventory entry.

`zig build`, the freshly built CLI's help command, Zig formatting checks for the changed files, and the public-surface audit passed. The help command proves startup only; it is not real-model agent evidence. See [C bridge validation](BRIDGE-VALIDATION.md) for the C consumer and original Node backend regression checks.

## Required remaining gates

- Full classified upstream test coverage, including the SDK's providers, steering, hooks, model listing, image processing and storage, and durable agent and session behavior.
- Persistent storage adapters, automatic checkpoints, durability barriers under slow storage, and process termination at effect boundaries.
- Sanitizers and concurrency stress tests, especially cancellation during preparation and storage.
- Runtime proof for x86_64 and final consumer validation against the release artifact.
- Available-credential real-model integration and exact-commit CI, including macOS arm64.
- Repository final ship gate before any release-readiness claim.
