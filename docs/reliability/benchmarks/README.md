# Isolated scale research

These are opt-in research tools for `RESEARCH-530`, not app benchmarks that
open real watched folders, and not an approved production redesign.

## Research traversal variants

`--variant stream` and `--variant spool` execute `BoundedTraversalScaleTests`
against a separate normalized experimental schema, not the product store. Stream
keeps one process-local directory handle and restarts an unfinished pass under a
new epoch after reopen. Spool first persists names in bounded pages, then samples
metadata from that durable page sequence. Neither persists an opaque directory
cookie. Both use indexed directory work rows and an atomic visible-generation
pointer. `--generations 2` charges unchanged second-generation construction plus
bounded scratch-name reclamation; it is supported only for these variants.

These prototypes omit product occurrence/history/attribution, multi-root merging,
retention and migrations. Storage is a **lower bound**, not product-equivalent
capacity evidence. Directory signatures alone cannot observe every file-content
change. A provided change-notification permit is bound at generation creation;
on restart that fenced generation is deliberately unavailable for publication,
pending a future durable reconciliation design. Nil permits are used only for
quiescent synthetic measurements.

The revised candidate fails closed after batch failure/cancellation instead of
reusing a native cursor ahead of its rolled-back database offset. Its queue query
pins an ordered partial index and records SQLite VM steps. Frontier COUNT/SUM is
sampled at most once per second plus readiness; its time is reported separately
and included in `maxFullIterationSeconds`. Frontier peaks remain sampled lower
bounds. `maxBatchSeconds` excludes telemetry; do not present it as total iteration
latency. File and validated-directory count oracles throw on mismatch; small
regressions additionally compare exact paths, device/inode, sizes, link counts,
mtime and sample times. Scale count checks do not replace those semantic tests.

## Run

Copy the source tree to a new `/private/tmp/disk-steward-*` leaf, then compile
there with `swift test --disable-sandbox --jobs 2 -c release --filter ScaleBenchmarkTests`.
Without the supervisor environment the heavy test must **skip**. Do not enable
native-client or packaged-helper opt-ins. A compiler is not part of the measured
process group.

```sh
python3 docs/reliability/benchmarks/supervise_scale.py \
  --workspace /private/tmp/disk-steward-YOUR-DISPOSABLE-BUILD \
  --count 100000 --shape wide --seconds 45
```

`--shape deep` spreads files across a 32-directory chain; `fanout` creates empty
immediate child directories. Counts are capped at one million. Files are empty;
this measures metadata/evidence costs, not content reading. Each invocation
creates a fresh owned fixture and database. No production file is deleted,
scanned or modified. Generated fixtures are retained until explicitly cleaned
after measurements have been collected; do not let repeated research accumulate
unbounded fixture trees.

`--variant path-index` adds one partial `(object_id,path)` open-binding index to
the **disposable database only**. It leaves scanner, store algorithm, migrations,
the 512-entry batch, depth 64 and default 512 MiB storage budget unchanged.

## Safety and interpretation

- Separate low-priority process group; minimal environment without credentials.
- Fixture creation: 300-second timeout / 128 MiB sampled process-group RSS cutoff.
- Measurement: requested 1–120 seconds cooperatively between calls, plus 15 seconds
  externally; 150 MiB in-process cooperative cutoff; 256 MiB external sampled cutoff.
- 32 GiB free-space floor, 768 MiB external database-family cutoff, 8 MiB output cutoff.
- External sampling every approximately 100 ms includes long store calls. These
  are **sampled stop thresholds**, not OS-enforced absolute allocation caps:
  allocation/writes between polls may overshoot. Threshold hits do not prove
  successful completion or compliance with the smaller product budgets.
- Polling failure terminates/reaps the owned child; the supervisor never kills
  another process group. Small regression tests exercise stop paths without large
  allocations: `python3 -m unittest -v test_supervise_scale` in this directory.
- Follow `commit.generation` until an observation is published. Scanner completion
  alone is insufficient because directory-pass validation can reopen work.
