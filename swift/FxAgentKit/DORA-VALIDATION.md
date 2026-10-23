# Dora integration acceptance

Local verification on 2026-10-24, macOS arm64. The integration worktree is based on `feat/libfx-swift` and merges the complete histories of `dora/native-tools`, `dora/tool-approval`, `dora/agent-runtime`, `dora/compaction-proof`, and `dora/runtime-updates`. No branch was pushed or merged into either base branch. Remote CI and the repository's release SHIP gate were not run.

## Public entry point

The live Release consumer depends only on the `FxAgentKit` product and imports only `FxAgentKit` plus Foundation. It opens `Agent`, supplies its provider configuration and approval actor, updates the deferred catalog, appends context, streams events, and closes/reopens SQLite persistence. The same product reexports the existing LibFx value types. See [the integration guide](DORA-INTEGRATION.md).

AgentKit owns the single-conversation facade and approval wrappers. LibFx owns transport, catalog execution, and persistence. The Zig gateway owns wire formats and the existing compactor owns context reduction. The change reuses the existing agent loop and journal rather than adding a second persistence system. New tests use the existing Swift targets and in-source Zig tests; no root deterministic E2E file or PGSO corpus owner was added.

## Live provider results

Both runs use `deepseek-flash`, a deliberately reduced 32768-token context window, and a 16384-token output budget. The small input window triggers automatic compaction without filling the provider's full context. Earlier 1024- and 4096-token output budgets exhausted the default thinking allowance before the summary completed; these failed trials are not counted as successful acceptance.

| Check | Responses | Messages |
| --- | --- | --- |
| Endpoint | `https://api.deepseek.com/v1/responses` | `https://api.deepseek.com/anthropic/v1/messages` |
| Deferred invocation | Native search output and native action calls | Explicit `.callAction` compatibility mode |
| Multi-turn recall | Passed | Passed |
| Search, then execute deferred action | Passed | Passed |
| Add, update, remove action; removed closure stays unused | Passed | Passed |
| Reject once, then approve once; rejected closure stays unused | Passed | Passed |
| Automatic summary model requests | 2 | 2 |
| Persisted replacements containing a real compactor summary | 1 | 1 |
| Continue after compaction and execute updated action | Passed | Passed |
| Appended context survives compaction and SQLite reopen | Passed | Passed |
| Text / reasoning / tool-start / tool-finish events | 112 / 530 / 11 / 11 | 124 / 474 / 11 / 11 |
| Requests with cache hits after the first request | 26 of 26 | 26 of 26 |
| Second request cached tokens | 640 | 512 |
| Runtime stderr bytes | 0 | 0 |

Each success comes from the native runtime linked into the consumer and actual HTTPS requests. The HTTP wrapper forwards the service response unchanged and records numeric usage. It does not replace model responses, inject tool calls, or alter request schemas. The test asserts closure counts, approval decisions, recalled markers, streamed event pairs, and a persisted `compacted_summary` with a positive removed-turn count.

## Messages compatibility boundary

