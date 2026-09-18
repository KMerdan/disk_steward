# TASK-551 — bounded export and cleanup repair

Worker implementation evidence, 2026-09-17. Not an audit, installed-app test, or release approval.

## Accepted candidate

- Whole verifier input identity: `b46aff222dc214fa4735fd5d6064a53ebade829b5b6169abfdee08b02413a9f7`.
- Exact source/test copies: `final-source/`; complete input manifest, executable hashes, commands, and environment limitations: `final-run/candidate.json`.
- Verification: `env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 Scripts/Testing/verify_candidate.py --output /private/tmp/ds551-final2-20260917`.
- Six stages passed, including 20 harness tests and 452 Swift tests (4 opt-in skips, zero failures). The suite includes live-fixture endpoint isolation and four historical forward-migration scenarios. Final test duration: 31.942 seconds.
- Rechecked every archived log checksum, all ten changed source/test copies, and the live repository input manifest against this candidate. `git diff --check` passed.

## Defects reproduced and repaired

`red-run/` records three failing tests, six failed assertions, against input `b9093d7227666c5b596bdb28c1d791df2d67ce18369ea8de2d5214323c62ca9d`: cancelled decode returned success, missing bytes decoded as empty evidence, and file compression overwrote an existing destination. The small reproduction sources are in `red-source/`.

One fixed-buffer streaming driver now serves memory encode/decode and file compression. Empty evidence has a finalized stream; missing, malformed, and truncated streams throw. Every chunk checks cancellation, cumulative input/output limits, progress, and stream completion. This follows Apple's [stream processing contract](https://developer.apple.com/documentation/compression/compression_stream_process%28_%3A_%3A%29): short output alone is not successful completion. Existing raw-DEFLATE wire compatibility is retained, including Apple's acceptance of some trailing padding; this codec is not a substitute for bundle integrity checks.

File output uses exclusive creation and removes only its own partial output on failure. Bundle reservation happens before suspension. Cleanup checks captured parent and bundle identities; exported results retain that ownership authority. Manual exports cannot use temporary destruction. The unredacted database backup, sidecars, and raw events share an owned private system-temp workspace, never a potentially synced user export folder.

SQLite export reads reject failed steps rather than silently returning a prefix, bound serialized bytes before copying/decoding rows, and throw on malformed scope JSON, malformed snapshots, and invalid snapshot timestamps. Checked numeric sums prevent overflow traps. Export and IPC timestamps share one whole/fractional-second parser and formatter. No `try!` remains in the affected production export/IPC paths.

## Explicit per-request limits

| Boundary | Manual export | Inline MCP export |
| --- | --- | --- |
| Total serialized SQLite row bytes admitted | 32 MiB | 4 MiB |
| Individual SQLite value/row length ceiling | 1 MiB | 1 MiB |
| Emitted bundle payload, including manifest | 64 MiB | 2 MiB |
| Raw JSONL before compression | 64 MiB | 2 MiB |
| Aggregate files plus decoded JSONL admitted by inline reader | N/A | 2 MiB |
| Encoded inline response before MCP's duplicate structured/text envelope | N/A | 1 MiB |

Existing 100,000-event manual / 10,000-event inline and 25,000-related-row ceilings remain. Limits fail explicitly, never silently discard bytes to produce a success. Inline budget failure becomes `response_too_large`; malformed evidence becomes `invalid_evidence`. Manual limit parameters may tighten but cannot raise the hard ceilings. Serialized-byte limits are not a claim that RSS equals the byte cap; Foundation decoding and JSON trees have overhead. Whole database backup space and full-product memory/scale proof remain separate gates.

## Lifecycle review and regression coverage

Initial review found pathname-only inline deletion. Its repair carried ownership into the export result. A second review found that recursive outer cleanup bypassed that check, and that inventory retry required repeating an already-completed deletion. Both were repaired:

- The request wrapper removes only an empty, still-owned workspace (`rmdir`). A replacement child is preserved, even when its enclosing workspace is unchanged.
- One request-local `TemporaryExportCleanup` remembers successful owned removal. A failed inventory update can retry without deleting again or touching a later replacement. Cleanup inventory writes are awaited without inheriting request cancellation.

`review-*.json`, `delta-*.json`, and `final-review-*.json` retain the bounded review chain. Earlier snapshots/guards are superseded and advisory. The last review matches the accepted source hash and current pre-submission guard, identifies no further concrete defect in those two changes, and remains **static review**, not independently executed validation. Raw helper envelopes are intentionally not promoted to runtime evidence.

The final suite directly covers zero/one/many-row bundles and inline responses, fractional requested/actual times, exact 64 KiB boundaries and incompressible data, missing/corrupt/truncated/high-expansion streams, input/output caps, oversized database rows, corrupt stored JSON, cancelled decode and partial file encoding, cancellation at final publication, failed-export inventory, replacement-parent and replacement-child preservation, and fail-once inventory retry. All normal/error/cancellation fixture workspaces are empty afterward. Foreign replacements are deliberately preserved rather than counted as successful cleanup.

The earlier 450-test candidate is retained as `pre-cleanup-review-run/` and `pre-cleanup-review-source/`; it is not the accepted final implementation.

One intermediate test build failed on Swift's region-isolation checker for an inline task-capture expression. Naming the immutable options/destination and using a detached fixture task corrected the test; subsequent focused runs passed 31 and then 34 cases before the final 452-test run. This compiler failure was not treated as a runtime regression pass.

## Boundaries and remaining work

This is TASK-551 worker completion only. Privacy-correct compact DTOs, full storage convergence, rollback, representative scale/RSS measurement, overnight monitoring, native client setup, and higher-level audits remain open. Process-kill recovery of abandoned scratch directories is not claimed: safe recovery needs explicit ownership/recovery evidence, not age-based deletion. Persistent inventory-write failure may still leave a served record requiring recovery; the tested fail-once retry now works. Deliberate concurrent same-user filesystem attacks between identity inspection and a filesystem operation are not a security guarantee of these cleanup checks.

No installed application, real evidence database, watched folder, client configuration, signing identity, or release was changed. Source remains uncommitted in the existing dirty worktree. New IPC regression coverage was explicitly mapped through Pyramid impact G69; no material finding was prematurely closed.

Six obsolete, explicitly identified disposable `.build` directories were removed after their runners terminated and `lsof` reported no open files. About 2.0 GiB of reproducible generated build data was removed permanently (not Trash); original source snapshots and reports remain, and the final accepted candidate build is retained.
