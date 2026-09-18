# Bounded-monitoring research decision

17 September 2026. Decision at plan R8/G61; **not a production implementation,
migration approval, audit pass, or release claim**.

## Decision

Keep TASK-531 and TASK-532 behind their unverified RESEARCH-530 dependency. No
measured option yet establishes the full product's correctness and useful
100k/1M-file progress inside the unchanged resource budgets. This is the explicit
implementation-block branch of AC-RESEARCH-530-01, not a request to raise the caps
or drop evidence semantics. Independent export, privacy and isolated-CI work can
continue. Preserve this research as a resumable task, rather than falsely marking
the storage design verified.

The supported component direction is **streaming enumeration + an indexed durable
directory frontier + bounded hidden preparation + a short fenced publication +
bounded reclamation**. Prefer streaming over always spooling names, based on the
measured extra spool work; retain restart-of-unfinished-pass semantics. Never
persist a native directory cookie. See `design-candidate.md` for object lifetimes.

The experiments reject three shortcuts:

- Adding the open-path index improves time but does not solve repeated enumeration,
  whole-frontier rewriting or publication/storage amplification.
- A compact path-membership prototype does not prove the product's occurrence,
  history, uncertainty, multi-root or migration semantics.
- Generic text interning with compatibility views saves selected-table space but
  does not preserve query cost. Typed, index-aware queries need their own proof.

## Latest query comparison

`layout-query-final-v2.json` compares the retained matched 10k-file plain and
dictionary layouts. All seven selected expressions returned identical ordered
rows on every completed attempt. The two-file probe/test source hash is
`dfe10d899964ae479542a84b4cf400f91159e0db33f9bd608e82976c712e59e1`.
`query-final-source/` preserves those files and the two test-handle cleanup files.
SQLite reader version: 3.53.4. Main databases were opened read-only; decoded views
were connection-local TEMP views. Fixtures were quiescent and exclusively owned.

| Selected expression | Plain VM-step lower bound | Decoded dictionary VM-step lower bound | Plain / dictionary median ms |
| --- | ---: | ---: | ---: |
| Current count and bytes | 50,000 | 360,000 | 0.339 / 1.860 |
| Current first page | 200,700 | 300,700 | 1.757 / 2.366 |
| Current keyset next page | 259,200 | 359,200 | 2.141 / 2.626 |
| Exact path | 0 | 0–100 | 0.005 / 0.006 |
| Open object paths | 0 | 0–100 | 0.005 / 0.009 |
| Object events with occurrence interval | 0–100 | 0–100 | 0.009 / 0.012 |
| Observation page | 91,100 | 291,100 | 0.836 / 1.855 |

The count view adds six LEFT JOIN lookups that the plain covering-index query
does not need. A typed predicate that resolves the `present` enum once returns the
same count/byte sum with **50,000 measured steps on both layouts**. That is evidence
for avoiding unnecessary decode joins, not for all typed queries being equivalent.
Both page variants still sort tied rows; normalization does not magically supply
lexical ordering. Tiny queries below callback granularity report zero, not zero
actual work.

These are three warm, instrumented runs per expression, not p95/app latency or a
complete MCP test. Progress callbacks count in 100-operation increments and include
the query-plan statement. Limits are cooperative (2 seconds, 2 million steps,
128 MiB RSS), output is capped at 501 rows. The selected page projection omits
category derivation, root filters, modified-before filters and revision fencing.
The scale fixture has one observation and no mutation. Separate small regressions
cover absent/unknown rows, Unicode lexical ties, NULL times and occurrence joins;
they do not establish a production conversion matrix.

## Test and reporting corrections

`query-harness-final-green.log`: **28 Python tests pass**, with ResourceWarning
treated as an error. It covers the existing fixture guards, child supervision,
space accounting and density roundtrips plus five query tests. The query reporter
now retains a failed attempt even when a later attempt succeeds; partial runs
cannot acquire a successful median or row hash. It also closes the query cursor
before removing the progress handler. Two older test fixture connections now close
deterministically. `query-harness-green.log` retains the earlier passing assertions
with resource warnings; it is not the final clean check.

## Migration baseline: what already exists

`query-migration-baseline-green.log`: **3 existing Swift tests pass** in the
disposable optimized build, using credential-free environment and temporary DBs.
Product/test input hash:
`ef6dbd7dd9a88b3527b1409de5c705e3acfe10a287dd2ad441b577494e2f15f3`.
Canonical and disposable EvidenceStore, SQLiteConnection and migration-test files
were hash-matched before execution. No production source changed in this research.

The existing `prepareDatabaseForOpen` creates a consistent shadow copy, migrates
and checks it, then atomically renames it over the main database. It preflights
available capacity using `max(64 MiB, 3 × source family + 16 MiB)`. Tests cover a
tiny version-5 fixture, four injected interruption boundaries, and insufficient
capacity before conversion. They establish forward recovery for that fixture.

They **do not** establish rollback to an older application after successful rename:
the old database is not retained as a rollback copy. They do not test large
conversion, a proposed compact schema, full per-table semantics, all power-loss
points, or migration under an active writer. An interrupted shadow is discarded
and rebuilt when the main database still exists. The backup loop copies in chunks,
but its busy/locked timeout is not an overall successful-copy deadline.

## Exact evidence needed to remove the storage block

The next storage-specific work must test one bounded, product-equivalent candidate
against these requirements rather than repeat the general algorithm comparison:

1. Preserve object occurrence identity, aliases/rename/replacement/deletion,
   overlapping and unavailable roots, producing-pass provenance, actual sample
   time, uncertainty and revision-fenced MCP/export results. Compare to an explicit
   oracle across mutation and restart, not only row counts or decoded TEXT hashes.
2. Measure complete visible + prepared + history + unreclaimed pages + WAL/SHM
   costs on 100k/1M workloads over repeated generations. Show progress, bounded
   cleanup and safe refusal when authoritative state genuinely cannot fit.
3. Bound read-view lifetime and each admission/maintenance operation. A pinned
   reader must cause explicit non-progress with preserved current truth, not
   checkpoint spinning. Resume must remeasure space before accepting new work.
4. Specify and exercise conversion authority, interruption recovery, downgrade
   compatibility and old-data retention. Count simultaneous conversion/rollback
   copies. Insufficient capacity must preserve the old usable state.

Those checks are a finite follow-up candidate-validation matrix. They are not a
license for a whole-product rewrite or a claim that the research prototype already
meets TASK-531/TASK-532. If the existing task scope cannot express that candidate
without mixing independent work units, use Pyramid expansion/replan and preserve
this negative decision and all failed experiments. Do not unblock production merely
because a research report has been written.

## Evidence chain

- `benchmark-progress.md`: current product baseline, repeated work and safety stops.
- `prototype-progress.md` and versioned run collections: streaming/spooling,
  wide/deep/fanout workloads, frontier/VM work and publication measurements.
- `recovery-and-space-progress.md`: pinned-reader failure, unpinned million-file
  recovery, actual product schema accounting and matched 53.8% selected-table
  density reduction. Historical failed tests remain failed.
- `layout-query-final-v2.json`: the latest exact rows, query plans and all attempts.
- `retained-fixtures.json`: only the 10k source and final layout pair remain;
  million-file trees were removed after archival. No benchmark process is live.

Pyramid handoff records the cumulative authored/evidence files, remaining work and
resume entry point. It does not replace an implementation result or final audit.
