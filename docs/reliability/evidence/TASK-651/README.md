# TASK-651: capacity ring and reserve guard

Candidate input `f74174a5272e4a1446f74eaa1815f4addd1e53af350439555e526e16907e5bf4` (uncommitted on main after `de4a511`). Nothing has
been installed or published.

## Change

- **`CapacityRing`** (`Sources/DiskStewardCore/Snapshot/CapacityRing.swift`)
  keeps capacity samples in their own file, `capacity.sqlite` beside the
  evidence store. It uses its own connection and a rollback journal, and
  follows the CONTRACT-602 tables. Per volume it keeps:
  - one 5-minute row per fine interval for 7 days; on-demand and wake samples
    inside an interval add nothing;
  - one hourly row per clock hour for a year.

  The contract's row and byte caps stay the backstop across volumes.
- **Recording.** `MonitoringLifecycleController` records every successful
  observation's selected volume. That covers the timer, on-demand refresh and
  wake samples. A failed ring write never fails a sample.
- **Failed samples.** After a failed sample the board shows **Capacity
  unavailable** (with the time of the last measurement) instead of the old
  value. The distance to the reserve is hidden, and health reads
  `unavailable`.
- **Reserve.**
  - The setting is `MonitoringSettings.comfortReserveGiB`. When unset, the
    suggestion is migrated from the old percentage threshold: the free space
    that threshold allowed, e.g. 93 GiB on the maintainer's 994.7 GB disk at
    90%.
  - The settings window offers "Keep at least N GiB free", with a "Use
    suggested reserve" reset.
  - One notification fires when free space is below the reserve on two
    comparable samples in a row. No repeat comes until free space recovers
    above reserve plus hysteresis (the larger of 1 GiB and 5% of the
    reserve). This replaces the percentage alert.
  - The board shows "N above/below your R reserve", and anything below the
    reserve counts as "attention".
- **`get_storage_summary`** adds `reserve_bytes`,
  `free_above_reserve_bytes` and `capacity_history` (sample count, oldest
  and newest sample, 24-hour minimum available). History is read from the
  ring file, so it is reported even when the evidence store is corrupt.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 65 tests pass: ring, history lifecycle, notification policy and delivery, settings, status board, volume presentation, lifecycle, storage-summary faults, recorder increment and bounded store. One volume's full year (8,784 hourly records plus 2 weeks of 5-minute records) leaves **602,112 bytes** on disk |
| `one-sample-alerts-red/` | Alerting on the first sample below the reserve fails the policy test |
| `no-hysteresis-red/` | Re-arming at the reserve itself fails the policy test |
| `no-ring-write-red/` | Not recording observations fails the ring lifecycle test |
| `stale-capacity-shown-red/` | Ignoring a failed sample keeps showing the old capacity; the board test fails |

## Acceptance notes

- **AC-01's "under 1 MiB".** One volume's full year is 602 KB on disk. The
  contract bounds four volumes at 3.2 MiB in the worst case.
- **"Every 5 minutes, on wake and on demand".** All three are samples of the
  same lifecycle path, which records to the ring. The ring keeps at most one
  5-minute row per interval, so a burst of on-demand samples cannot crowd out
  the week.
- **"Two comparable samples".** This uses the existing comparison rules: the
  same volume identity, distinct observations and a later time.
- **Existing tests.**
  - `VolumePresentationTests.testCapacityAlertsSurvivePendingFileReconciliationWithoutDuplicates`
    now sets a 200 GiB reserve. It checks that the reserve alert waits for a
    second comparable sample, still fires while file changes are pending, and
    is not replayed after they clear.
  - `ThresholdNotificationPolicyTests` was rewritten for reserve semantics.
