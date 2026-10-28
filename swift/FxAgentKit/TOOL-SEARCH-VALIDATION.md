# Deferred tool search validation

Date: 2026-10-27. Branch: `feat/libfx-swift`. Baseline: `a89e0c43`.

Repeated searches previously saved the same definitions more than once. Native Responses and Messages replayed all of them, so strict services rejected the request. The saved results made the failure persist after reopening.

## Behavior

- Searches return current tool information, but save native declarations only for names not yet declared in the retained context.
- Native serializers retain each name's first saved definition and position. They filter later declarations without replacing historical schemas or modifying storage. This also repairs requests from saved conversations containing duplicates.
- Responses preserves search-result text when there are no new native declarations. Chat Completions and Messages call-action mode retain text when their declaration delta is empty.
- Responses and native Messages keep `call_action` in the fixed tool list. Updated schemas arrive as appended context; calls through `call_action` use current arguments, validation, permissions, and closures.
- Reopening and successful compaction rebuild declaration flags from retained history. Removed names that reappear still retain their first declaration if it remains in history. Names removed by compaction can be declared again.
- No persisted type, field, enum, checkpoint version, or journal format changed. No local data conversion, deletion, or migration is required. Existing user sessions were not modified during validation.

## Cache boundaries

The fixed `call_action` function changes the resident tool list for Responses and native Messages. This is an accepted resident-tool cache boundary. Request repair changes a saved invalid request from its later duplicate declaration onward; the user explicitly approved this boundary. Empty search results now retain their text in Responses. Historical snapshots and tool-result bytes on disk remain unchanged.

After these fixed serialization rules are applied, repeated calls, catalog updates, removal/re-addition, and checkpoint restoration preserve earlier serialized input bytes. Normal operation does not replace old schemas with the live catalog. Compaction remains an accepted new-context boundary; its summary request still uses its parent's prefix.

Local byte equality and provider cache counters are separate checks.

## Local checks

- `zig build test-focused -Dtest-filter=deferred --summary all`: passed. Covers immutable first declarations, overlap, replacement, retained-context reconstruction, and native serializers.
- `zig build test-focused -Dtest-filter='repeated broad search'`: passed. Repeated search returns both matches and an empty native declaration delta.
- `swift test --package-path . --no-parallel`: passed. Reported 413 LibFx, 11 MCP, 14 HTTP, and 36 FxAgentKit tests; the opt-in live test was skipped in this run.
- The Swift catalog tests exercise duplicate-free native requests, exact and broad searches, overlapping matches, changed parameters through `call_action`, removal/re-addition, checkpoint reopen, native Messages, automatic compaction, and SQLite reopen.
- A checksum-valid checkpoint fixture contains repeated full definitions. Reopening preserves its decoded checkpoint contents, and its next serialized request contains one declaration per name.
- `bash swift/scripts/build-xcframework.sh`: passed for arm64 and x86_64. Archive SHA-256: `872f81986f10741a0175a1a6a1c955047f3cf501942ad769e8c1a38fb8906900`.
- `bash swift/scripts/test-runtime-catalog-consumer.sh`: passed through the public package in a separate executable, including 5 automatic compaction requests, current-schema execution, removal, SQLite reopen, and checkpoint restoration. Runtime stderr was empty.
- `bash swift/scripts/test-consumer-x86_64.sh`: passed the public Release consumers under Rosetta, including routing, HTTP wake, timed ownership, resources, and Foundation HTTP queue/credential-isolation checks. The dual-architecture archive hash remained unchanged.
- `zig fmt --check src/`, `git diff --check`, `scripts/check-compactor-boundary.sh`, `scripts/check-indexer-boundary.sh`, and `scripts/check-public-surface.sh`: passed before the final documentation update.

The first Swift full run used the default parallel test execution and failed in several lifecycle/storage suites. Those suites passed in isolation (17 tests), and the explicit serial full run passed. No assertions were relaxed.

## DeepSeek Responses

`runtimeCatalogLiveDeepSeekRepeatedSearchAndRecovery` sends every native request to `deepseek-flash` at `/v1/responses`, then supplies scripted replies to make repeat searches deterministic. It does not replace the serialized request body. The service validates each request; the script determines which tool operation the engine performs next.

All 7 requests returned HTTP 200. The fixture covers repeated broad/exact discovery, current-schema invocation through `call_action`, and reopening a checkpoint with duplicate declarations. It checks stable instructions, reasoning settings, top-level tool bytes, and append-only input bytes between calls and catalog updates. The repaired saved checkpoint is a separate history branch.

