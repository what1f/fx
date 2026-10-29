# Responses message phase validation

Local verification on 2026-10-24, macOS arm64, on `dora/integration`. The baseline was `355ffa883f0316db9b4588a7cddec6aa675f0265`. No push, merge, remote CI, or release SHIP gate was performed.

## Cause and captured sequence

The fourth diagnostic Core-3 run failed on its first turn. For the same message identity at `output_index=1`, DeepSeek sent:

| Received event | Type | Phase | Text bytes |
| --- | --- | --- | --- |
| 59 | `response.output_item.added` | `final_answer` | No content yet |
| 61–76 | `response.output_text.delta` | Not supplied | 77 in total |
| 77 | `response.output_text.done` | Not supplied | 77 |
| 78 | `response.content_part.done` | Not supplied | 77 |
| 79 | `response.output_item.done` | `commentary` | 77 |

Both text completion events and the completed message had SHA-256 `6dde79ce173286721e091461a9faa778293e4620a1e0f929d10f5896fc953879`. The failure was the phase comparison in `Reducer.reconcile_message`, not a text hash, length, identity, kind, or order mismatch. fx treated the phase from the unfinished item as final and rejected the completed item's classification.

The reference implementation is Codex `8c818cbed4bc83d30f5d515674b809646fe2676d`. `codex-rs/codex-api/src/sse/responses.rs::process_responses_event` emits the completed `ResponseItem`; `codex-rs/core/src/session/turn.rs` passes that item to `handle_output_item_done`. It does not require the added item's phase to match the completed item's phase. Its `ResponseCompleted` also does not deserialize the terminal output array for text comparison. pi's `packages/ai/src/api/openai-responses-shared.ts` likewise assigns the completed message's text signature from `item.phase` in its `response.output_item.done` branch. [DeepSeek's event guide](https://api-docs.deepseek.com/guides/responses_api/) describes added and done events as item start and completion.

## Change and regression proof

The gateway now distinguishes provisional phase metadata from completed phase metadata. The first completed known phase replaces the provisional phase. Further completed records must agree. Identity, text digest, length, part kind, text order, cancellation, and resource checks remain enforced. No retry, protocol switch, or duplicate tool execution was added.

`src/gateway/fixtures/deepseek-provisional-phase.jsonl` reconstructs the 79 received events from metadata. Every text field uses the same UTF-8 byte length as its captured counterpart, with `x` placeholders; item IDs use stable placeholders. It contains no original text or credentials. The regression exercises full and one-byte content capture, verifies the completed commentary phase, checks for duplicate text delivery, and rejects a later conflicting completed phase. Another test verifies the converse phase transition and final replay metadata. Existing conflict tests still run.

Restoring the old phase equality check makes the captured regression fail. The repaired Responses focused tests and the full ReleaseSafe Zig suite pass.

Set `FX_RESPONSES_DIAGNOSTICS=1` only for diagnosis. It writes event types, receive sequence, stream identifier, item/content indices, item IDs, phase, byte lengths, and SHA-256 digests to stderr. It never writes response text, tool arguments, requests, or headers. It is disabled by default. Live acceptance removes this switch and the general trace switches, checks output for the exact credential before printing it, and checks HTTP disk caches.

## Local results

| Check | Result |
| --- | --- |
| Full `FX_SOUND=0 zig build test -Doptimize=ReleaseSafe` | Passed: 10084 tests, 2 skipped |
| Responses focused tests | Passed |
| arm64/x86_64 XCFramework build | Passed |
| Full Swift tests | 462 passed: LibFx 406, MCP 11, HTTP 14, AgentKit 31 |
| Release consumers | All six passed, including compaction, catalog, approvals, workspace tools, and Rosetta x86_64 |
| Fresh `zig-out/bin/fx` runtime interaction | Consumed the captured SSE fixture over local HTTP, exited 0, stderr empty |
| DoraKit rebuild and tests | Passed, 45 tests; dependency check passed |
| Formatting, public surface, compactor/indexer boundaries, whitespace | Passed |

After the diagnostic helper was made private, the freshly rebuilt ReleaseSafe CLI remained byte-for-byte identical to the binary used by the E2E sweep (SHA-256 `2e61b3c0b456e94ba3b81231516e6fd8392fe6360a0f344380e1ee65f1442273`). Swift, consumer, and live-provider validation was rerun against the rebuilt universal archive.

The universal archive SHA-256 is `54118f0d220b43cce344b080b386ca9ed216b1db7c119c7b5ceafcd33110482a`. The gateway source SHA-256 is `6ee150117e99653f298ce3c94ab1330459ffd0da477b2a1f949029e36d7409fb`.

### Live DeepSeek revalidation

Both protocols used `deepseek-flash` and the existing public FxAgentKit acceptance program. Both passed multi-turn recall, deferred search and invocation, catalog add/update/remove, approval deny/allow, automatic compaction, continued invocation after compaction, appended context, SQLite reopen, and close. Each persisted one real compaction replacement. Messages retains its explicit `.callTool` compatibility setting.

| Protocol | Requests | Summary requests | Cache hits after first request | Second request cached tokens | stderr bytes |
| --- | --- | --- | --- | --- | --- |
| Responses | 27 | 2 | 26 of 26 | 640 | 0 |
| Messages | 26 | 1 | 25 of 25 | 384 | 0 |

[Per-request numeric usage](FX-2-USAGE.json) retains the provider's field names. Responses input includes cached input. Messages input excludes cache-read and cache-creation input. These counters establish cache hits for these runs only.

### Three consecutive Core-3 runs

Dora was rebuilt against the new local Swift package. No Dora source was changed. The unmodified `scripts/test-core3-live.py` passed three times in succession with diagnostics disabled:

| Run | Requests by turn | Input tokens | Cached input | Output tokens | Reasoning tokens | Requests with cache hits |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 5, 3, 5, 3 | 142122 | 138112 | 5452 | 2981 | 16 of 16 |
| 2 | 5, 3, 4, 4 | 173739 | 166400 | 3532 | 437 | 16 of 16 |
| 3 | 6, 3, 4, 3 | 180112 | 172928 | 4125 | 657 | 16 of 16 |

Each run created and enabled a plugin, discovered and invoked its open action, changed Gmail to Outlook with an accepted version increase, rejected the dangerous clipboard clear, preserved the database sentinel, restored all four completed turns across processes, and listed enabled actions through MCP. Per-request usage and assertions are retained in Dora's `docs/validation/fx-2-core3-run-{1,2,3}.json`; the earlier Core-3 evidence file was preserved.

## Boundaries

This is local protocol and runtime evidence. It does not establish remote CI, release qualification, a Dora App window, Keychain UI, or a macOS 14 device run. The repository's two sound-producing E2E exceptions remain excluded on macOS as its instructions require. The initial local E2E sweep encountered an overlong tmux socket path and a test-wide Keychain override; affected files were rerun with a short socket directory and without that override. Final E2E results and credential audit follow.

## E2E sweep and credential audit

The local root E2E sweep checked 68 files: **1969 passed, 62 skipped, 1 filtered, 0 failed**. [Per-file results](FX-2-E2E.json) retain the counts. Existing platform, credentialed live-model, and capability conditions account for the skips. `notifications.test.ts` and the sound-enabling TUI case were excluded as the repository requires on macOS. No new root E2E owner was added; existing corpus classifications and Linux shard weights remain appropriate.

The added diagnostic stderr sink is registered narrowly as opt-in noninteractive metadata output in the direct-write audit. Its four tests pass. The late-settlement interruption fixture initially completed its 30000-file search before the second Escape, so its required event order never occurred. It now uses the existing Linux corpus size of 120000 files on both platforms. Timeouts and ordering assertions are unchanged. All 11 interruption tests and two subsequent focused runs pass. This changes the test setup, not cancellation behavior.

`gateway-stream-lifecycle.test.ts` received HTTP 403 in one initial MCP fixture run. Its full-file retry passed; three isolated repetitions of the affected test also passed. This remains a possible fixture or transport race to observe. It did not exercise the Responses reducer, and no production workaround was added for it.

The credential audit uses `git grep` for both worktrees, both indexes, and the fx commits added since `c9c8ae3c`, plus exact in-memory matching over new evidence and HTTP caches. It found no credential matches. All 84 discovered HTTP cache files were checked; the Acceptance and dora cache directories remain absent. Live launchers check captured output before emitting it. No key was written to source, fixtures, evidence, or commits.
