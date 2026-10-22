# Durable Swift acceptance

The portable Generic and Durable public contracts are implemented and qualified through the Swift SDK, native core, SQLite persistence, selected unchanged upstream assertions, and native process-recovery tests. The mapping below supports the Durable and Generic status in [MIGRATION.md](MIGRATION.md). It does not claim that every original JavaScript test file or a deployed queue provider passed.

## Behavior mapping

Original references use these source files:

- `core`: [test-durable-core.mjs](../sdk/tests/test-durable-core.mjs)
- `durable`: [test-durable.mjs](../sdk/tests/test-durable.mjs)
- `world`: [test-world-persistence.mjs](../sdk/tests/test-world-persistence.mjs)

Native test names establish the corresponding Swift behavior. Selected original assertions run through the conformance bridge; other original scenarios have native equivalents or the representation boundaries described below.

| Portable behavior and original references | Swift implementation | Direct acceptance evidence |
| --- | --- | --- |
| Atomic acceptance, stable IDs, ordered execution, deduplication, and replay. core:277,416,440,474,1206,1234,1473,1527; durable:499,517,532,549 | `FxSession`, `FxSessionTurn`, `FxAgent.execute`, and `FxSessionStore.accept/next/start/finish` | [SessionStoreTests](Tests/LibFxTests/SessionStoreTests.swift): `intakeIsDurableOrderedAndDeduplicated`, `replayRetainsAcceptedInputAfterDuplicateAndDatabaseReopen`; the final withdrawal and image-retry tests below. |
| Validation before effects, cancellation before commit, commit winning a cancellation race, and the combined input/context/settings limit. core:1143,1165,1183,1568,1947,1960; durable:1665,1684,1841,1804 | `FxAgent` admission and complete-input transactions in `FxSessionStore` | [IntakeCancellationTests](Tests/LibFxTests/IntakeCancellationTests.swift): `cancellationBeforeCommitLeavesTheIDReusable`, `cancellationAfterCommitPreservesAcceptedInput`, each for prompts and steering; [SessionInputAdmissionTests](Tests/LibFxTests/SessionInputAdmissionTests.swift): `typedJSONAndContextAndSettingsShareOneInclusiveLimit`, including the exact limit and one byte either side. |
| Session/store isolation, named routing, compatible replicas, and conflicting configuration rejection. core:324,346,368,387,404,1810,1824,1894,1911–1935,2013,2039,2064,2096,2113 | `FxAgentRouter`, name validation, and the shared `FxAgentAdmission` domain | [AgentAdmissionTests](Tests/LibFxTests/AgentAdmissionTests.swift): `hostIdentityAllowsCopiesAcrossDirectAndRoutedConstruction`, `identityNeverOverridesStructuralDifferences`, `separateConnectionsAndProxiesUseTheHostsSharedAdmissionDomain`; unchanged named-routing assertions in [generic-routing.mjs](Tests/Conformance/generic-routing.mjs). |
| Independent views, cursor resume, lazy reads, reader cancellation, and read errors. core:549,771,1017,1663; durable:906,952,976 | `FxSessionEvents` reads on iterator demand; view cancellation leaves execution running | [AgentTests](Tests/LibFxTests/AgentTests.swift): `resumedViewStartsAfterAlreadyObservedOutput`, `closeDrainsAcceptedWorkAndReaderCancellationDoesNotCancelIt`; [DurableVisibilityTests](Tests/LibFxTests/DurableVisibilityTests.swift): `subscriberBeforeIntakeSeesFirstCommitWhileProviderIsHeld`; the final denied-read test below. |
| Acceptance and completed results remain independent of unrelated journal loads. core:925,974; durable:925 | Separate input, result, and journal operations in `FxAgent` and `FxSessionStore` | [DurableRecoveryBoundaryTests](Tests/LibFxTests/DurableRecoveryBoundaryTests.swift): `acceptanceAndFirstResultDoNotWaitForAnUnrelatedJournalLoad`; [DurableVisibilityTests](Tests/LibFxTests/DurableVisibilityTests.swift): `completedResultAndEndReplayDoNotRequireAnotherJournalLoad`. |
| Text/image steering placement, scoped cancellation, idle wakeups, and pending steering recovery. durable:683–885,994–1181,1216,1260 | `FxAgent` controls, atomic steering marks, and native turn steering | [DurablePlacementTests](Tests/LibFxTests/DurablePlacementTests.swift): `twoWaitingPromptsPlaceLaterSteeringOnlyInTheSecondTurn`, `idleTextSteerSurvivesProducerCloseAndDuplicateWakeups`; [DurableRecoveryBoundaryTests](Tests/LibFxTests/DurableRecoveryBoundaryTests.swift): `snapshotRefusalRetainsUnplacedSteeringAcrossDatabaseReopen`. |
| Yield, delivery deadlines, executor replacement, failed starts, stop budgets, opening outages, and slow close. core:291,305,457,574–810,1518,1623; durable:1292,1329,1369,1387 | `FxAgent` delivery/recovery and the durable session/turn protocols | [DeliveryTests](Tests/LibFxTests/DeliveryTests.swift): `cooperativeDeliveriesKeepOneTurnAndRunEachToolOnce`, `stalledModelStopsAfterThreeCutoffsAndSessionContinues`; [HarnessRecoveryTests](Tests/LibFxTests/HarnessRecoveryTests.swift); [TerminalCleanupTests](Tests/LibFxTests/TerminalCleanupTests.swift): `nextInputRunsDuringTerminalCleanupAndAgentCloseJoinsEveryEngine`; unchanged cases in [generic-core.mjs](Tests/Conformance/generic-core.mjs). |
| Independent lease renewal, expiry, stale-effect admission checks, and stale-write fencing. durable:577,598,628,659,1547; world:225 | Optional `FxSessionLeasePolicy`, `SessionLeaseGuard`, guarded storage/HTTP/tool boundaries, and SQLite ownership | [AgentLeaseTests](Tests/LibFxTests/AgentLeaseTests.swift): `lostRenewalCancelsNativeHTTPAndSuccessorResumesWithoutRepeatingAnEffect`, `heldNativeHTTPRemainsOwnedAcrossSeveralLeaseDurations`; [AgentOwnershipAdmissionTests](Tests/LibFxTests/AgentOwnershipAdmissionTests.swift): `staleSuccessfulOwnershipReplyCannotAdmitEffectsOrWrites`; [SessionLeaseTests](Tests/LibFxTests/SessionLeaseTests.swift) covers stalled renewal and post-await expiry. |
| Authenticated queue redelivery, higher/equal-attempt takeover, bounded release recovery, and delivery membership. core:517,1698,1741,1776; durable:1504,1547 | `FxQueueDeliveryAuthority`, `FxQueueDeliveryContext`, atomic queue claims and invocation ledger, and `FxAgent.releaseOwnership` | [QueueOwnershipTests](Tests/LibFxTests/QueueOwnershipTests.swift) covers replacement, live owners, races, stale writes, and context reuse; [ReleaseRetryTests](Tests/LibFxTests/ReleaseRetryTests.swift): `nativeToolYieldRecoversReleaseWithoutReplayingTheTool`; [native-queue-redelivery.mjs](Tests/Conformance/native-queue-redelivery.mjs) uses SIGKILL and a new Swift process for higher/equal-attempt takeover before the old lease expires. |
| Journal compare-and-swap, atomic marks/completion, checkpoint compaction, and process recovery without repeated completed effects. core:848,888; durable:1235,1402,1450,1572,1601,1647,2097,2113,2150,2162; world:169,225,252,297 | `FxSessionStore.appendJournal/saveJournalCheckpoint`, `FxPersistenceSnapshot.completedTurnID`, and native journal restoration | [OpaqueCompletionTests](Tests/LibFxTests/OpaqueCompletionTests.swift): `completionSurvivesReopeningAndCheckpointCompaction`, `completionIsAtomicAndFencedWithItsRecord`, `settledJournalDoesNotRepeatWhenPublicResultWriteFailed`; [generic-fresh-host.mjs](Tests/Conformance/generic-fresh-host.mjs), [sqlite-crash.mjs](Tests/Conformance/sqlite-crash.mjs), and [agent-crash.mjs](Tests/Conformance/agent-crash.mjs) use fresh native processes. |
| Image preparation, content-addressed restoration, image steering/tool results, limits, and storage faults. core:1222,1361–1487; durable:1708–1981 | `ImagePersistence`, `FxEngine` image restoration, scoped image storage, and complete-byte input intake | [ImagePersistenceTests](Tests/LibFxTests/ImagePersistenceTests.swift): `sqlitePicturesSurviveReopeningWithSmallCheckpoints`, `failedPictureWritePreservesItsErrorAndNeverSendsThePrompt`, `toolPicturesKeepTheirBytesWhenStorageFails`; [OpeningRetryTests](Tests/LibFxTests/OpeningRetryTests.swift): `transientStoredImageReadReopensTheSameAcceptedTurn`; the final damaged-history and image-retry tests below. |
| Typed Codable inputs/updates, opaque journals, custom checkpoints, structured terminal failures, and persisted settings/context. core:1031,1062; durable:2040,2065,2084 | `FxDurableAgent`, `FxDurableHarness`, `FxDurableSession`, `FxDurableTurn`, and separate `FxSessionOptions.settings/context` | [DurablePayloadTests](Tests/LibFxTests/DurablePayloadTests.swift): `typedInputUpdatesReplayAndRepeatedIDsUseTheSharedWorker`, `terminalResultPreservesStructuredFailureWithoutThrowingOrRetrying`; [CustomHarnessSettingsTests](Tests/LibFxTests/CustomHarnessSettingsTests.swift): `eachInputRetainsSettingsAndContextAcrossSQLiteRecovery`; [SessionHarnessTests](Tests/LibFxTests/SessionHarnessTests.swift) verifies opaque persistence and marks. |
| Native tool read/write ordering and durable intent before external effects. durable:1572,1601; world:188,252 | Native core barriers, journal acknowledgements, and ownership checks | [ToolContractTests](Tests/LibFxTests/ToolContractTests.swift): `nativeToolAdmissionHonorsReadOverlapAndWriterBarriers`; [JournalAdmissionTests](Tests/LibFxTests/JournalAdmissionTests.swift): `nativeCoreControlsDurabilityBeforeToolExecution`, `failedIntentAfterReadAdmissionStopsFurtherModelRequests`, `cancellationDuringWriteBarrierNeverStartsTheEffect`. |

