# TASK-716: the connection test reads Monitoring's capacity samples

GATE-719 found this on the installed 1.5.1 (13).

## What was wrong

- **What the user saw.** The user pressed **Set up** for Codex and **Repair**
  for Claude Code in **Settings › Agent Integrations**. Both registered the
  server and installed the skill. Codex's row then warned: "The configured
  helper connected, but no evidence has been persisted yet. Check that
  Monitoring is running."
- **When it began.** Claude Desktop had shown the same `verified-stale` result
  since 1.5.0 was installed.
- **The cause.** `disk-witness-mcp --self-check` took evidence freshness only
  from `persisted_state_as_of`.
  - That field is the newest observation from the file-level scanner, which
    1.5.0 retired (TASK-653), so on every current install it is null.
  - The same answer carried `capacity_history.newest_sample_at`. Monitoring
    persists a capacity sample every 5 minutes by default, and the newest
    one was minutes old.
  - Transcript:
    [`../GATE-719/installed-1.5.1/self-check-13.txt`](../GATE-719/installed-1.5.1/self-check-13.txt).
- **The effect.** Test Connection could never report **Verified** on 1.5.0
  or 1.5.1 (13).

## Change

- **The helper** (`Sources/DiskStewardMCP/main.swift`). The self-check takes
  freshness from the newer of `persisted_state_as_of` and the newest
  persisted capacity sample.
  - The sample counts only when the capacity history's `status` is
    `available`.
  - It is still never the moment the live volume figures were read.
  - With neither, the report says nothing has been persisted, as before.
- **Shared wire names**
  (`Sources/DiskStewardCore/IPC/StorageSummaryContract.swift`). The backend
  and the helper use the same constants for the capacity history,
  `capacity_history`, `status`, `available` and `newest_sample_at`, so the
  field cannot be renamed on one side only.
- **What agents see is unchanged.** `get_storage_summary` still says file
  detail is retired.
- **Docs.** `docs/integrations/README.md` says what "Stale evidence" now
  measures.

## Evidence

| Evidence | Result |
| --- | --- |
| [`green/`](green/) | Focused isolated run on input `16c6ec71`: 44 tests, 0 failures, covering the self-check, transport, install, storage summary, helper verification and retired-detail suites |
| `SelfCheckCapacityFreshnessIncrementTests` | Runs the built helper's `--self-check` against the production backend configuration (`fileDetail: .retired`) and judges the result with the app's `HelperSelfCheck.evaluate`: a sample 3 min old is **verified** with its age; no sample is **stale** with nothing persisted; a sample 2 h old is **stale** |
| [`reds/capacity-sample-ignored/`](reds/capacity-sample-ignored/), spec in [`mutations/`](mutations/) | Restores the 1.5.1 (13) behaviour on a snapshot. The 3-minute and 2-hour cases fail (`persisted` false, no age), and the no-sample case still passes |
| GATE-719 | On the reinstalled build, Test Connection for Codex and Claude Code reads **Verified** |

The existing `SelfCheckDetailFaultIncrementTests` builds a legacy store in
which the scanner is not retired. It passed both before and after this fix,
so it could not catch this defect.

## Limitations

- With **Sample interval** set above an hour, Test Connection still reports
  stale between samples. The one-hour threshold is unchanged by design.