| Request | Input tokens | Cached tokens |
| --- | ---: | ---: |
| 1 | 453 | 256 |
| 2 | 705 | 512 |
| 3 | 824 | 640 |
| 4 | 1025 | 891 |
| 5 | 1144 | 896 |
| 6 | 1216 | 1024 |
| 7, restored branch | 832 | 640 |

These are service-returned counters. They establish observed cache reads, not a guaranteed cache-hit ratio. Credentials were read from the local credential launcher into `DORA_TEST_DEEPSEEK_KEY`, never written into fixtures or reports, and checked against captured output before it was displayed.

The separate Release `DeepSeekAcceptance` consumer also passed with real model-driven Responses calls: 27 requests, including catalog add/update/remove, approval denial/allowance, automatic compaction, appended context, persistence, reopen, and close. There were 2 compaction model requests. All 26 requests after the first reported cache reads. The summary requests reported input/cached tokens of 15691/10368 and 15087/14464. The credential scan found no key in consumer output or its HTTP disk cache. This consumer uses the model's own tool choices; the deterministic fixture above covers the repeated-search trigger directly.

## Full Zig suite limitations

The final full run reported 10100/10104 passes, 2 skips, 1 failure, and 1 crash. The first full run had the same failure/crash before the retained-history regression test was added.

- The compaction provenance test expected 2 model calls and observed 1. It also fails on the untouched `a89e0c43` baseline with the same assertion.
- The ACP model-commit boundary test expects `SessionPersistenceUnavailable`, but `commitActiveSessionModel` now succeeds for a libfx session without `v2`. The test unwraps `worker.failure.?` after that success and aborts. Direct execution of test index 9308 from the final full test binary reproduces the crash. The complete test block and called method are byte-identical to `a89e0c43`; neither was changed by this task.

An earlier command using `-Dtest-filter='ACP model commits honor the active session write boundary'` reported success but did not select this lazily imported test. That result is not counted as an ACP pass. The direct full-binary test run corrects that verification gap. The tool-search regression tests are present in the final full binary and are not among its failures.

Remote CI was not run. No push, merge, browser acceptance, or installed-app acceptance was performed.

## Model-driven live output

