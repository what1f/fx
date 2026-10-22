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

## Final native contract audit

The production Swift SDK links the C archive in process. `FxEngine.open` creates `NativeTransport`, which calls `fx_core_create`; `src/c_core_main.zig` aliases `native.Runtime`. The Node entry point uses the same runtime. `src/native_core_runtime.zig` owns the queues, readiness channel, attachment and fetch state, provider composition, ACP server and thread. Swift does not start a JavaScript engine or the fx CLI. `FxSwiftDriver` and the JavaScript adapters are test executables, not dependencies of the `LibFx` product.

The audit used baseline `e49ee1c0` and the unchanged universal archive with SHA-256 `d0e682012905e7525c4a6c80e016a5a7fcc09a83704b8dc5cb58b79f3edf3a18`. It checked current source and existing evidence rather than repeating unchanged full suites. The additional security consumer below changes no production behavior.

### Native owner dispositions

Paths in the first column are under `sdk/tests/`. An unchanged original owner running through the Swift adapter proves its retained assertions through Swift. A direct equivalent proves the named contract without claiming execution of the original N-API file.

| Original owner | Contract and evidence |
| --- | --- |
| `test-native-core.mjs` | Original assertions through Swift: initialization, checkpoint, close and wire observations. The adapter projects `runtime.ready` from the first actual Swift wire send after native startup. |
| `test-native-core-cancel.mjs` | Original assertions through Swift: stalled response cancellation and runtime close. |
| `test-native-core-config-isolation.mjs` | Original assertions through Swift: explicit instructions, no workspace context, automatic MCP startup or native billing. Direct raw MCP rejection is also checked below. |
| `test-native-core-env-growth.mjs` | `test-c-env-growth.sh`: 18 isolated processes and 54 model turns with libc environment growth after creation. Node addon loading and `process.env` mechanics are not claimed. |
| `test-native-core-exit-code.mjs` | `test-c-abi.sh`: 180,000 lossless replies above queue capacity after five seconds unread, exit status and blocked-output destruction. Its drain deadline is 20 seconds; the original five-second drain bound remains unqualified. |
| `test-native-core-fetch-failure.mjs` | Original assertions through Swift: an unrelated host AbortError retries once and fails without hanging. |
| `test-native-core-http-cleanup.mjs` | Direct `HTTPDrainTests`, real TCP differential checks and the C fetch consumer qualify delayed EOF, normal cleanup, bounded tails, tool-step ordering and exact consumption identity. Legacy addon disposition wrappers are not reproduced. |
| `test-native-core-image-framing.mjs` | Original assertions through Swift: large tool-image framing, eviction of only older images and rejection before fetch when an image-free request is too large. |
| `test-native-core-misuse.mjs` | Direct C consumers qualify options/input/attachment bounds, absolute paths, live/stale/future fetch handles, backpressure, URL rejection and trace isolation. JavaScript argument counts, getters, proxies, object brands and fractional numbers have no C equivalent. Invalid pointers, double frees and access after destruction violate the documented C ownership contract. |
| `test-native-core-ready.mjs` | Direct C checks qualify 1,000 ordered replies with actual readiness waits, drain-to-empty handling and descriptor cleanup. C borrows the FD; Node transfer-once and Socket events do not apply. |
| `test-native-core-security.mjs` | `test-c-security.sh` qualifies 64 live cores, precise refusal of the 65th, slot reuse, raw stdio MCP rejection and subsequent valid session creation. Failed-create recovery and descriptor checks also run in `test-c-abi.sh`. The original N-API file is not executed through Swift. |
| `test-native-core-stream.mjs` | Original assertions through Swift: split terminal tails, cancellation matching, next-prompt isolation, Unicode streaming and graceful close. |
| `test-native-core-worker-termination.mjs` | Node Worker termination and cleanup hooks do not apply. Direct C destruction and native Swift close/cancel qualify bounded cleanup of blocked work. Swift Task cancellation alone is not automatic engine destruction. |
| `test-native-core-workers.mjs` | Direct Swift lifecycle/concurrency tests qualify isolation and explicit cleanup, including 70 retained closed engine wrappers without retaining runtime slots. Node environments and GC finalizers do not apply. |
| `test-native-core-cancel-before-fetch.mjs` | `NativeTransportTests` qualifies cancellation before HTTP dispatch. `NativeLatePublicationCancellationTests` observes actual native fetch publication after idle abort, then proves the production effect guard prevents HTTP and a follow-up succeeds. Both pass normally and under Swift TSan. Injected addon handles are not copied. |
| `test-native-host-tool-frame-limit.mjs` | `HostToolFrameBoundaryTests` sends the actual RPC ID at exactly 8 MiB and one byte above. Both paths produce explicit tool errors, continue the model turn and reuse the engine without repeating the tool. Normal, ASan and TSan evidence covers both cases; the original JavaScript rich-result encoding fixture is not executed. |
| `test-native-host-tool-late-settle.mjs` | Original assertions through Swift: late completion after cancellation or close sends no further frame, does not replay and causes no unhandled rejection. |

