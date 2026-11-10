# Local migration acceptance

The local delivery is a Swift package backed by the shared Zig runtime and C ABI. `LibFx`, optional `LibFxMCP`, and optional `LibFxHTTP` run without JavaScript. `FxSwiftDriver` and the JavaScript adapters exist only to reuse behavioral assertions.

This review applies to the functional scope in [the migration plan](MIGRATION.md). It does not qualify a published package or a deployed service. Final command results are recorded in [validation](VALIDATION.md).

## Requirement review

| Requirement | Implementation and acceptance evidence |
| --- | --- |
| Reuse the existing kernel | `src/native_core_runtime.zig` owns the runtime used by both `src/napi_core_main.zig` and `src/c_core_main.zig`. The C entry point adds admission and byte ownership, not another agent loop. [Bridge validation](BRIDGE-VALIDATION.md) maps native contracts and platform-specific owners. |
| Provide the current portable libfx behavior | The [functional matrix](MIGRATION.md#functional-acceptance-matrix) covers engines, streams, tools, control, providers, images, journals, checkpoints, durable execution, observation, MCP, skills, and package integration. [Durable acceptance](DURABLE-ACCEPTANCE.md) maps queue, storage, generic execution, HTTP wakeups, ownership, and recovery to specific native assertions. |
| Use Swift conventions | Public configuration and payloads use Sendable values, enums, Foundation URL/Data, Codable, async closures, and AsyncSequence. Actors own asynchronous mutable state. Explicit asynchronous close joins owned work. No Promise/AbortSignal facade, Node fallback, deprecated TypeScript aliases, or implicit JavaScript default-store registry is included. |
| Avoid unnecessary abstractions | The generic harness reuses the durable worker. Storage owns its admission domain; additional opaque replicas require an explicit compatibility identity. Queue authority is a separate verified, one-use context. Optional HTTP/MCP products use maintained libraries. These boundaries serve current behavior and ownership. |
| Keep the adapter thin | The adapters translate values and forward operations to the built Swift driver. Swift owns the engine, persistence admission, scheduling, cancellation, and effects. Original callbacks remain test fixtures. Native tests cover boundaries that IPC cannot prove; bridge validation documents shape/timing adaptations. |
| Preserve persistence and recovery | Original journal/checkpoint interoperability runs in both directions. SQLite stores Swift durable state; hosts can supply storage and queues. Native tests and separate-process SIGKILL consumers cover stable IDs, fencing, ambiguous effects, and replay. Swift durable storage does not adopt the JavaScript private physical layout. |
| Qualify lifecycle and concurrency | Full native tests, targeted Swift sanitizer runs, an additional instrumented Zig/Swift TSan run, C ABI consumers, and independent public Release consumers provide separate evidence. Ordinary Swift sanitizer runs do not instrument the packaged Zig archive. |
| Deliver usable package integration | The local SwiftPM package links the generated universal XCFramework without unsafe linker flags. Separate consumers import public products and run native model/tool, persistence, routing, HTTP, and MCP interactions. The README contains the build and local dependency steps. |
| Honor local-only acceptance | No CI or push is required or performed for final acceptance. An unrelated PostgreSQL experiment is excluded from the package, dependencies, and acceptance evidence. |

The final source review found no remaining required portable capability gap. This conclusion relies on the behavior mappings and direct native equivalents as well as selected unchanged JavaScript assertions. It does not mean every assertion in every original JavaScript owner was executed.

## Qualifications

- The first target is macOS arm64. Swift 6.2 and 6.4 have full local native test results. The universal archive also has x86_64 Release-consumer proof under Rosetta; native Intel hardware, Linux, and other Apple platforms are unqualified.
- Live credentialed provider calls and deployed Vercel Workflow/Queue behavior are unqualified. The SDK supplies portable storage, verified delivery, wake, deadline, and ownership interfaces; local fixtures do not establish remote service atomicity or liveness.
- Node addon ownership hooks, Wasm, npm/browser terminal packaging, and private World hooks have explicit platform dispositions. Their necessary engine behavior is mapped to Swift/C evidence where applicable.
- Lossless bounded native output is qualified. The original five-second pressure-drain performance deadline is not established by the direct C check, which allows twenty seconds.
- The generated XCFramework is local and ignored by Git. Remote package distribution and release publication are not part of this delivery.
