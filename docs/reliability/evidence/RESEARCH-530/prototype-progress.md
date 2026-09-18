# RESEARCH-530: corrected traversal experiments

17 September 2026. **Research remains working/unverified, not production-ready.**
This continues `benchmark-progress.md`; that earlier document's cleanup and
no-live-process statements describe its own baseline matrix, not later runs.

## Reproducibility and correction sequence

1. Candidate v1 product/test hash:
   `9fa4f7934953e26266969709a2359413318f1def8e7a0aeb65849235e1f78293`,
   frozen at `/private/tmp/disk-steward-530-prototype.OkTsA4`. Its million-file test requests two successive
   generations of the same one-million-file fixture, not two million distinct files.
2. `prototype-v1-runs/summary.json` contains six terminal runs. The 10k two-generation
   pilots completed. Both 100k-directory variants timed out without publication.
   Both million-file variants published generation 1 but timed out during generation
   2. These are not all-passing scale results. All six fixture roots were removed
   only after handle completion, evidence collection and exact-target ownership
   validation; `prototype-v1-runs/cleanup.json` records this.
3. Read-only review found two correctness defects. New tests against v1 reproduce
   missing paths after failed batch persistence and invalid publication after a
   failed generation creation. `prototype-retry-red.log` records eight executed
   tests, two failed cases/twelve failed assertions. The red test source is retained.
4. Corrected candidate v2:
   `7d822143a20fc3dd6f8a9a1619152b43d2e89824cfe29a40573b6632dd2f5947`,
   frozen at `/private/tmp/disk-steward-530-prototype-v2.VKZmHR`. Canonical and
   disposable execution product/test hashes match. `prototype-retry-green.log`
   records twelve passing small tests plus one default-skipped heavy test. Six
   supervisor tests pass with host process-group sampling. No full-product suite
   rerun or installed-app test is claimed.

The execution bundle is in `/private/tmp/disk-steward-522-lifecycle-dev.9CYz1T`.
The frozen source and bundle were not modified during their scale matrix.
All process groups use minimal credential-free environments and the documented
time, RSS, DB-family, free-space and output cutoffs. No personal watched roots,
production evidence/configuration, app installation or signing were involved.

`prototype-v2-performance-tests.log` additionally records the complete ordinary
PerformanceTests target: **17 passed, 2 opt-in tests skipped, zero failures**, in
1.764 seconds. Its virtual 72-hour scenario is not a real overnight soak. The
three exact v2 experimental source files are retained in `prototype-v2-source/`;
`prototype-v1.swift` plus the retained red test source reproduce the earlier
failures without depending only on a temporary frozen directory.

## Fresh corrected-candidate results

`prototype-v2-runs/summary.json` archives four completed runs, process exits,
manifests, hashes and post-run SQLite inspection. Time excludes fixture creation.
Peaks use the larger available internal/external sample, not OS high-water marks.

| Workload / variant | Published generations | Time | Names inspected | Peak RSS | Peak DB family | Peak WAL |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100k empty directories / stream | 1 | 25.088 s | 100,000 | 25.06 MiB | 31.81 MiB | 5.86 MiB |
| 100k empty directories / spool | 1 | 39.881 s | 100,000 | 25.42 MiB | 34.53 MiB | 5.94 MiB |
| 100k files / 32 levels / stream | 2 | 1.879 s | 200,062 | 22.67 MiB | 24.53 MiB | 5.92 MiB |
| 100k files / 32 levels / spool | 2 | 2.349 s | 200,062 | 22.77 MiB | 27.22 MiB | 5.83 MiB |

Both fanout post-run checks find exactly **100,001 phase-4 directories** in the
visible generation; zero files alone is not their completion proof. Deep runs
have exactly 32 validated directories and 100k visible files. Every database
reports integrity `ok`. The 200,062 deep entries are two passes over 100k files
plus 31 child-directory entries, not repeated full-directory lexical searches.

The corrected queue queries use the explicit `directories_open` and
`directories_unvalidated` indexes without a temporary sort. Maximum observed
queue VM steps are 31 in these runs. This is a measured bound for these shapes,
not proof for arbitrary stale/orphaned pass lineages. Frontier telemetry took
0.114 and 0.197 seconds total in the two fanout tests. Maximum full iteration
latency was 0.126 and 0.109 seconds, respectively. These figures include telemetry;
the separate batch-only measurement must not be substituted for full latency.

The corrected million-file rerun is separately archived in
`prototype-v2-million/summary.json`. Both process handles are confirmed terminal.

