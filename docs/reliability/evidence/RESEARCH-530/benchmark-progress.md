# RESEARCH-530: measured baseline and index probe

17 September 2026. **Research in progress; no production storage design selected.**
This report records new measurements, not completion of TASK-531/TASK-532 or an
audit pass. No installed app, user evidence, client configuration, Git commit,
push, signing identity or release changed.

Later work is recorded in [prototype-progress.md](prototype-progress.md): two
research alternatives, reproduced retry defects, corrected regressions and fresh
directory/deep-tree scale results. The baseline results below remain unchanged;
their cleanup statements apply to this earlier matrix only.

## Candidate, scope and safety

Production baseline is the accepted TASK-522 candidate
`b3b546fb1c09a77825ab564ef449fc748e216a36f03bbfe5871e85d0c8c54d21`.
The measured candidate adds only `Tests/PerformanceTests/ScaleBenchmarkTests.swift`
to that product/test file set; hash
`28aaa4e041537dbec042ad4b61d31440fda0fe8876e789ec091a935ef3ca13c9`.
Frozen source: `/private/tmp/disk-steward-530-measured.x9zJqC`.
Execution copy: `/private/tmp/disk-steward-522-lifecycle-dev.9CYz1T`.
Canonical, frozen and execution product/test hashes match. The TASK-522 hash
recipe is unchanged; research documentation/scripts are recorded separately.

The main measurements and compact raw evidence are in `runs-v1/summary.json`.
Earlier `pilot-runs/summary.json` uses instrumentation predecessor
`30b43a5e24d9433a7ba522a11a9bc61f3682410ff304a7eb4a00ef6fa70354c4`.
Its product sources are the same, but it lacks explicit frontier-byte and
pre-publication telemetry. Do not substitute it for the current instrumented
candidate. The first harness launch was safely rejected because Foundation
abbreviates `/private/tmp` to `/tmp`; using filesystem `realpath` fixed the
ownership check. That failed launch is not a performance result.

The harness follows the actual `beginOrResumeScanGeneration → scanSlice →
recordScanSlice` path, including validation and publication. The app's periodic
scheduler/notifications/IPC are not run. Batches remain 512 entries, depth 64,
default storage admission 512 MiB; no product limit was raised. The index probe
only adds `research_path_bindings_open_object_path` in a disposable database.

External supervision and fixture details are documented in
`../../benchmarks/README.md`. Six small supervisor regression tests pass. Heavy
XCTest skips without explicit supervised opt-in. External cutoffs are sampled;
the deep-tree trial overshot its 768 MiB stop threshold before the next poll.
This overshoot is retained as evidence, not hidden by reporting the threshold
as measured usage. The test runner uses a minimal child environment; an earlier
help invocation unexpectedly dumped the parent environment. That output was
not copied into research artifacts and the user was advised to rotate the
exposed credential.

## Results

Times below exclude fixture creation. Peaks are the maximum available in-process
or external sample, not exact operating-system high-water marks.

| Workload / variant | Result | Time | Directory entries inspected | Peak DB family | Important observation |
| --- | --- | ---: | ---: | ---: | --- |
| 10k files, wide / baseline | Published 10k | 5.939 s | 200,000 | 61.45 MiB | Final store call 5.300 s; scanning 0.398 s |
| 10k files, wide / index | Published 10k | 1.705 s | 200,000 | 63.58 MiB | Final store call 1.068 s; scanning 0.402 s |
| 100k files, wide / baseline (matched candidate) | External timeout; no publication | 60.032 s including runner | 19,600,000 before final call | 122.72 MiB sampled | Scanning finished by 12.797 s; final call did not return before termination; 100k staged rows survived |
| 100k files, wide / index | Published 100k | 24.215 s | 19,600,000 | **603.53 MiB** | Final store call 11.388 s; external RSS 123.73 MiB; exceeds the unchanged 512 MiB product storage budget |
| 100k empty directories / baseline | Product-RSS stop; no publication | 5.916 s | 3,200,000 | 7.61 MiB | Only 16,384 entries processed; frontier 16,385 cursors / 1,540,363 JSON bytes; in-process RSS 150.91 MiB |
| 100k files, 32-level chain / index | External DB-family stop | 27.793 s including runner | 709,595 before final call | **880.41 MiB** | No final XCTest result; durable inspection found a complete 100k publication already committed |
| 1M files, wide / baseline | Cooperative time stop; no publication | 45.219 s | **142,000,000** | 89.33 MiB | 72,704 files processed; 141,927,296 repeated inspections; scanning took 42.776 s |

