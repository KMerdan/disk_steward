# Recovery, pinned-reader pressure and product space accounting

17 September 2026. Continues the G59 checkpoint in `prototype-progress.md`.
**Research evidence, not an implemented production repair or release approval.**

## What changed the decision

Both retained million-file fixtures eventually published generation 2 after
reopening without a pinned reader. Holding a reader transaction open instead
exhausted the research admission reserve in about three seconds. A bounded number
of rows per transaction therefore does not alone bound total database/WAL space.
The next production design needs a reader-lifetime/pressure policy as well as
bounded preparation and reclamation.

SQLite documents that an active reader's fixed end mark can prevent checkpoint
progress and WAL reuse. That explains the observed mechanism; it is not a claim
that the installed app currently holds the same artificial transaction.
[SQLite WAL concurrency and checkpointing](https://www.sqlite.org/wal.html).

## Reproduction identity and phase-local results

- Original v2 baseline: `prototype-v2-million/summary.json`, source hash
  `7d822143a20fc3dd6f8a9a1619152b43d2e89824cfe29a40573b6632dd2f5947`.
- Pinned attempt: `pinned-stream-run/summary.json` and
  `pinned-spool-run/summary.json`, product/test hash
  `0678ce3e7a3290c419ade1acf14fbf03f3af14e0eb78539f907df86df07c1926`,
  frozen `/private/tmp/disk-steward-530-resume-source.vOlhVc`.
- Unpinned recovery: `recovery-runs/summary.json`, product/test hash
  `afb496260788b1da4599ec14be591d9bc46418b5a16f5d7b814c007de7904e92`,
  frozen `/private/tmp/disk-steward-530-recovery-source.ONuocv`.

| Phase / mode | Outcome | Phase elapsed | Names reread | Metadata processed | Peak sampled family |
| --- | --- | ---: | ---: | ---: | ---: |
| Pinned stream | Admission refused, generation 1 preserved | 3.254 s | 48,128 | 48,128 | 534,212,208 B |
| Pinned spool | Admission refused, generation 1 preserved | 2.793 s | 0 | 31,744 | 534,697,432 B |
| Unpinned stream | Generation 2 published | 81.374 s | 1,000,000 | 1,000,000 | 287,066,584 B |
| Unpinned spool | Generation 2 published | 30.582 s | 0 | 321,664 | 231,855,688 B |

The pinned experiments exited XCTest with **failure**, because their original
harness classified the expected `capacity` refusal as an error. Preserve those
failed logs; do not relabel them passing tests. Both post-run databases were
intact with one million visible generation-1 entries. Neither pinned attempt
reached publication, so neither proves old-reader consistency across publication.
The 4 MiB admission reserve is a heuristic, not a proof against every overshoot.

The two recovery processes exited zero and integrity checks passed with exactly
one million visible generation-2 entries. Sampled external RSS was 28,147,712 B
(stream) and 27,738,112 B (spool). The stream restarted its unfinished directory;
the spool resumed from the durable metadata offset. These durations/counters are
**additional recovery work**, not total cost of generating the second snapshot.
The archived baseline and pinned work must also be counted in total-cost claims.

Successful explicit checkpoints took 0.014447 / 0.011363 seconds. Family sizes
before/after were 282,006,216 / 281,190,400 B (stream) and
227,513,208 / 225,972,224 B (spool). Old generation/epoch rows remain physical:
checkpoint success does not prove bounded row reclamation. All resource maxima
are sampled lower bounds; these are single synthetic runs, not product SLOs.

## Harness review, reproductions and corrections

The read-only review job `helper-recovery-review.json` examined the immutable
seven-file snapshot hash
`42b8415db7a3ce8a8e6ee64b1856d7e038440b820e9ab968ffaced617dadc638`.
Its findings were advisory, not an audit approval. Coordinator regressions
reproduced and corrected:

1. Wide-only resume accepted an extra non-root directory path. It now checks at
   most three directory rows and requires exactly the two canonical fixture roots.
   The fixture manifest must also explicitly say `complete: true`.
2. Main-file checks omitted SQLite sidecars. Before SQLite opens, both resume and
   collection now require an allowlisted regular, non-symlink, single-link database
   family. Tests reject WAL/SHM symlinks and hardlinks **before any SQLite open**.
3. Stopped runs emitted zero checkpoint metrics despite no checkpoint. The new
   reporter emits `checkpointState` and nullable measurements; failed checkpoints
   retain the measured before size/time but no fabricated after size. Earlier logs
   are immutable: their zero values mean unmeasured and must not enter size ratios.

`resume-guards-red.log`: 13 tests, seven failing assertions/subtests before the
guard fix. `resume-and-space-guards-green.log`: **21 Python tests pass** after it.
The intermediate sandbox run in `resume-guards-sandbox-denied.log` hit four
process-sampling permission errors, not test assertions; the scoped host rerun
passed. The supervisor terminates its owned child on such sampling failure.

`resume-checkpoint-green.log`: **20 ordinary Swift performance tests pass**, three
opt-in heavy tests skip, zero failures. This includes admission/time-stop null
reporting, failed-checkpoint partial reporting and successful measurement tests.
The new reporter product/test hash is
`ef6dbd7dd9a88b3527b1409de5c705e3acfe10a287dd2ad441b577494e2f15f3`.
The million-file experiments used the earlier hashes above; the reporter-only
tests are not a rerun of those heavy experiments. No production source changed.

After recovery, direct read-only checks found both original databases had safe
single-link families and exactly their two canonical roots, with both generations
published. This finds no evidence of the reviewed escape cases in those fixtures;
it does not retroactively turn the old guard into a sufficient validator.

## Real product schema: 10,000-file accounting

`product-space-run/summary.json` records a fresh completed production-store run
with the disposable open-path index. Source hash is the recovery hash `afb496…`
above; production source itself remains the prior baseline. All 10,000 rows are
present, one observation exists, staging is empty, and integrity is `ok`.

- Elapsed 1.811 s; last store call 1.142 s; 200,000 entries inspected for 10,000
  files (190,000 repeat inspections); peak sampled family 66,591,600 B.
- Post-run main file: 32,980,992 B = 8,052 pages at 4,096 B/page.
- Free/reusable pages: 3,073 = 12,587,008 B. They remain allocated on disk.
- Occupied table/index pages: 4,979 = 20,393,984 B. Post-run WAL is zero bytes,
  SHM 32,768 B. These post-close numbers are not the earlier peak.
- Largest table b-trees: change events 2,744,320 B; current state 2,572,288 B;
  file observations 2,289,664 B; legacy events 1,957,888 B; path bindings
  1,470,464 B. Their separate indexes add more space; the complete breakdown is
  retained in the collection's `tableAndIndexPages` query.

`dbstat` reports table/index b-tree pages, not all disk overhead or WAL; page-count
and freelist measurements are kept separately.
[SQLite DBSTAT documentation](https://www.sqlite.org/dbstat.html).
The collection records its inspection SQLite version separately from the Swift
runtime. Tests check page accounting and the pre-open family guard.

This confirms that speeding up enumeration or adding an index is insufficient.
Do not extrapolate the compact prototype into a one-million-file capacity promise.
The next sizing experiment must preserve object/path identity, producing-pass
provenance, real sample times, uncertain coverage and historical changes while
measuring visible + prepared + history + free/unreclaimed pages + WAL + migration
copies. A schema conversion also needs a bounded, reversible migration path.

## Lossless dictionary-density probe (not a migration)

`dictionary-density-probe.json` records one bounded 10k-file experiment over the
six tables above plus `file_objects`. `probe_dictionary_layout.py` replaces TEXT
values with references into one unique text dictionary, copies rows in pages of
512, retains the source row IDs, recreates the 13 original column/uniqueness index
shapes and reconstructs every selected original SQL value. Each table's ordered
source/reconstructed SHA-256 matches; 60,000 rows total. Real/NULL sample times,
paths, IDs, event intervals and uncertainty strings are not dropped.

- Original six tables and indexes occupy **20,140,032 B** in `dbstat`.
- Destination main file after checkpoint: **8,974,336 B**, zero free pages;
  32,768 B SHM and zero-byte WAL. Sampled family peak 13,206,088 B.
- Elapsed **2.497 s**; process RSS high-water 45,694,976 B on macOS/Python;
  40,009 distinct text values. That dictionary and its unique index account for
  4,689,920 B, more than half the destination main file.
- The scoped three-source-file hash is
  `ac0b0e61d2139d2ab9060f7354df15d84d5d674824e7fecfb557f56c7239118f`.
  Frozen source: `/private/tmp/disk-steward-530-review-fixed.KS9t9t`.
  `recovery-fixed-source/` also retains the exact small research sources.
- `recovery-density-guards-green.log`: **22 Python tests pass**, including a
  NULL/Unicode/empty-text/fractional-time roundtrip and non-overwrite check.

The initial comparison is approximately 55.4% less occupied space for the selected
tables, **not** 55.4% less whole-app peak space. It includes repacking/index-fill
effects; the controlled comparison below supersedes attribution of that entire
gain to encoding. It omits other product tables, prepared generations,
additional history and migration copies, and it does not preserve/enforce the full
schema constraint graph. Integer dictionary order is not lexical path order;
equivalent query behavior requires joins and new measured query plans. The source
had one observation and all files present, so exact roundtrip is not a deleted,
renamed, replaced, multi-root or interrupted-state migration matrix. No linear
one-million-file estimate is claimed as measured capacity.

Engineering consequence: interned references are a useful component, but generic
all-text interning alone is not a justified full design. Evaluate typed internal
identities, shared immutable metadata versions and normalized parent/name paths;
keep historical public identities and observation/coverage semantics recoverable.
Budget actual dictionaries and indexes rather than assuming deduplication is free.

The static review found this attribution confound and a budget-check cadence
defect. The corrected probe adds a fresh **plain control**, with identical source
page size, source-rowid copy and index construction order. It also checks budgets
every 512 processed rows regardless of sparse rowid values and performs final
metadata queries before capturing final resource/time measurements. A dedicated
sparse odd-rowid spy observes checks after rows 512, 1024 and 1025.

The final scoped three-file hash is
`6c83caca4102d9d9a72247c6c7f8c051794c2c2419f894f10a6cb50bdbf40fad`,
frozen at `/private/tmp/disk-steward-530-density-matched.7JbdkT` and retained in
`density-matched-source/`. `dictionary-final-plain.json` and
`dictionary-final-encoded.json` record the final-source rerun:

| Same 60,000 original SQL rows | Plain fresh rebuild | Dictionary fresh rebuild |
| --- | ---: | ---: |
| Post-checkpoint main file | 19,435,520 B | 8,974,336 B |
| Peak sampled database family | 20,424,632 B | 13,206,088 B |
| Elapsed including reconstruction and final queries | 0.587 s | 2.484 s |
| Process RSS high-water | 41,402,368 B | 42,123,264 B |

Every ordered table hash matches across both reconstructions. The controlled
occupied-space reduction is **53.8%**, while this one-run encoding/reconstruction
cost is higher. This still proves neither lexical-query performance nor complete
product/migration capacity. `recovery-density-final-green.log` records **23 Python
tests passing**. The earlier 22-test logs and initial probe stay as historical
evidence; do not relabel them the final candidate. Static review is advisory and
cannot replace these measured checks or the product audit.

`helper-density-delta-result.json` passes result-schema, job identity and budget
validation (zero findings, six evidence items). The coordinator confirmed matching
canonical/frozen three-file hashes and the live G59 task guard before reconciliation,
and independently checked equality of all six paired table counts/hashes/index
counts. Accepted as narrow advisory review of the corrections, not final audit
evidence; the raw result remains pending/ineligible. Exclusive source ownership
is a requirement: the probe does not hold a cross-table read transaction.

## Remaining gate

RESEARCH-530 remains working/unverified. Product-equivalent normalized preparation,
bounded reclamation and migration/rollback costs are not yet established.
TASK-531/TASK-532 must not be claimed complete from these results. No installation,
real client/evidence changes, commit, push or release occurred.

## Fixture lifecycle at this checkpoint

Terminal benchmark handles: recovery session 61019, collection 4024, production
10k run 13810, density probe 49070. Exact-path `lsof` returned no holders for the
three completed source databases before cleanup. Session 93296 then removed the
two million-file roots using archived hashes and tokens;
`recovery-runs/cleanup.json` preserves the record. Only generated synthetic files
were removed; they can be regenerated and were not moved to Trash.

The 10k source `/private/tmp/disk-steward-530-scale.hlbli48j` and final matched pair
`/private/tmp/disk-steward-530-layout.5122brhn` (plain) and
`/private/tmp/disk-steward-530-layout.cua9ml60` (dictionary) remain intentionally
available for the next sizing/query experiment. Final matched run session 45492
is terminal. The source must be cleaned through `product-space-run` after use;
the destination leaves are separately owned probes, not general cleanup targets.
The three obsolete probe leaves (`w38lo80g`, `y3ayqlp6`, `j7o8_rhh`) were removed
after their sessions ended and logs were archived. Each contained only its
generated `evidence.sqlite`; exact-file removal and then `rmdir` were used, not
a broad recursive deletion. Their data is reproducible, not moved to Trash.

## Canonical progress record

`EVENT-20260917T101318068535Z-D25B7D86` records this progress at R8/G60 through
Pyramid's `update --status at-risk` interface. RESEARCH-530 remains working,
unverified and owned by `codex`; this is not an implementation-completion claim.
Task guard: `GUARD-TASK-C2E48DEF4FEC113B267DA33DF1900E98`; context:
`CTX-2325BA16647836AF33EE9984BFED1696`. The existing lease expires at
`2026-09-17T10:14:53.839960Z`; a progress update does not renew it. Reinspect and
reclaim through the runtime if expired before continuing the next experiment.

Validation passes. History doctor reports 11 records, 6 chronicles, zero bindings,
no pending transaction and no errors. No closed-intent history was rewritten.
`progress-inventory.json` lists 256 cumulative research source/evidence paths for
the eventual worker result; it is not a substitute for that final provenance
submission. Current helper review was reconciled before this guard-changing
progress mutation and remains advisory, not fresh final audit evidence.