### Buffer, cancellation and lifetime evidence

`fx.h` requires serialized core access, copied input, caller-owned returned buffers released with `fx_buffer_free`, a borrowed readiness FD, and stopped host operations before destruction. `NativeTransport` enforces serialization with its actor, copies and frees C buffers, and waits for DispatchSource cancellation before destroying its handle. The shared runtime closes queues, wakes blocked operations and joins its thread before freeing state. The C consumers exercise null/length combinations, attachment tables, allocation-bound rejection, readiness coalescing, pressure, repeated close and descriptor recovery.

The shared fetch state machine preserves exact handle identity and separates logical consumption from HTTP EOF. `Tests/CABI/fetch.m` drives real catalog and model requests, checks metadata/body separation, stale operations against a newer live handle, 8 MiB plus one byte of backpressure, consumption retained through normal shutdown and revocation on explicit abort.

`CancellationOrderingTests` separately qualifies submission before acknowledgement, acknowledgement before effect abort, and original failure retention when cancellation is rejected. Native output-pressure and journal-barrier tests qualify blocked-reader cleanup and error priority. Ordinary JavaScript turn readers pull the actual Swift iterator one event at a time. The adapter translates fixture callbacks, JavaScript values and error identity; it does not implement model/tool scheduling, persistence or the production agent loop. JavaScript close maps its cancelled-result convention using turn cancellation followed by engine close. Direct Swift tests independently prove the native `FxError.closed` convention.

Permission protocol tests intentionally inject permission requests, as the original output-control fixture does. The minimal kernel disables native tools, and registered host tools do not advertise an approval contract. These tests prove callback selection, denial, cancellation and late-reply fencing, without claiming an unavailable automatic host-tool permission trigger.

`test-c-security.sh` compiles with `-Wall -Wextra -Werror`, uses an isolated temporary home/workspace, rejects nonzero exit or any stderr, and bounds the consumer with an alarm. Both arm64 and translated x86_64 runs exit 0 with empty stderr against the unchanged archive. The C calls directly verify `TooManyRuntimes`, release one slot, create again, reject `session/new` with stdio MCP as `-32602`, and successfully create a normal session on that same core afterward. A separate current-tree arm64 rerun also passes. Rosetta evidence does not establish native Intel hardware behavior.

### Platform owner dispositions

The inventory classifies 28 owners as platform-specific. That classification does not exempt agent behavior inside packaging or UI tests. The following table separates mechanisms from portable contracts; original files are not claimed as executed through Swift unless another record explicitly says so.