The earlier 100k-wide baseline was externally stopped at 60.040 s. All 100k
staged rows survived, with zero current rows/observations and database integrity
`ok`. It is preliminary because its instrumentation predates the main matrix;
a matched-candidate rerun in `matched-baseline/summary.json` independently confirms
the timeout at 60.032 seconds, zero publication, 100k durable staged rows and
integrity `ok`. Its last pre-publication row reports 19.6 million inspections and
12.797 seconds elapsed before the final store call.

The main matrix's completed runs passed their durable-count, staging-empty and
integrity assertions. Incomplete fresh runs had zero current rows/observations.
Post-run read-only checks report integrity `ok` for every main-matrix database.
The deep trial is deliberately **not** called a passing benchmark: its process
was stopped on storage growth, but the atomic COMMIT had already completed.
Count/current-generation observations after reopening distinguish that outcome
from an interrupted transaction. A supervisor stop alone cannot establish which
side of COMMIT was reached.

## Evidence-backed conclusions, not yet a selected design

1. **Repeated directory reading is measured.** The million-file prefix inspected
   all one million names 142 times while processing only 72,704 names. This is
   work amplification, not useful progress. A bounded retained-name heap alone
   does not bound total enumeration work.
2. **Publication has a separate lookup problem.** Both system `sqlite3` and the
   post-run reader's query plans show a full `path_bindings` scan for open-path
   counts. The disposable partial index changes this to an object-key lookup.
   At 10k, publication fell from 5.300 to 1.068 seconds with similar scan time.
   Single-run timings are indicative, not a promised 5× app speedup. The index
   is a justified candidate component, not a complete scale fix.
3. **The pending-directory representation is not resource-bounded by batch size.**
   Empty directories hit the memory threshold with no staged file metadata at
   all. Full-frontier decoding/copying/serialization and telemetry overhead need
   separate measurement; this run does not attribute every retained byte to a
   particular allocation site or recreate the historical OOM.
4. **Current admission underestimates publication's transient storage.** A wide
   100k publication reached 603.53 MiB; deeper, longer paths reached 880.41 MiB.
   Checks around a large transaction and rough row estimates do not enforce the
   desired physical DB/WAL budget. Raising the cap is not the selected answer.

## Primary-source constraints

Apple's directory API documentation says directory position cookies do not
survive closing and reopening their originating stream. A persisted opaque
`telldir` value is therefore not a valid durable restart design. A process-local
stream candidate must invalidate unfinished pass membership on handle loss or
restart. [Apple directory operations](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/seekdir.3.html)

