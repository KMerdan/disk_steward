# TASK-612 — A classified object is a leaf, not a directory to enter

Actor: `claude`, 2026-09-20. Focused runs on input `214cd35120…`; the scale run and the full verifier are recorded below. Every run is an isolated snapshot under `/private/tmp`; no real project tree and no live evidence database were touched.

## What changed

`DirectoryMetadataScanner` takes an optional `ObjectClassifier`. When a child directory carries a candidate name, the scanner asks the classifier once and acts on the answer:

- **object** — recorded in `MetadataScanSlice.objects` and **not entered**. Everything beneath it stops being scan work.
- **unresolved** — scanned as an ordinary directory and reported in `MetadataScanSlice.unresolvedCandidates`. Doubt means looking, not skipping.
- **source** — scanned as an ordinary directory, because a repository tracks it.

The repository that owns a directory is resolved once per parent and remembered for the rest of the slice, so classification costs one walk up the tree per directory rather than one per child.

`EvidenceStore.recordScanSlice` publishes `slice.objects` as object rows in the same transaction that commits the slice. An object therefore appears as soon as the slice that found it commits, rather than waiting for the whole generation.

A `nil` classifier keeps the previous behaviour of entering everything, which is what the existing scale and soak fixtures use as their baseline.

## Proofs (AC-TASK-612-01)

| case | test |
|---|---|
| an object is recorded whole and nothing inside it is scanned | `testAnObjectIsRecordedWholeAndNothingInsideItIsScanned` |
| scan work does not grow with what is inside an object | `testScanWorkDoesNotGrowWithWhatIsInsideAnObject` |
| tracked source that looks like output is still scanned | `testTrackedSourceThatLooksLikeOutputIsStillScanned` |
| an unresolved candidate is scanned and reported | `testAnUnresolvedCandidateIsScannedAndReported` |
| a generation completes and publishes its objects | `testAGenerationCompletesAndPublishesItsObjects` |

Five tests, zero failures (`focused-green/`). The second is the one that states the property in a way that cannot drift: the same tree twice, one object holding 10 files and the other 400, must process the same number of entries.

## Scale (`scale-run/`)

A fixture of 12 projects, each with a `node_modules` of 90,000 entries: **1,080,000 entries behind objects**, plus 252 ordinary files.

| | |
|---|---|
| generation status | `completed` |
| slices needed | 1 |
| wall clock | 0.7 s |
| entries processed | 288 |
| objects published | 12 |
| per-file rows | 252 |
| **per-file rows inside an object** | **0** |

The comparison that matters is with the installed 1.2.1 app on the same maintainer's disk: a generation opened on 18 September was still active 39 hours later, having processed 17,365,812 entries without ever publishing (`EV-604-STUCK-SCAN`). The scale case is the opt-in `ObjectScanScaleTests`, which refuses to run without a supervisor-owned fixture and its ownership token, so an ordinary test run never builds a million files. The fixture was removed after the run; `scan-result.json` and the suite log are archived.

## Non-vacuity

| mutation | result |
|---|---|
| the scanner enters objects again instead of recording them whole | three tests fail, including the cost-independence case (`enter-objects-mutation-red/`) |
| a committed slice no longer publishes the objects it found | `testAGenerationCompletesAndPublishesItsObjects` fails (`publish-objects-mutation-red/`) |

## Limitations

- Objects are published without aggregates: `logical_bytes` is zero and `measured_at` is absent until `TASK-621` measures them. A reader must not present an unmeasured object as having no size.
- The classifier is wired into the scanner but not yet into the app's monitoring probe, so the installed app's behaviour is unchanged until that wiring lands.
- The scale fixture is synthetic and uniform. It proves the cost of an object is independent of its contents; it does not model the variety of a real disk, which `RESEARCH-601` measured separately.
- Collapsing the per-file rows an existing installation already holds is `TASK-613`'s migration, not this task.
