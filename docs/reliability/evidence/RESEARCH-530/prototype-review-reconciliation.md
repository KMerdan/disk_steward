# Prototype review reconciliation — in progress

17 September 2026. Scope: research candidate
`9fa4f7934953e26266969709a2359413318f1def8e7a0aeb65849235e1f78293`,
frozen at `/private/tmp/disk-steward-530-prototype.OkTsA4`.
This is not a production audit or approval of a storage migration.

The bounded read-only helper `HELPER-RESEARCH-530-PROTOTYPE-REVIEW` returned
five findings, nine evidence references, no changed files/assets and no executed
tests. Its identity, guard and snapshot match its job. The coordinator read the
referenced prototype, tests and SQLite transaction implementation. Runtime
reproduction is still required before promoting static findings to test proof.

1. **Native cursor versus transaction rollback.** `readNames` advances the live
   directory stream before the transaction starts. A failed insert or cancellation
   can leave the durable offset behind the native cursor. Same-instance retry can
   skip names. Add injected-insert failure tests in both modes and require either
   correct replay or fail-closed reopening; compare full paths and metadata.
2. **Failed generation creation.** `begin` assigns its generation ID inside a
   transaction. Rollback can leave a nonzero in-memory ID without a durable row.
   Add a failing root-insert test with prior visible evidence. Publish must never
   treat an absent generation/root as a complete generation.
3. **Receipt freshness is not yet modeled.** A permit supplied only at publication
   does not bind observations to the receipt revision under which they were
   collected. The existing acknowledge-and-republish test proves pointer rollback,
   not reconciliation. Do not claim recovery after dirty receipts from this test.
4. **Query cost and telemetry.** The coordinator's read-only system-SQLite query
   plans on the completed 100k-directory stream fixture select
   `directories_queue (generation=? AND phase<?)` followed by `USE TEMP B-TREE
   FOR ORDER BY` for both `phase<3` and `phase<4`. Thus even the existing
   `directories_open` index does not establish bounded dequeue work. Also,
   `sampleFrontier` scans the pending queue after each batch; record that overhead
   separately and include it in full-iteration latency.
5. **Oracles and claims.** File counts alone cannot detect equal-count wrong paths,
   identity or metadata. Zero files do not prove all empty directories were visited.
   Add semantic small-fixture oracles, explicit validated-directory coverage, and
   throwing benchmark checks so a failed assertion cannot emit `completed`.

The first prototype scale matrix is allowed to finish against its frozen binary.
Its results characterize that candidate only. The two fanout runs timed out;
neither published a generation. These observations cannot be presented as a
passing scale design, regardless of their low measured RSS. A changed candidate
requires fresh regression and representative benchmark evidence.

## Reproduced failures and corrected candidate

`prototype-retry-red.log` records the original prototype with two new regressions:
eight tests ran, two cases failed (twelve assertions). Failed enumeration lost two
specific paths in both modes; failed `begin` left generation 2 in memory with no
durable row and hid the prior visible state on publication. The exact red tests
are retained as `prototype-retry-red-tests.swift`; the prototype source is the
immutable v1 snapshot. These are now reproduced defects, not static speculation.

Candidate `7d822143a20fc3dd6f8a9a1619152b43d2e89824cfe29a40573b6632dd2f5947`
is frozen at `/private/tmp/disk-steward-530-prototype-v2.VKZmHR`, with matching
canonical and execution source hashes. `prototype-retry-green.log` records twelve
passing small tests and one supervised-scale test skipped by default. The changes:

- Publish the in-memory generation ID only after successful transaction COMMIT.
- Close/poison the native traversal after any step failure; reopen replays the
  unfinished pass or resumes the committed spool page. Injected cancellation is
  tested after names have actually been consumed.
- Require an existing preparing generation and root before publication. Bind the
  original permit at `begin`, not at `publish`. After a dirty receipt, a fresh
  permit cannot approve the previous generation. Fenced restart fails closed and
  preserves old visible evidence; it is **not** a claim of automatic convergence.
- Pin ordered partial indexes for open/unvalidated work. A 10k-row query fixture
  verifies no temporary sort and fewer than 100 VM steps for the tested lookups.
  Epoch-filtered orphan-heavy queues are not covered by that bound.
- Separate frontier telemetry timing, lower its sampling frequency and report full
  iteration latency. Add throwing validated-directory/count oracles and small
  exact-path/metadata, equal-count rename, hard-link and spool-retry tests.

The six supervisor tests pass with host process-group sampling. A sandbox attempt
failed because `/bin/ps` is prohibited there; that was an isolation limitation,
not a passing test, and its children were reaped by the fail-closed supervisor.
The corrected candidate still requires fresh scale results and review. Production
sources, installed app, user evidence and client configurations remain unchanged
by this research task.