DeepSeek Messages returned HTTP 422 for `tool_addition.tool.type = tool_definition`. Replacing it with `tool_reference` returned HTTP 400 for an unknown tool unless that definition was already declared at the top level. The endpoint therefore could not support arbitrary new by-value definitions while keeping its top-level tool list fixed. The same incompatibility is reported in [DeepSeek issue 1701](https://github.com/deepseek-ai/DeepSeek-V3/issues/1701).

The accepted integration uses an explicit `deferredToolMode: .callAction` setting for this endpoint. Its fixed functions are `tool_search` and `call_action`; search returns full schemas in tool-result text. Invocation validates the current schema and then executes the same approved closure. The default `.native` mode remains available for Messages services that accept inline definitions. There is no automatic protocol downgrade after a rejection. Route identity includes the compatibility mode so opaque replay cannot cross modes.

The implementation follows pi's explicit provider-compatibility distinction rather than assuming that all Messages endpoints accept the same features. The local reference was pi `6fb2e7815167e6b19006fc526d1a5d0f5f998787`, `packages/ai/src/api/anthropic-messages.ts`. The Responses search format was checked against Codex `8c818cbed4bc83d30f5d515674b809646fe2676d`, `codex-rs/protocol/src/models.rs`, and the existing Responses serializer/reducer was reused. Service protocol references: [DeepSeek Responses](https://api-docs.deepseek.com/guides/responses_api/) and [DeepSeek Messages](https://api-docs.deepseek.com/guides/anthropic_api/).

Live acceptance also found and repaired Messages thinking/signature replay, missing JSON separation between thinking and text, and content-block indices being mistaken for tool ordinals. Focused regressions cover these cases. Public `FxUsage` now retains cache and reasoning counters supplied through the Chat Completions reducer, including translated Messages usage. The integration also completes the host-context JSON export/import and test equality cases missed by the earlier branch.

## Per-request usage

These are the final successful runs. Each row represents one actual model request, including requests made by the compactor. Responses `input_tokens` includes cached input. Messages `input_tokens` excludes `cache_read_input_tokens` and `cache_creation_input_tokens`; add those fields to obtain total input. Missing reasoning counters in Messages are left unreported.

### Responses

```text
request=1 kind=conversation input_tokens=489 input_tokens_details.cached_tokens=256 output_tokens=289 output_tokens_details.reasoning_tokens=279 total_tokens=778
request=2 kind=conversation input_tokens=788 input_tokens_details.cached_tokens=640 output_tokens=6 output_tokens_details.reasoning_tokens=0 total_tokens=794
request=3 kind=conversation input_tokens=811 input_tokens_details.cached_tokens=640 output_tokens=139 output_tokens_details.reasoning_tokens=98 total_tokens=950
request=4 kind=conversation input_tokens=1066 input_tokens_details.cached_tokens=896 output_tokens=22 output_tokens_details.reasoning_tokens=0 total_tokens=1088
request=5 kind=conversation input_tokens=1105 input_tokens_details.cached_tokens=896 output_tokens=8 output_tokens_details.reasoning_tokens=0 total_tokens=1113
request=6 kind=conversation input_tokens=1136 input_tokens_details.cached_tokens=896 output_tokens=42 output_tokens_details.reasoning_tokens=0 total_tokens=1178
request=7 kind=conversation input_tokens=1298 input_tokens_details.cached_tokens=1152 output_tokens=23 output_tokens_details.reasoning_tokens=0 total_tokens=1321
request=8 kind=conversation input_tokens=1335 input_tokens_details.cached_tokens=1152 output_tokens=18 output_tokens_details.reasoning_tokens=0 total_tokens=1353
request=9 kind=conversation input_tokens=1370 input_tokens_details.cached_tokens=1152 output_tokens=23 output_tokens_details.reasoning_tokens=0 total_tokens=1393
request=10 kind=conversation input_tokens=1409 input_tokens_details.cached_tokens=1152 output_tokens=10 output_tokens_details.reasoning_tokens=0 total_tokens=1419
request=11 kind=conversation input_tokens=1569 input_tokens_details.cached_tokens=1408 output_tokens=41 output_tokens_details.reasoning_tokens=0 total_tokens=1610
request=12 kind=conversation input_tokens=1726 input_tokens_details.cached_tokens=1536 output_tokens=22 output_tokens_details.reasoning_tokens=0 total_tokens=1748
request=13 kind=conversation input_tokens=1764 input_tokens_details.cached_tokens=1536 output_tokens=8 output_tokens_details.reasoning_tokens=0 total_tokens=1772
request=14 kind=conversation input_tokens=1922 input_tokens_details.cached_tokens=1664 output_tokens=76 output_tokens_details.reasoning_tokens=54 total_tokens=1998
request=15 kind=conversation input_tokens=2015 input_tokens_details.cached_tokens=1792 output_tokens=18 output_tokens_details.reasoning_tokens=0 total_tokens=2033
request=16 kind=conversation input_tokens=2166 input_tokens_details.cached_tokens=1920 output_tokens=41 output_tokens_details.reasoning_tokens=0 total_tokens=2207
request=17 kind=conversation input_tokens=2220 input_tokens_details.cached_tokens=2048 output_tokens=27 output_tokens_details.reasoning_tokens=12 total_tokens=2247
request=18 kind=conversation input_tokens=6500 input_tokens_details.cached_tokens=2176 output_tokens=53 output_tokens_details.reasoning_tokens=50 total_tokens=6553
request=19 kind=conversation input_tokens=10774 input_tokens_details.cached_tokens=6528 output_tokens=3 output_tokens_details.reasoning_tokens=0 total_tokens=10777
request=20 kind=compaction input_tokens=16098 input_tokens_details.cached_tokens=10752 output_tokens=2187 output_tokens_details.reasoning_tokens=1135 total_tokens=18285
request=21 kind=compaction input_tokens=15497 input_tokens_details.cached_tokens=14848 output_tokens=1840 output_tokens_details.reasoning_tokens=1158 total_tokens=17337
request=22 kind=conversation input_tokens=7345 input_tokens_details.cached_tokens=256 output_tokens=28 output_tokens_details.reasoning_tokens=25 total_tokens=7373
request=23 kind=conversation input_tokens=7391 input_tokens_details.cached_tokens=7168 output_tokens=13 output_tokens_details.reasoning_tokens=0 total_tokens=7404
request=24 kind=conversation input_tokens=7419 input_tokens_details.cached_tokens=7168 output_tokens=53 output_tokens_details.reasoning_tokens=12 total_tokens=7472
request=25 kind=conversation input_tokens=7588 input_tokens_details.cached_tokens=7424 output_tokens=22 output_tokens_details.reasoning_tokens=0 total_tokens=7610
request=26 kind=conversation input_tokens=7627 input_tokens_details.cached_tokens=7424 output_tokens=10 output_tokens_details.reasoning_tokens=0 total_tokens=7637
request=27 kind=conversation input_tokens=7648 input_tokens_details.cached_tokens=7424 output_tokens=6 output_tokens_details.reasoning_tokens=0 total_tokens=7654
```

### Messages

```text
request=1 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=128 input_tokens=424 output_tokens=113
request=2 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=512 input_tokens=163 output_tokens=6
request=3 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=512 input_tokens=186 output_tokens=54
request=4 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=640 input_tokens=183 output_tokens=54
request=5 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=640 input_tokens=254 output_tokens=8
request=6 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=768 input_tokens=157 output_tokens=42
request=7 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=896 input_tokens=137 output_tokens=55
request=8 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=896 input_tokens=206 output_tokens=14
request=9 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=896 input_tokens=237 output_tokens=64
request=10 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=1024 input_tokens=189 output_tokens=17
request=11 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=1152 input_tokens=228 output_tokens=41
request=12 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=1280 input_tokens=212 output_tokens=54
request=13 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=1408 input_tokens=154 output_tokens=9
request=14 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=1536 input_tokens=185 output_tokens=125
request=15 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=1664 input_tokens=199 output_tokens=18
request=16 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=1792 input_tokens=222 output_tokens=58
request=17 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=1920 input_tokens=165 output_tokens=17
request=18 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=2048 input_tokens=4307 output_tokens=24
request=19 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=6272 input_tokens=4328 output_tokens=3
request=20 kind=compaction cache_creation_input_tokens=0 cache_read_input_tokens=10496 input_tokens=5438 output_tokens=1548
request=21 kind=compaction cache_creation_input_tokens=0 cache_read_input_tokens=14720 input_tokens=613 output_tokens=3349
request=22 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=256 input_tokens=6984 output_tokens=67
request=23 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=7168 input_tokens=157 output_tokens=115
request=24 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=7296 input_tokens=159 output_tokens=115
request=25 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=7424 input_tokens=217 output_tokens=54
request=26 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=7552 input_tokens=160 output_tokens=16
request=27 kind=conversation cache_creation_input_tokens=0 cache_read_input_tokens=7552 input_tokens=187 output_tokens=6
```

## Reproduce the live acceptance

From the worktree root:

```sh
bash swift/scripts/build-xcframework.sh
swift build --package-path swift/consumers/DeepSeek -c release
python3 swift/scripts/test-deepseek-consumer.py responses
python3 swift/scripts/test-deepseek-consumer.py messages
```

The Python launcher reads the existing `ANTHROPIC_AUTH_TOKEN` assignment from `~/.local/bin/dcc` into memory, sets `DEEPSEEK_API_KEY` only in the consumer's environment, and executes the built consumer. It never prints or writes the credential. Temporary conversation databases are removed when each run exits. No trace capture or observation sink is enabled. Provider-error diagnostics are bounded and redact credentials before printing.

## Final local gates

The generated XCFramework contains arm64 and x86_64 macOS slices. Its static archive SHA-256 is `1be018f68932e9d19c91eeada2f3241ccfa76f3629976f035b93f1365092024f`.

| Gate | Result |
| --- | --- |
| `zig build` | Passed |
| Complete `FX_SOUND=0 zig build test` | Passed |
| `swift test --package-path swift --no-parallel` | Passed: LibFx 405, MCP 11, HTTP 14, AgentKit 31; total 461 |
| `test-consumer.sh` | Passed |
| `test-tool-approval-consumer.sh` | Passed |
| `test-workspace-tools-consumer.sh` | Passed, including real file and shell effects, denial, and cancellation |
| `test-compaction-consumer.sh` | Passed: one summary request, persisted replacement, SQLite continuation |
| `test-runtime-catalog-consumer.sh` | Passed: two automatic summary requests, catalog mutations and recovery |
| `test-consumer-x86_64.sh` | Passed under Rosetta; the XCFramework archive remained unchanged |
| Guide's minimal Swift function | Typechecked for macOS 14 with Swift 6 |
| Fresh `zig-out/bin/fx` | `--version`, `help`, `status --json`, and `scripts/smoke-binary.sh` passed; stderr empty |
| Formatting, public surface, compactor/indexer boundaries, whitespace | Passed |
| Five source branches | Each tip is an ancestor of integration HEAD |

Swift tests and consumers above use the rebuilt native XCFramework. Consumer scripts enforce clean runtime stderr and exercise cancellation and resource teardown in addition to the live acceptance paths. Build warnings and test failures were checked separately from successful process exit codes.

The credential was checked with `git grep` against every new integration revision tree and with an in-memory exact-match scan of working files and evidence logs. No match was found. The scan is repeated after the local commit. Generated artifacts and evidence logs are ignored by git. Full local logs are retained under `swift/.build/dora-integration-evidence/`.
