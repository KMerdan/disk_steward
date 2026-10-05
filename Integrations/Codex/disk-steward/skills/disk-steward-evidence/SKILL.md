---
name: disk-steward-evidence
description: Query and interpret local Disk Steward evidence when a user asks what consumed disk space, what recently grew, what can be cleaned up for review, or which agent task may be related.
---

# Disk Steward Evidence

Use the `disk_steward` MCP tools to replace broad filesystem digging with a bounded evidence query.

Start with `get_storage_summary` for free space and the reserve. For "what can be cleaned", use `list_review_items` (the latest review, ranked, with the same sizes and evidence states as Disk Steward's review window; name its scope as `get_health` shows it, or by path) and `get_review_item_evidence` for one item's reasons to keep it and its recreate command. Use `list_largest_objects` for the largest measured build output, environments and caches. Use `explain_growth` for a stated time window: it attributes the volume delta to measured objects and states the unexplained remainder. Use `measure_path` only for one folder inside the configured scopes; it is limited to 15 seconds and 500,000 entries, may return a partial lower bound, and joins a running review instead of starting a second walk. Use `get_task_impact` for a registered agent session and `get_health` when an answer looks incomplete. Use `export_evidence` when the user wants a portable evidence package.

Treat evidence states, confidence and limitations as part of every result:

- `Verified now` was checked within five minutes; `Stale` is older; `Partial` means the size is a lower bound; `Unknown` means the path is no longer found.
- A partial review stopped before covering everything: what it did not cover is unknown, not empty.
- `inferred` is supported correlation, not certainty; task impact is a correlation with a session's workspace and window, never proof of which process wrote.
- `unknown` means no claim is justified.

Never describe a review item as safe to delete. Present it as evidence for human review, with its size, evidence state, reasons to keep it and the owning tool's own cleanup command as text. Do not delete, move, or modify files unless the user separately authorizes that action after reviewing exact targets.

If the app or local socket is unavailable, report the connector's recovery guidance. Do not fabricate a disk explanation or silently fall back to an unbounded scan.
