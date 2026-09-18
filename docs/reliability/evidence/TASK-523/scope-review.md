# TASK-523 — ordered, bounded endpoint evidence delivery

## Why this repair exists

TASK542 observed an intermittent exact-versus-unknown confidence failure in unchanged endpoint code. Its callback launched one independent Task per raw event. Sequential callbacks therefore did not imply sequential bridge arrivals; the normalized buffer limited neither these Tasks nor their raw payloads. Stop/crash also did not revoke pending deliveries.

The negative fixture reproduced the ordering defect deterministically on the pre-repair source: hold watched sequence1 before its bridge call, allow excluded sequence2 to finish, then release sequence1. The old observer reports unknown confidence for the otherwise complete event. `endpoint-red.log` records the expected one-test failure at 2026-09-17 11:50:12 JST. This is no longer merely an inferred scheduling mechanism.

The negative source is the TASK542 frozen snapshot `/private/tmp/disk-steward-542-accepted.xRV6DE`, aggregate hash `a13e1f55a7beac07019ba371bfc1c5ef965c277ecd269d31da054cc839b1d024` using the expanded input set below. Only before/after-delivery barriers were injected into its observer; its Task-per-callback behavior was preserved. The exact instrumented observer is retained as `negative-observer.swift.txt`, with `EndpointOrderingReproductionTests.swift.evidence`. Reproduce only in a disposable copy of that old source, placing these two files at the observer path and the endpoint test directory, then running the recorded filtered command. It is an expected failing oracle, not a passing old-product test.

## Accepted engineering contract

- One observer-owned consumer Task exists across all start/stop cycles. A fixed-size ring admits callbacks synchronously in lock-acquisition order. An AsyncStream with one buffered Void value only wakes the consumer; it never owns raw notifications. No Task or loss record is created per callback.
- The ring has at most 4096 reservations and a 4MiB estimated-payload ceiling by default and at maximum. Count and bytes include the one in-flight delivery. Stop discards queued data, but a held old-epoch delivery retains its reservation until its consumer finishes. Payload accounting includes all seven variable-length fields, using doubled UTF-8 lengths and fixed overhead; it is an estimate, not an RSS guarantee. The normalized output buffer has its own existing limits, now checked for coalescing replacements as well as appends.
- Rejection aggregates into one saturating loss counter and an ordered loss marker. Later callbacks are rejected while a marker is pending, so accepted pre-gap work precedes the loss notification. A loss report is published even if no further callback arrives. The queue and wake protocol cannot lose that report through wake coalescing.
- Runtime start/stop calls are actor-serialized. Every lifecycle attempt has a revocable token. Revocation closes old admission synchronously; the bridge checks authentication and current epoch at its non-suspending mutation boundary. Stop awaits its bridge transition. Work already across the commit boundary may finish before stop, but old work cannot reappear after a completed stop or replace the new session's sequence/status.
- Startup callbacks are staged until runtime.start succeeds. A throwing startup discards them. Superseded async activation, retained callbacks, crash and deinit cannot reactivate an old session. The consumer captures collaborators, not the observer, so it does not prevent cleanup.
- Excluded contiguous events still advance raw sequence. Gaps seen on excluded/invalid events remain pending until visible evidence carries them. Restart records a real monitoring-downtime gap; later complete contiguous events can be exact locally. Gap status remains conservative. Sequence wrap, invalid size subtraction and coalescing arithmetic overflow no longer trap.
- Authentication still precedes data/control mutation. Review also corrected a pre-existing challenge-length comparison that truncated the length XOR to UInt8; a challenge with 256 appended NUL bytes must not authenticate. Managed bridges reject legacy unfenced ingestion/status changes.

## Acceptance evidence

Accepted immutable copy: `/private/tmp/disk-steward-523-accepted.8oZqwJ`.
Input SHA-256: `e408ff149419ace16c04932147f8f635852ed011c8a8182d9126e27cf36220e8`.
The canonical worktree's product inputs matched this hash after the final edit. Unlike TASK542's older hash convention, this task explicitly includes Extensions in the aggregate.

The full suite executed 315 tests, one native-client opt-in skipped, zero failures. The 17 endpoint tests passed five further repetitions. The 13 new regressions cover delayed first delivery and excluded middle events; 10,000 overflowed callbacks with a held consumer; each variable-field byte limit; old in-flight bytes across restart; stop/crash and retained handlers; superseded activation; inline startup success/failure; hidden/invalid gaps and UInt64 wrap; spoofed/revoked epochs; oversized coalescing replacement; 30 restarts and observer deinit; challenge-length mismatch; size/coalescing overflow. Existing delivery assertions now await a bounded completion acknowledgment, not a sleep. Coalescing timestamps use a fixed base date.

Independent review found the remaining wall-clock-dependent coalescing oracle. It was fixed and re-reviewed on the accepted hash. The earlier candidate's passing full suite and five repetitions are not substituted for the final runs. Helper review is static, not independently executed runtime validation; see the raw envelopes and reconciliation.

## Scope and remaining limitations

Five implementation files and two endpoint test files changed, all under the declared TASK523 scope and ASSET-ATTRIBUTION. No installed app, user evidence, client profile, native system-extension activation, entitlement, Git commit, publication or release action occurred.

These tests prove the fixture/runtime adapter contract, not real EndpointSecurity entitlement, native callback sequencing or shutdown behavior. If a native runtime calls concurrently, FIFO means callback lock-admission order; out-of-order source sequences are conservatively reported as gaps, not secretly sorted. Synchronous runtime start/stop implementations must return; Swift actors cannot preempt a blocking native call. macOS13 and Intel were not exercised (host macOS15.6.1 arm64, Swift6.2.4). The one bounded idle-wait acknowledgment is internal fixture support, not a public unbounded waiter registry.

This resolves FIND-ENDPOINT-ORDER at the scoped implementation/inspection boundary. Integration verification still waits for OUTCOME510 and GATE529; it does not close the full reliability intent or replace scale, migration, overnight, export, onboarding or native-client evidence.