| One million files / variant | First publication | Final status | Total names read | Total metadata processed | Peak RSS | Peak DB family |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Stream | 68.094 s | Time limit; 1 of 2 generations published | 1,773,632 | 1,773,632 | 27.06 MiB | 170.40 MiB |
| Spool | 71.734 s | Time limit; 1 of 2 generations published | 2,000,000 | 1,646,592 | 27.23 MiB | 186.30 MiB |

At 120 seconds of work each run stopped cooperatively; final elapsed including
oracles was 120.434 / 120.458 seconds. External process elapsed was 120.711 /
120.778 seconds, below its 135-second cutoff. Both databases retain exactly one
million visible files in published generation 1, with generation 2 still preparing
and integrity `ok`. WAL peaks were 8.62 / 8.54 MiB. Neither result proves completion
of two generations; the incomplete second pass remains explicit. These owned
datasets are retained temporarily for the next isolated restart/resume experiment,
which must use new logs and may not overwrite these collected measurements.
`retained-fixtures.json` records the exact roots, ownership tokens, terminal session
and continuation constraints. The existing fresh-run supervisor is not a resume
interface and must not be pointed at an existing database as though it were fresh.

## Review reconciliation and remaining boundary

`helper-prototype-v2-result.json` validates against its schema and matches its job,
task guard and immutable snapshot: zero new findings, nine evidence items, 5,071
compact JSON characters, no file/asset changes. The coordinator independently
reproduced the old failures and ran the corrected regressions and benchmarks.
The static review is accepted as candidate-bound advisory evidence of that delta,
not an audit pass or approval of a production redesign. Its raw eligibility stays
pending/ineligible to prevent accidental use as final whole-product proof.

The helper's measurement qualification is retained: cooperative limits are checked
between work calls, before some telemetry/oracles. Total elapsed includes those
oracles, and the external supervisor remains authoritative about its own thresholds.
A `completed` string alone does not prove every transient peak or a timing SLO.

`design-candidate.md` maps the evidenced component direction and lifecycle/migration
tradeoffs. Streaming plus indexed durable work rows is the leading traversal
candidate; spooling trades extra writes for durable name-enumeration recovery.
Neither compact schema includes the full product's current/history/occurrence/
multi-root/attribution and migration costs. Fenced restart is explicitly
fail-closed, not production recovery. Full semantic preparation and peak-space
accounting, pinned readers, bounded reclamation and recovery remain before selecting
the final production storage path. TASK-531/TASK-532 are not implemented by this work.

## Continuation

- **Update:** `recovery-and-space-progress.md` now records the pinned-reader stops,
  successful unpinned second-generation recovery, exact-target cleanup of both
  million-file roots, harness regressions and real-schema space/density experiments.
  The G59 figures above remain historical measurements, not current fixture state.
- Measure product-equivalent storage/preparation and retained-reader/migration
  headroom, retaining all occurrence, root and sample-time semantics.
- Select the smallest supported design or explicitly document that implementation
  remains unapproved. Do not turn compact prototype success into product capacity.
- Submit the complete research result through Pyramid with every authored/evidence
  path. Refresh applicable inspections at the required boundary; do not rewrite
  prior intent history or mark the overall repair plan complete.

## Canonical checkpoint

Pyramid recorded `EVENT-20260917T092656763906Z-E844A369`, `task.at-risk`, at R8/G59.
The task remains **working**, **unverified**, owned by `codex`; the flag is not a
blocked execution or a research-completion claim. Current task guard:
`GUARD-TASK-36010BDAEE6F9609CECF3FD2ABF17C5C`; context:
`CTX-6E33FC657AA1D48456BDFAEB21AFD64E`; lease expires
`2026-09-17T10:14:53.839960Z`. The earlier helper was reconciled before this progress
mutation; it remains advisory, not fresh final audit evidence under the new guard.

Validation passes at R8/G59. History doctor reports eleven records, six chronicles,
zero bindings, no pending transaction and no errors. No final intent chronicle,
clean-commit binding, commit, push, app installation or release is claimed.

All benchmark and cleanup sessions from this continuation are terminal. The four
v2 directory/deep fixture roots were removed after archival and exact-target
validation; `prototype-v2-runs/cleanup.json` records their removal. Together with
the six v1 roots this is ten removed synthetic datasets, not personal files; they
can be regenerated and were not moved to Trash. Only the two intentionally retained
million-file roots remain. `progress-inventory.json` records 177 cumulative
research source/evidence paths for eventual worker-result provenance.
