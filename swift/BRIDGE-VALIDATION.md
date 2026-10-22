# C bridge validation

This record covers the C ABI and the extraction of the native transport from the Node-API entry point. It does not establish Swift SDK feature parity or release readiness.

## Implementation boundary

`src/native_core_runtime.zig` owns the shared queues, readiness socket, attachment table, host-fetch state machine, ACP server composition, and runtime thread. Both `src/napi_core_main.zig` and `src/c_core_main.zig` use this implementation. The C entry point adds JSON option validation and C-compatible buffer and handle operations. It does not implement another agent loop.

The static archive bundles Zig's compiler runtime. A link test with Apple's C compiler exposed unresolved float128 helper symbols before this setting was added.

The C entry point preserves the embedding host's signal stacks. It disables Zig's automatic alternate-stack installation on native threads. A Swift Address Sanitizer run exposed the previous conflict: native thread setup replaced ASan's mapped stack with a 256 KiB thread-local buffer, and sanitizer teardown attempted to unmap that buffer. One isolated real-core test reproduced the failure. With newly built archives, that test and all 104 Swift tests passed under ASan. This does not establish instruction-level sanitizer coverage of the Zig archive.

## Ownership review

- Input bytes are copied before the C call returns.
- Returned output, attachment, fetch, and error buffers belong to the caller. Release each with `fx_buffer_free`.
- Null input with a nonzero length is rejected. Null input with zero length represents empty data.
- The readiness descriptor is borrowed. Stop watching it before destroying the core, and do not close it separately.
- The host serializes calls on each core and stops host network tasks before destruction.
- Closing input also closes output delivery and wakes blocked writers. Repeated close and fetch-abort calls are allowed.
- Destruction closes input, shuts down fetch, joins the runtime thread, and then releases queues, attachments, options, and the runtime slot.
- A failed fetch-request copy leaves the request pending. A successful take transfers copied metadata and body together.
- Attachment ID zero and duplicate pending IDs are rejected.

## Local evidence

Tests ran on macOS arm64 with Zig 0.17.0, Node.js 25.9.0, and Apple's C compiler. Upstream specifies Node.js 24 for its SDK CI, so these local runs do not replace that gate.

The following upstream native tests passed after the extraction:

```sh
node sdk/tests/test-native-core.mjs
node sdk/tests/test-native-core-misuse.mjs
node sdk/tests/test-native-core-cancel.mjs
node sdk/tests/test-native-core-image-framing.mjs
node sdk/tests/test-native-core-ready.mjs
node sdk/tests/test-host-tools.mjs native
node sdk/tests/test-host-tool-cancel.mjs native
```

These exercised initialization, checkpoint generation, graceful close, invalid arguments, stale fetch handles, logical-consumption identity, backpressure, cancellation, accepted image framing, readiness notification, host-tool execution, and host-tool cancellation before and after settlement.

`swift/scripts/test-c-abi.sh` compiles and runs a C consumer of the static archive. It checks 12 initialize/session-create/teardown cycles, invalid input buffers, empty input, attachment ownership checks, stale fetch operations, repeated abort and close, and 80 failed creates followed by a successful create. The latter checks that validation failures release runtime slots.

The host-target archive passed this C consumer. The final macOS 14 archive also built and passed the consumer without deployment-target linker warnings:

```sh
zig build libfx-c -Dtarget=aarch64-macos.14.0
LIBFX_SKIP_BUILD=1 swift/scripts/test-c-abi.sh
```

Observed output:

```text
C ABI smoke passed: initialize, session creation, repeated teardown, invalid options
```

## Remaining proof

The initial journal attempt required an unused Wasm fixture. The conformance loader now skips that asset for native-to-native runs, and the complete 77-case journal owner passes locally through Swift. The original assertions remain in place. Current native lifecycle and concurrency tests also pass in normal, Address Sanitizer and Thread Sanitizer builds; see `VALIDATION.md` and `MIGRATION.md` for their scope.

The normal conformance runner streams output so CI records the time of each completed case. It preserves the 60-second process deadline, reports exit status, signal and timeout diagnostics, and saves results after each file. CI uploads the results even when a later check fails. These diagnostics help distinguish an aggregate deadline from a stalled case; they do not establish that either caused an earlier failure.

The user requested local-only validation on 2026-10-22. Final local runtime and available-credential real-model integration remain required; CI is excluded from this task's acceptance. Local passes do not explain the historical CI journal deadline failure.
