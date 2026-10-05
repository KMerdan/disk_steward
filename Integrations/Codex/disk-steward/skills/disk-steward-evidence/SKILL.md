---
name: disk-steward-evidence
description: Disk space, storage growth and cleanup review on this Mac. Query and interpret local Disk Steward evidence when a user asks what is using disk space, what grew recently, what can be cleaned up for review, how big a folder is, or which agent task may have changed which folders.
license: MIT
compatibility: Needs the Disk Steward app (macOS 13 or later) with Agent Access on, and its disk-steward MCP server.
---

# Disk Steward Evidence

Use the `disk-steward` MCP tools for bounded, read-only evidence instead of walking the disk yourself.

## Which tool answers which question

- **How full is the disk, and how far from the reserve?** `get_storage_summary`.
- **Are the stores, journal and reviews healthy, and which scopes have been reviewed?** `get_health`. It names each review's `scope` the way the other tools accept it.
- **What can be cleaned up for review?** `list_review_items` with `scope` set to a name from `get_health` (for example `localGit`), a folder's absolute path, or `caches`. Then use `get_review_item_evidence` with an `item_id` for one item's reasons to keep it, its recreate command and a live check. If no review matches the name, the answer lists `available_scopes`.
- **What are the largest build outputs, environments and caches?** `list_largest_objects`, optionally with the same `scope`.
- **Where did space go over an interval?** `explain_growth` with `from` and `through`. It reports the capacity change, the measured object deltas, and the unexplained remainder.
- **How big is one folder right now?** `measure_path` with an absolute path inside a reviewed scope. It is bounded to 15 seconds and 500,000 entries, may return a partial lower bound, and joins a running review instead of starting another walk.
- **What did an agent session change?** `get_task_impact` for a registered session, or `list_active_agent_sessions`.
- **Who needs a portable evidence package?** `export_evidence`.

## Reading the answers

- **Evidence states:**
  - `Verified now` was checked within five minutes;
  - `Stale` is older;
  - `Partial` means the size is a lower bound;
  - `Unknown` means the path was not found at the last check.
- **A partial review** stopped before covering everything. What it did not cover is unknown, not empty.
- **Confidence:** `inferred` is a supported correlation, not certainty. Task impact correlates a session's workspace and time window; it never proves which process wrote. `unknown` means no claim is justified.
- **Errors:** an error result's text is a JSON object with `code`, `message`, `retryable` and `recovery`. Follow `recovery`. Correct `invalid_arguments` and call again. Never retry `agent_access_disabled` until the user turns Agent Access on.

## Cleaning up safely

Never describe an item as safe to delete. For each item, present:
- its size;
- its evidence state;
- its reasons to keep it;
- its recreate command;
- the owning tool's cleanup command, as text.

Do not delete, move or modify files unless the user separately authorizes that action after reviewing the exact targets. Prefer reversible actions such as moving a folder to the Trash, and say how to undo them. After a cleanup, call `get_review_item_evidence` again: a removed item reads `Unknown` with `present: false`.

If the app or its local socket is unavailable, report the recovery guidance. Do not fabricate a disk explanation, and do not fall back to an unbounded scan.