- Final store-call duration includes last-slice staging, validation, reconciliation
  and COMMIT. It is not pure COMMIT duration. RSS/DB/WAL maxima are sampled lower
  bounds; combine in-process and external samples. Swift result counters omit a
  call that never returned. The pre-publication row records attempted scanner work.
- Frontier bytes measure the single root's persisted JSON array using SQLite;
  whole-progress bytes additionally include generation metadata. The sum of one
  progress-length sample per returned call is not cumulative physical I/O and
  misses internal validation rewrites.
- Count/integrity oracles run **after** timing. Complete runs require all expected
  current rows, one observation and no staging; unfinished fresh runs require no
  published current rows or observations. Resource-killed runs need separate
  post-run inspection: a stop may race with a successful atomic COMMIT.

`collect_scale.py` archives bounded logs, manifests, SHA-256 hashes, query plans,
and read-only post-run database checks; it never copies synthetic files or large
databases. Use a new output collection each time. Measurements are single runs
with uncontrolled OS caches, not statistical performance guarantees or a full
GUI/MCP/overnight acceptance test. Temp SQL files and APFS metadata are not included
in the DB/WAL/SHM family metric. The extra telemetry itself needs an overhead
comparison before a design's final acceptance.

## Collected-fixture recovery

`resume_scale.py --collection <baseline-collection> --label <run> --workspace
<disposable-build> --confirmed-stopped` continues only an owned, collected wide
fixture with generation 1 published and generation 2 preparing. It pins a reader
to test WAL pressure. `--phase recovery` instead takes the collected pinned
admission-stop result and resumes without the pinned transaction. Neither mode
accepts an arbitrary database path or overwrites prior phase logs.

Before SQLite opens, the whole database family must be regular, single-link and
free of unexpected siblings. The wide fixture must be complete and contain exactly
two persisted root directory rows. Exclusive ownership during validation/execution
is still required. Collection also validates the family before opening SQLite.

Recovery counters are phase-local; earlier baseline/pinned work is additional.
`checkpointState` distinguishes not-attempted/failed/completed. Unmeasured values
are JSON null; older stopped-run logs containing zero checkpoint values mean
unmeasured, not successful reclamation. The collector optionally records `dbstat`
table/index pages alongside page count, reusable pages and post-run file sizes;
these are distinct from the supervisor's sampled peak database family.

Run guard/accounting regressions with `python3 -m unittest test_resume_scale
test_supervise_scale test_collect_scale`. Supervisor tests require host process
RSS visibility; they still create only disposable fixture files and child processes.

`probe_dictionary_layout.py --collection <10k-product-collection> --label <run>
--encoding plain|dictionary` compares a lossless fresh rebuild of six selected
product tables with/without text interning. Use both modes: an existing source's
fragmentation/index fill is not a matched control. It copies at most 10k rows per
table in 512-row pages into a newly created probe leaf, verifies ordered decoded
row hashes and reports cooperative 45-second/128-MiB limits. It is a density probe,
not a product schema or migration: constraints, path ordering, other tables,
pending generations and historical workloads require separate validation.
`test_dictionary_layout` adds value-roundtrip and sparse-rowid budget-cadence tests.

`probe_layout_queries.py --plain <archived-plain-record> --encoded
<archived-dictionary-record>` compares seven selected query shapes over the exact
retained layout pair. It validates the generated database family before opening
read-only connections, creates connection-local decoded views and caps each query
at 501 rows, 2 million progress-callback steps and 2 cooperative seconds. This is
not the full MCP backend or a product-latency guarantee. Each variant records all
attempt statuses; an interruption cannot become a successful median after a retry.
`test_layout_queries` covers result equivalence, Unicode ordering, presence/NULL
semantics, work/output budgets and repeated-attempt reporting.

After collecting evidence and confirming the actual process handles are terminal,
use `cleanup_scale.py --collection <collection>` to preview exact generated roots.
`--execute --confirmed-stopped` verifies archived hashes and ownership markers,
then removes only those synthetic run roots and records cleanup progress. Never
infer a stopped process solely from saved JSON. All datasets from the first
research matrix were cleaned after archival; reruns recreate their fixtures.
