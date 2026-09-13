# TASK-251 real export journey

## Outcome

The status-board and utility-menu **Export Current Evidence** action now use the
durable `EvidenceStore` database and `EvidenceBundleExporter`. The retained
`SnapshotExporter` entry point exists only for compatibility tests and the
explicitly named capacity diagnostic; production UI actions do not call it.

## Exercised journey

`StatusBoardEvidenceExportTests.testActualViewModelPathExportsDurableBundleRevealsItAndRecordsManualOwnership`
creates a real SQLite evidence store, records a partial observation containing a
current file, invokes the same asynchronous view-model closure used by the menu
bar UI, waits for completion, and verifies:

- the UI exposes an in-progress state and then a success result;
- the completion callback receives the finished bundle URL, which production
  wiring passes to Finder;
- the manifest contains all eleven evidence payloads and not the legacy
  capacity-only file set;
- `coverage.json` discloses the configured root and the open partial-coverage
  limitation;
- `current-state.json` contains the exact retained file record;
- the database inventory owns the export as a manual, available bundle with its
  path and manifest digest.

The companion failure test verifies that an unavailable or throwing exporter
reports failure and always clears the busy state.

## Human and agent usefulness

`codex-brief.md` now opens with the scope boundary and evidence age, then lists
largest current directories and files, measured growth or an explicit
unavailable statement, cleanup-review leads, notable retained events,
provenance limitations, and an ordered inspection path. Machine-readable exact
records remain in the bounded payloads; the brief does not pretend that
whole-volume capacity means whole-disk file visibility.

The summary intentionally excludes export-generation time so otherwise
equivalent evidence views remain deterministic. Generation time remains in the
manifest and the human brief. No file contents or environment values are read
or exported.

## Active scan generation semantics

The schema-v5 repair adds an explicit distinction between the latest completed
observation and an in-progress filesystem scan. A bundle exported while a scan
generation is active now identifies the generation, its start time, completed
root count, total root count, processed-entry count, and staged-file count. The
bundle forces file-detail coverage to `partial` and states that absence has not
yet been reconciled, so an agent cannot mistake the preceding completed state
for a current exhaustive observation.

`EvidenceBundleExporterTests.testExportDuringActiveGenerationDisclosesProgressAndKeepsPriorStateStale`
creates two watched files, advances a durable generation by one bounded entry,
and exports before the generation completes. It verifies that the staged file
does not leak into authoritative current state, active progress and limitations
are present in both machine-readable coverage and the human brief, and all
payload hashes remain valid. This is the export-side proof for the A/B/C
reconciliation lifecycle implemented by TASK-250.

## Verification

- Targeted exporter regression set: 9 tests passed, 0 failures.
- Full Swift package suite: 156 tests passed, 0 failures.
- Xcode Debug application build: succeeded and signed with the configured Apple
  Development identity.
- Scoped `git diff --check`: passed.
