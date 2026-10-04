# INTENT-006: reclaimable space as whole objects

PLAN-DISK-STEWARD-006 closes on **candidate 1.5.0 (12)**.
- Verified input:
  `03e80c743d0ce97b1e6c5dd49d0b0670fc4cf6452d49efd421fb60815490947b`.
- Commits `52c206e` (version bump) and `4cdbe93` (TASK-664). Every later
  commit changes only `.pyramid/`, `docs/reliability/` and `docs/tasks/`,
  which are outside the hashed input.
- The candidate is installed on the maintainer's Mac. It was not notarized
  when the gates ran.

## The criterion, clause by clause

AC-INTENT-006-01: "Every cumulative outcome passes against the exact
candidate, the configured scope completes a scan under the configured limit,
no classified object stores per-file rows, and no open material finding
remains."

| Clause | Evidence |
| --- | --- |
| Every cumulative outcome passes against the exact candidate | Each rung's outcome was audited, or re-audited, on input `03e80c74`: OUTCOME-640 ([`../GATE-649/outcome-640-audit-1.5.0.json`](../GATE-649/outcome-640-audit-1.5.0.json)), OUTCOME-650 ([`../GATE-659/outcome-650-audit-1.5.0.json`](../GATE-659/outcome-650-audit-1.5.0.json)), OUTCOME-660 ([`../GATE-669/outcome-660-audit.json`](../GATE-669/outcome-660-audit.json)) and OUTCOME-670 ([`../GATE-679/outcome-670-audit.json`](../GATE-679/outcome-670-audit.json)). Each later gate inherits the earlier gates' proofs ([`../GATE-669/audit.json`](../GATE-669/audit.json), [`../GATE-679/audit.json`](../GATE-679/audit.json)) |
| The configured scope completes a scan under the configured limit | The installed app reviewed `~/localGit` in **54.0 s cold** (right after `sudo purge`) and **44.8 s warm**, against GATE-669's 60 s bound. Both runs were complete with 2,000 items, and sizes match `du` at a ratio of 1.000001 ([`../GATE-669/README.md`](../GATE-669/README.md)). A synthetic million-file tree completes inside the default budget in 6.6 s, and stops with a partial report under an injected 300,000-entry budget |
| No classified object stores per-file rows | The steward store has eight fixed tables with row and byte caps, pinned by `BoundedStoreContractTests` (CONTRACT-602, [`../CONTRACT-602/bounded-store-contract.md`](../CONTRACT-602/bounded-store-contract.md)). The review index stores one row per object: 4,071 objects for `localGit`, whose `measure_path` walk passes 500,000 entries before its budget stops it. On the installed app, `steward.sqlite` holds exactly those eight tables, and every review states "nothing inside an object is listed or stored" ([`../GATE-669/README.md`](../GATE-669/README.md#supervision-and-rollback), [`../GATE-669/installed-1.5.0/cold-localgit-health.json`](../GATE-669/installed-1.5.0/cold-localgit-health.json)). The legacy per-file database is kept unmodified and unread, as rung 2 required |
| No open material finding remains | No finding is open. Three were resolved during rungs 3 and 4, and the maintainer accepted the remaining five on 2026-10-05 (below) |

**Required evidence** (EVREQ-INTENT-006-01): the isolated verifier ran on the
final candidate in [`../TASK-664/consecutive/`](../TASK-664/consecutive/):
- Runs 1 and 2 passed 727 tests (11 skipped, 0 failures) and built the
  packaged CI app.
- Run 3 failed only the known `ObjectConvergenceTests` seed race.

Each rung's gate evidence is linked above.

## Findings at close

**Resolved during rungs 3 and 4:**
- FIND-R4-SUPERVISOR-RACE (TASK-664);
- FIND-R4-DOCS-STALE (TASK-671);
- FIND-R4-LIFECYCLE-RESPONSE-SIZE (GATE-679).

**Accepted by the maintainer (Dr. Kiji) on 2026-10-05**, when asked to close
the plan:

| Finding | Severity | Why it is accepted |
| --- | --- | --- |
| FIND-R4-XCODE-WORKER | medium | Affects only the test harness. `xcodebuild` exits 0. The supervisor stops the one retained worker and verifies cleanup on every packaged and archive build. A stage that fails for any other reason still fails |
| FIND-R4-OBJECT-CONVERGENCE-FLAKE | low | The race is in the retired scanner path and also fails on unmodified `main`. It never masked another failure |
| FIND-R4-PAGE-SCHEMA-STALE | low | The page schema is unenforced documentation. The enforced contract is the MCP catalogue, its fixtures and TASK-671's size tests |
| FIND-R4-PATH-REDACTION-FALSE-POSITIVE | low | Pre-existing, and it fails safe: it hides part of an ordinary name and never leaks one |
| FIND-R4-JOURNAL-LIMIT | low | The fixed 200-folder window stays under the response ceiling. Only the request's `limit` is ignored |

The acceptance records are in `.pyramid/assurance.json`, applied from
[`../../planning/r10-assurance-intent-006-close.json`](../../planning/r10-assurance-intent-006-close.json).

## Controls at close

**Rollback.** Rungs 3 and 4 changed no store format. To roll back, quit
1.5.0 and reinstall 1.4.0. The 1.4.0 steward files were hashed and cloned
before the install, and the legacy set and its restore script are unchanged
from 1.4.0.

**Monitoring:**
- `get_health` reports store caps, journal coverage and the last review's
  timing and size.
- The board and the capacity ring report free space against the reserve.
- Idle CPU over one hour: 0.056% of one core on 1.4.0 and 0.156% on 1.5.0.
- The supervisor's 13 watchdog cases pass on the candidate.

**Superseded nodes.** The inspections of TASK-612, TASK-613 and TASK-615 stay
stale as history and are no longer required, because those nodes were
superseded by replans R4 and R5. The same was done for GATE-619 to GATE-639
in R4.

## Limitations

- **The gates ran on an unnotarized build.** Notarization, Gatekeeper
  acceptance and publication come after this close, as the intent's
  non-goals say ("Signing, notarization or Homebrew publication").
- **One Mac.** The installed measurements come from the maintainer's Mac.
  Other machines and trees will differ.
- **No live VoiceOver pass.** VoiceOver labels are asserted in the model and
  by a source check.