SQLite documents that readers can prevent WAL reuse, and that a large write
transaction cannot reset its WAL midway through the transaction. That supports
measuring preparation, retained readers and final publication separately; it
does not justify removing atomicity. [SQLite WAL](https://www.sqlite.org/wal.html)

## Preflight reconciliation

The returned read-only preflight envelope matches the job's helper ID, task,
guard, immutable TASK-522 snapshot, phase and budgets: six findings, eleven
evidence items, 7,352 compact JSON characters, no changed files/assets. Both
schemas validate. Raw evidence remains advisory/pending/ineligible, not an audit.
The coordinator independently read the scanner diagnostics, full-directory
selector, generation persistence, reconciliation loop and test entrypoints
before choosing measurements. In particular the harness follows the returned
commit generation, includes empty-directory fanout, separates scan/store timing,
and never counts scanner completion as publication.

The helper's alternatives have not been implemented or benchmarked. Its static
advice is not evidence that either scales or preserves behavior.

## Next required work / ownership

`RESEARCH-530` remains owned by `codex`; acceptance is not yet met.

1. Compare a bounded process-local directory stream with a disk-backed name spool,
   each coupled to indexed durable work rows and bounded dequeue/delta persistence.
   Do not merely store rows and then decode the entire queue back into Swift.
2. Measure full cost, including spool construction, restart/revalidation, frontier
   storage, file metadata sampling and publication. Keep the index component
   explicit so its benefit cannot be misattributed to enumeration changes.
3. Prototype bounded preparation plus an atomic visible-generation switch; measure
   current + preparing + WAL + recovery-copy space. Migration/rollback and pinned
   reader costs must be budgeted, not assumed away. Current event/history payload
   duplication may prevent 1M files fitting the existing cap; test, do not assert.
4. Add unchanged second-generation, mutation, restart, overlapping/failed-root,
   cancellation and rollback checks before recommending a production design.
   Preserve pass ownership, real sample times, dirty-receipt fences and unknown
   versus absent semantics. A toy faster enumerator does not satisfy this gate.
5. Reconcile measurement overhead, repeat representative runs and confirm 1M
   completion under the product budget, or explicitly leave implementation
   unapproved with the measured constraint. Then submit the research result
   through Pyramid; do not bypass pending asset inspections or release gates.

Generated fixture roots are listed in each collected record. No user files were
removed. After every benchmark process handle was confirmed terminal, the
coordinator previewed exact targets, verified owner tokens and archived hashes,
then removed all nine collected run roots (including their synthetic databases).
`runs-v1/cleanup.json`, `pilot-runs/cleanup.json` and
`matched-baseline/cleanup.json` retain that lifecycle. The separately failed
ownership-check pilot `/private/tmp/disk-steward-530-scale.mdfkh37n` was also
inspected, its logs/manifests archived in `ownership-check-red/`, then removed.
These are reproducible generated data, not personal files; they were not moved
to Trash. Compact evidence and the frozen source/build trees remain. All ten
dataset roots from this research turn are gone; there is no live benchmark or
cleanup process to resume.

## Canonical progress and verification handoff

At G58 the runtime recorded `task.at-risk` event
`EVENT-20260917T084805431580Z-51BC37CE` with this report as its evidence reference.
Execution remains **working**, verification **unverified**, owner **codex**;
this is a measured risk flag, not a blocked execution or implementation claim.
Task guard: `GUARD-TASK-BACAFCFA003B73489525B42E8C89C865`.
Context: `CTX-722B22DDD053E4124372563FD2D1F5E0`.
Lease remains `2026-09-17T10:14:53.839960Z`; refresh the smallest node packet
before continuation if state has changed.

`normal-performance-tests.log` records the accepted optimized candidate's
ordinary performance target: **five passed, one heavy opt-in skipped, zero
failures**, 1.719 seconds, session 87067 exit 0. The virtual 72-hour test is still
not a real overnight soak. `supervisor-tests.log` records six passing supervisor
tests. `build-and-opt-in-skip.log` proves the benchmark compiles and is skipped
by default. No whole-suite rerun is claimed for this instrumentation-only change;
the preceding TASK-522 full-suite evidence remains scoped to its own hash.

After the progress mutation, Pyramid validation passes at R8/G58. History doctor
reports eleven records, six chronicles, zero bindings, no pending transaction
and no errors. No final intent chronicle or clean-commit binding is claimed.
`git diff --check` passes. `progress-inventory.json` inventories authored/evidence
files for later worker-result provenance; it is not an `agent-result-v1`
implementation submission and does not change canonical task completion.