## Final fault and ordering acceptance

[DurableFinalAcceptanceTests](Tests/LibFxTests/DurableFinalAcceptanceTests.swift) closes the remaining combined evidence gaps with real Swift execution and SQLite persistence. Test-local callbacks control host reads or HTTP timing; the SDK owns scheduling, journal writes, and results.

| Test | Verified result |
| --- | --- |
| `deniedHistoryReadFailsOnlyItsViewAndUnreadResultDoesNotReadEntries` | A denied `entries` read throws the original error. The native turn still completes, an unread result performs no entry reads, and a later view replays the output. |
| `withdrawingMiddleInputKeepsThirdBehindHeldFirst` | With the first model request held, cancelling the second input leaves the third waiting. Only first and third content reach the model, in order; all three inputs receive exactly one terminal result. |
| `damagedSavedImageHistoryStopsEffectsAndRepairsTheSameInput` | Missing and corrupt saved images produce `.missingImage(hash)` and `.corruptImage(hash)` before model dispatch. The input remains pending. Corrected host reads resume the same ID once, and a subsequent text turn succeeds. |
| `completedImageRetryBypassesAWriterThatNowFails` | Retrying a completed image ID after reopening returns the repeated result without another image write or model request, even when the writer now rejects every write. |

These four test functions contain five concrete cases. Both the normal and Thread Sanitizer runs passed; the sanitizer run reported no race.