| Original owner under `sdk/tests/` | Disposition |
| --- | --- |
| `test-backend-info.mjs` | JS backend selection and Wasm probe/cache mechanisms do not apply to a fixed linked Swift core; native startup failure, ABI checking and cleanup have C/Swift evidence. |
| `test-browser-wasm.mjs` | Browser-suite import wrapper; browser rendering/JSPI do not apply; prompt, cancellation and recovery map to native engine owners. |
| `test-core-browser.mjs` | Browser DOM/terminal rendering and JSPI do not apply; native stream/cancel/steering/checkpoint owners qualify the underlying agent behavior. |
| `test-default-import.mjs` | ESM export shape does not apply; separate Swift products and independent public SwiftPM consumers qualify imports; no original import-time zero-fetch assertion execution is claimed. |
| `test-libfx-benchmark.mjs` | Node/Bun/Pi benchmark programs and thresholds do not apply; no Swift performance equivalence is claimed. |
| `test-libfx-loader.mjs` | Dynamic addon/Wasm selection, JS getters and API shape checks do not apply; C creation failure recovery, Swift ABI guard, bootstrap and lifecycle tests qualify startup and cleanup. |
| `test-linux-abi.py` | GLIBC parser and Linux package baseline do not apply to the macOS XCFramework; Linux runtime support remains unqualified. |
| `test-native-core-worker-termination.mjs` | Node Worker termination/finalizer mechanics do not apply; explicit native close, stalled-fetch cancellation and bounded C destruction qualify teardown; cancelling a Swift Task is not automatic engine destruction. |
| `test-next-package.mjs` | Next/webpack route tracing does not apply; underlying durable streaming, reopening and wake delivery have native and independent SwiftPM consumer evidence; Next deployment itself is unqualified. |
| `test-node-async-assets.mjs` | Dynamic Wasm asset formats/resolvers/repair/cache do not apply; actual engine turns and isolation are qualified by native lifecycle/model tests. |
| `test-node-bundled-assets.mjs` | Webpack asset URLs and dynamic backend fallback do not apply; independent SwiftPM consumers qualify native package linking and startup. |
| `test-node-napi.mjs` | Node runner mechanics do not apply; its child agent/core owners require their individual dispositions, rather than a blanket platform exemption. |
| `test-node-package.mjs` | Npm tarballs, conditional CJS/ESM exports and addon relocation do not apply; independent SwiftPM Release consumers and native checkpoint owners qualify packaging and engine behavior. |
| `test-node-tracing.mjs` | Node output-file tracing does not apply; independent public SwiftPM consumers qualify linked engine/checkpoint/storage; ambient runtime tracing isolation is separately qualified by the C fetch consumer. |
| `test-node-wasm.mjs` | Node/Bun JSPI runner mechanics do not apply; child prompt/cancel/persistence contracts require their native equivalents. |
| `test-package-resilience.mjs` | Npm/addon/Wasm mutation and module repair do not apply; tool success/rejection, checkpoint restoration, agent isolation, late-settlement suppression and retained-wrapper cleanup have native equivalents; the original long randomized workload and performance bounds are not qualified. |
| `test-packed-example.mjs` | Packed npm CJS/ESM examples do not apply; actual Swift public consumers and SQLite recovery qualify underlying prompt and persistence behavior. |
| `test-pi-benchmark.mjs` | External Pi benchmark executable does not apply; no Pi or Swift performance equivalence is claimed. |
| `test-sdk.mjs` | Wasm smoke runner mechanics do not apply; child prompt/cancel/checkpoint contracts map to native owners; virtual Wasm HOME behavior is not a native filesystem contract. |
| `test-term-demo-package.mjs` | Web terminal asset hashes and cache headers do not apply to the Swift SDK product. |
| `test-term-login.mjs` | Terminal URL/code rendering and UI OAuth records do not apply; public Swift sign-in, credential refresh and persisted authorization have separate native/provider-suite evidence; no terminal UI migration is claimed. |
| `test-term-session-resume.mjs` | JS terminal snapshots and legacy 0.0.13 UI formats do not apply; complete checkpoint/journal owners and SQLite recovery qualify conversation restoration. |
| `test-term.mjs` | Terminal DOM, draft rendering and polling do not apply; actual steering, assistant-prefix continuity and cancellation isolation are qualified by native stream/steering owners. |
| `test-types.mjs` | TypeScript export/declaration tests do not apply; Swift compilation, typed public APIs and independent SwiftPM consumers are the equivalent gates; minimum-compiler qualification remains separately recorded. |
| `test-vercel-package.mjs` | Vercel/Linux deployment packaging is unqualified, not a JavaScript-syntax exemption; portable model/tool/checkpoint/MCP cleanup has Swift evidence, which does not prove a deployed Vercel service. |
| `test-wasm-jspi-tier-up.mjs` | JSPI call/suspension counters do not apply to the native C core. |
| `test-wasm-memory.mjs` | Wasm linear-memory page limits do not apply; no native memory-budget equivalence is claimed. |
| `test-wasm-module-cache.mjs` | Wasm compile caches, repair and WeakRefs do not apply; native isolation/cancellation and closed-wrapper resource release have direct Swift/C evidence. |

### Evidence limits

No uncovered production C ABI capability was identified in this audit after adding the two security checks. This is a contract-level finding, not a claim that every original assertion passed. The pressure owner's five-second drain performance bound remains unqualified. The allocation-failure copy paths were inspected but do not have exhaustive OOM injection evidence.

The original Wasm `test-core.mjs`, `test-core-cancel.mjs` and `test-core-home-unavailable.mjs` files are not executed through Swift. Native equivalents qualify ordinary streaming, usage, request identity, checkpoint, cancellation and lifecycle; the inventory retains the narrower status instead of inferring a missing SDK API. The unavailable virtual HOME condition is specific to Wasm. `test-durable-harness.mjs` tests JavaScript benchmark helpers and launches benchmark drivers; no complete equivalent workload result is claimed.

World/Vercel deployment and provider behavior require service evidence. Native persistence, routing, lease, queue-authority, HTTP wake and process-death recovery proofs do not establish a deployed provider. Neither a platform classification nor an unexecuted original file establishes a missing portable capability. See [durable acceptance](DURABLE-ACCEPTANCE.md) for individual durable contracts and [validation](VALIDATION.md) for live-credential and platform limits. Swift 6.2 has now passed all 416 local test functions using the official compiler and macOS 15.2 SDK; this does not extend the runtime platform claim beyond the tested macOS consumers. CI and push remain excluded.
