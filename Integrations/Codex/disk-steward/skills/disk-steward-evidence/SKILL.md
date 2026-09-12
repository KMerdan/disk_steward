---
name: disk-steward-evidence
description: Query and interpret local Disk Steward evidence when a user asks what consumed disk space, what recently grew, which agent task may be related, or what deserves cleanup review.
---

# Disk Steward Evidence

Use the `disk_steward` MCP tools to replace broad filesystem digging with a bounded evidence query.

Start with `get_storage_summary`. Use `explain_growth` for a stated time window, `get_provenance` for a path, and `get_task_impact` only for an active registered session. Use `export_evidence` when the user wants a portable evidence package or another agent needs the complete bounded record.

Treat confidence and limitations as part of every result:

- `exact` requires direct operation-to-process observation.
- `tool-linked` identifies an authenticated agent process tree, but does not prove that it wrote each file.
- `inferred` is supported correlation, not certainty.
- `unknown` means no actor claim is justified.

Never describe an item from `find_cleanup_candidates` as safe to delete. Present it as evidence for human review, including size, age, confidence, and limitations. Do not delete, move, or modify files unless the user separately authorizes that action after reviewing exact targets.

If the app or local socket is unavailable, report the connector's recovery guidance. Do not fabricate a disk explanation or silently fall back to an unbounded scan.