The corrupt-history case exposed a production defect: native image rejection was classified as a terminal executor-opening error and consumed the waiting input. `FxEngine.open` now checks the loaded bytes against their content-addressed name before uploading them and throws `FxPersistenceError.corruptImage(name)`. The error follows the recoverable persistence-fault path. The same acceptance assertions pass after this correction.

## Interface boundaries

Swift accepts complete typed image bytes atomically with the input. The JavaScript implementation can upload an image separately, then accept an input that names it. Its upload-before-accept failure semantics and physical file layout therefore do not map directly to Swift. Swift proves cancellation before/after the complete-input commit, image-write fault safety, and recovery of damaged committed history after the host repairs its read. It does not discard damaged history to run later prompts.

Native snapshots refuse unsafe compaction while steering remains unplaced; the full journal preserves it across reopening. JavaScript's folded-snapshot representation is not required. World in-band event counts, page/cache read counts, Node global registration, legacy image filenames, and fixture-private fault hooks likewise have no identical Swift interface. The tests establish the corresponding public ordering, fencing, recovery, and no-repeat contracts without claiming every original World assertion ran.

The host supplies queue authentication and verifies delivery metadata. Plain HTTP JSON cannot grant takeover authority. Local SQLite and SIGKILL tests establish how Swift processes a verified grant; they do not qualify a provider's production authentication, acknowledgement, same-attempt rerun, or request-lifecycle guarantees. Swift cancellation is cooperative, and expiry fencing cannot forcibly terminate an arbitrary host callback.

## Reproduce the checks

Run from the repository root with the package's native core archive available, as described in [VALIDATION.md](VALIDATION.md). Use separate scratch directories:

```sh
durable_scratch="$(mktemp -d "${TMPDIR:-/tmp}/libfx-durable.XXXXXX")"
swift test --package-path swift --scratch-path "$durable_scratch/normal" \
  --no-parallel --filter DurableFinalAcceptanceTests
swift test --package-path swift --scratch-path "$durable_scratch/thread" \
  --sanitize thread --no-parallel --filter DurableFinalAcceptanceTests
```

To rerun the selected upstream assertions and native process companions, build the driver and discover its path through SwiftPM:

```sh
swift build --package-path swift --scratch-path "$durable_scratch/driver" \
  --product FxSwiftDriver
export LIBFX_SWIFT_DRIVER="$(swift build --package-path swift \
  --scratch-path "$durable_scratch/driver" --show-bin-path)/FxSwiftDriver"
node swift/Tests/Conformance/run.mjs
```

The conformance runner retains its selected assertions and checks child termination and stderr. Its selected entry count is not a percentage of functional acceptance.