```text
turn_completed input=562 output=2 cached=128
turn_completed input=574 output=6 cached=384
tool_started=tool_search
tool_finished=tool_search error=false
tool_started=echo_code
tool_finished=echo_code error=false
turn_completed input=2182 output=90 cached=1536
tool_started=tool_search
tool_finished=tool_search error=false
tool_started=save_note
tool_finished=save_note error=true
turn_completed input=2890 output=83 cached=2304
tool_started=save_note
tool_finished=save_note error=false
turn_completed input=2206 output=44 cached=1792
tool_started=tool_search
tool_finished=tool_search error=false
tool_started=new_code
tool_finished=new_code error=false
turn_completed input=4249 output=71 cached=3584
tool_started=new_code
tool_finished=new_code error=false
turn_completed input=3084 output=45 cached=2688
tool_started=tool_search
tool_finished=tool_search error=false
turn_completed input=3597 output=69 cached=3200
turn_completed input=6113 output=33 cached=1792
turn_completed input=10367 output=3 cached=6144
turn_completed input=6922 output=42 cached=256
turn_completed input=6982 output=123 cached=6784
tool_started=tool_search
tool_finished=tool_search error=false
tool_started=call_action
tool_finished=call_action error=false
turn_completed input=21957 output=223 cached=21376
persisted_compaction_replacements=1
stream_events text=96 reasoning=353 tool_started=11 tool_finished=11
request=1 kind=conversation input_tokens=562 input_tokens_details.cached_tokens=128 output_tokens=2 output_tokens_details.reasoning_tokens=0 total_tokens=564
request=2 kind=conversation input_tokens=574 input_tokens_details.cached_tokens=384 output_tokens=6 output_tokens_details.reasoning_tokens=0 total_tokens=580
request=3 kind=conversation input_tokens=597 input_tokens_details.cached_tokens=384 output_tokens=60 output_tokens_details.reasoning_tokens=19 total_tokens=657
request=4 kind=conversation input_tokens=773 input_tokens_details.cached_tokens=512 output_tokens=22 output_tokens_details.reasoning_tokens=0 total_tokens=795
request=5 kind=conversation input_tokens=812 input_tokens_details.cached_tokens=640 output_tokens=8 output_tokens_details.reasoning_tokens=0 total_tokens=820
request=6 kind=conversation input_tokens=843 input_tokens_details.cached_tokens=640 output_tokens=42 output_tokens_details.reasoning_tokens=0 total_tokens=885
request=7 kind=conversation input_tokens=1005 input_tokens_details.cached_tokens=768 output_tokens=23 output_tokens_details.reasoning_tokens=0 total_tokens=1028
request=8 kind=conversation input_tokens=1042 input_tokens_details.cached_tokens=896 output_tokens=18 output_tokens_details.reasoning_tokens=0 total_tokens=1060
request=9 kind=conversation input_tokens=1077 input_tokens_details.cached_tokens=896 output_tokens=36 output_tokens_details.reasoning_tokens=13 total_tokens=1113
request=10 kind=conversation input_tokens=1129 input_tokens_details.cached_tokens=896 output_tokens=8 output_tokens_details.reasoning_tokens=0 total_tokens=1137
request=11 kind=conversation input_tokens=1299 input_tokens_details.cached_tokens=1024 output_tokens=41 output_tokens_details.reasoning_tokens=0 total_tokens=1340
request=12 kind=conversation input_tokens=1456 input_tokens_details.cached_tokens=1280 output_tokens=22 output_tokens_details.reasoning_tokens=0 total_tokens=1478
request=13 kind=conversation input_tokens=1494 input_tokens_details.cached_tokens=1280 output_tokens=8 output_tokens_details.reasoning_tokens=0 total_tokens=1502
request=14 kind=conversation input_tokens=1516 input_tokens_details.cached_tokens=1280 output_tokens=35 output_tokens_details.reasoning_tokens=13 total_tokens=1551
request=15 kind=conversation input_tokens=1568 input_tokens_details.cached_tokens=1408 output_tokens=10 output_tokens_details.reasoning_tokens=0 total_tokens=1578
request=16 kind=conversation input_tokens=1765 input_tokens_details.cached_tokens=1536 output_tokens=41 output_tokens_details.reasoning_tokens=0 total_tokens=1806
request=17 kind=conversation input_tokens=1832 input_tokens_details.cached_tokens=1664 output_tokens=28 output_tokens_details.reasoning_tokens=11 total_tokens=1860
request=18 kind=conversation input_tokens=6113 input_tokens_details.cached_tokens=1792 output_tokens=33 output_tokens_details.reasoning_tokens=30 total_tokens=6146
request=19 kind=conversation input_tokens=10367 input_tokens_details.cached_tokens=6144 output_tokens=3 output_tokens_details.reasoning_tokens=0 total_tokens=10370
request=20 kind=compaction input_tokens=15691 input_tokens_details.cached_tokens=10368 output_tokens=2549 output_tokens_details.reasoning_tokens=1302 total_tokens=18240
request=21 kind=compaction input_tokens=15087 input_tokens_details.cached_tokens=14464 output_tokens=1776 output_tokens_details.reasoning_tokens=553 total_tokens=16863
request=22 kind=conversation input_tokens=6922 input_tokens_details.cached_tokens=256 output_tokens=42 output_tokens_details.reasoning_tokens=39 total_tokens=6964
request=23 kind=conversation input_tokens=6982 input_tokens_details.cached_tokens=6784 output_tokens=123 output_tokens_details.reasoning_tokens=110 total_tokens=7105
request=24 kind=conversation input_tokens=7120 input_tokens_details.cached_tokens=6912 output_tokens=147 output_tokens_details.reasoning_tokens=106 total_tokens=7267
request=25 kind=conversation input_tokens=7383 input_tokens_details.cached_tokens=7168 output_tokens=54 output_tokens_details.reasoning_tokens=0 total_tokens=7437
request=26 kind=conversation input_tokens=7454 input_tokens_details.cached_tokens=7296 output_tokens=22 output_tokens_details.reasoning_tokens=12 total_tokens=7476
request=27 kind=conversation input_tokens=7487 input_tokens_details.cached_tokens=7296 output_tokens=6 output_tokens_details.reasoning_tokens=0 total_tokens=7493
cache_hit_requests_after_first=26
PASS protocol=responses multi_turn deferred_tools catalog_add_update_remove compaction approval_deny_allow append_context restore close
PASS: credential absent from HTTP disk cache
```
