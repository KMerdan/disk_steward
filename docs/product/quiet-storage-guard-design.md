# Disk Steward: quiet guard and project review

Status: product and interaction design proposal, 2026-09-23. This document is
not an implemented feature or a release claim. The active Pyramid Task object
plan remains canonical for implementation until it is explicitly replanned.

## Product decision

Disk Steward earns its place on the Mac by answering two questions:

1. **Am I approaching the amount of free space I want to keep?** This must be
   cheap, reliable, and answerable without a file inventory.
2. **When I choose to investigate, what development work is worth reviewing?**
   The answer is a small list of current, explained project and generated-data
   groups that a human can inspect before making a cleanup decision.

The user may open the app only a few times a year. Success is a short, accurate
path from concern to decision, with negligible cost between those moments.
The initial focus is coding projects, build output, agent-generated artifacts,
and developer caches. System Data can be shown as unexplained capacity change;
the app must not imply it has identified inaccessible system files.

Existing macOS Storage settings provide generic capacity and recommendations.
DaisyDisk and GrandPerspective locate large files visually. DevCleaner focuses
on Xcode caches. Disk Steward's hypothesis is that project context, evidence
freshness, and a bounded agent-readable review can shorten a developer's
investigation. This is a hypothesis to validate with real cleanup sessions.

## Why the current release needs a change

The read-only live check on 2026-09-23 used the installed 1.2.3 helper's MCP
protocol. `get_storage_summary`, `get_evidence_lifecycle`, and
`explain_growth` returned `query_budget_exceeded`. The live store had 548
retention coverage gaps; its lifecycle summary refuses more than 512. A
consumer query returned partial coverage with persisted state from September
13. A large-item candidate query returned no revalidated item. The active
scan, started September 18, had accumulated over 55 million processed entries
with only one of three roots complete. Its roots include `localGit`. In a
ten-second sample the app consumed about 4.7 CPU seconds; its evidence
directory occupied about 393 MiB. The Data volume had about 418 GiB free.

These measurements describe that live session, not a benchmark of every
installation. They establish two design constraints: capacity must stay
available when detailed evidence fails, and background work must stop when it
cannot produce a timely review. Preserve the existing database; no silent
reset or deletion is part of this design.

## Two operating modes

### Quiet guard (default)

- Capture only volume identity, free/used bytes, timestamp, and a compact
  capacity history. It does not walk watched folders or start a file database
  job at launch.
- Let the user choose a **comfort reserve** in GiB. Present this as a personal
  preference, with an editable suggestion based on disk size. The previous
  percentage threshold remains migratable but is not the main explanation.
- Notify once when measured free space crosses below the reserve after two
  comparable samples. Suppress repeats until free space recovers above the
  reserve plus hysteresis. A large growth alert above the reserve is opt-in.
- Do not promise a cause from volume measurements. The alert says the exact
  free space, reserve, and interval, then offers **Review storage**.
- Display `Capacity unavailable` when the volume cannot be measured; never
  reuse an old measurement as if it were live.

### Review (explicit user action)

- Start with a bounded scope: a chosen project, Downloads, a specific
  developer cache, or a folder selected by the user. Project review groups
  build outputs and generated artifacts as objects; it does not persist one
  row per file across an entire repository.
- Show elapsed time, scope, measured work, current phase, and a **Stop**
  control. If total work is unknown, use an indeterminate indicator and
  concrete counts; never invent a percentage.
- Enforce elapsed-time, CPU, memory, row, and database budgets in the worker.
  Exceeding one yields a partial report with a reason. The app returns to
  quiet guard without immediately restarting the same scan.
- Revalidate each proposed item against the live path and identity before
  showing it as present. A changed or inaccessible item becomes `Needs a new
  review`, not an actionable candidate.
- Show a finished review until its expiry or a relevant file-change event.
  A cached result is labeled with its scope, completed time, and coverage.

## Interface structure

### Notch island: the glanceable surface

Use a visually continuous black island that grows from the MacBook camera
housing into the display. The expanded surface is a compact interactive
popover, **not** a detached glass card, a terminal, or the detailed review
window. Its material remains nearly black in both system appearances. No app
logo, redundant title, decorative gauge, perpetual spinner, or monitoring
diagnostic line appears here.

In priority order the expanded island shows:

1. **Measured free space**, with the volume identified in its accessibility
   description. Never substitute a stale sample for a failed live read.
2. **Distance to the user's comfort reserve**: for example, `82 GB below your
   500 GB reserve`. This is the explanation for the amber attention signal,
   not a claim about what created the files.
3. **File-evidence freshness or limitation**: for example, `File detail last
   reviewed 10 days ago` or `File detail unavailable`. It is omitted when no
   detail exists and replaced with `No file review yet` only when useful.
4. **One action**: `Review storage`, `Open review`, `Stop review`, or `Review a
   smaller scope`, matching the current state. Settings, export, MCP setup,
   and Quit live elsewhere.

The collapsed surface shows only a short free-space value (`418 GB`) beside
the camera housing. The value is neutral above the reserve and amber below
it. A tiny amber mark may accompany the value when attention is needed; it
must never imply that file scanning is continuously active. Click opens the
island; click again, Escape, or clicking outside closes it. Hover can be an
optional reveal preference, but is not the only way to discover or operate
the control. Opening the island reads current capacity without starting a
file walk. No motion loops while idle. A reserve-crossing alert may briefly
expand, then returns to the collapsed state after the user dismisses it.

Use the notch only on a verified compatible built-in display, position the
interactive region in display-safe space, and never place text or controls
behind the physical camera housing. A regular status item or keyboard entry
point remains available on external displays, Macs without a notch, and
configurations where the island cannot safely appear. The user can choose
`Notch`, `Menu bar`, or `Both` in Settings; migration preserves the existing
menu bar entry until the notch mode has been tried successfully. Full-screen,
presentation, multiple displays, menu-bar auto-hide, accessibility text size,
and screen recording need explicit QA before any default switch.

The existing right-click utility menu can retain Settings, Export, About, and
Quit in menu-bar mode. A full review is a regular macOS window because the
user must compare evidence, inspect risks, and navigate more than one item.
A modal dialog is reserved for a focused confirmation or a destructive action
if one is ever added. Implement the island shell with AppKit window and screen
geometry and the content in SwiftUI; UIKit/Mac Catalyst adds no benefit to
this native macOS app.

**Review window**:

- Toolbar: scope selector, review timestamp, **Start/Refresh review**, Stop
  while running, and an overflow menu for export and settings.
- Summary: amount *worth reviewing*, not a claim that all of it is
  reclaimable. Show observed free space separately from estimated review size.
- Item list: name and project, allocated size, reason it is listed, last
  activity, and a visible evidence state (`Verified now`, `Stale`, `Partial`,
  or `Unknown`). Group a project's generated objects together.
- Detail pane: origin, why it may be disposable, reasons to keep it, exact
  paths and last verification, known reclaim estimate or `Unknown`, and
  **Reveal in Finder**. A separate **Copy review brief** action gives a user
  portable context without requiring an MCP client.

**States**:

| State | Expanded island content | Primary action |
| --- | --- | --- |
| Comfortable, no review | Free space and amount above reserve; no warning color. | Review storage |
| Below reserve, no review | Free space, amount below reserve, age of file detail. | Review storage |
| Reviewing | Free space stays visible; scope, elapsed time, and concrete work count replace evidence age. | Stop review |
| Complete with items | Free space, reserve distance, verified review scope and completion time. | Open review |
| Complete with zero items | `Nothing in the completed scope met review rules`; do not generalize to the disk. | Choose another scope |
| Partial or budget stopped | Free space remains visible; say what was covered and what is unknown. | Review smaller scope |
| File evidence unavailable | Live free space remains visible; detail failure is explicit. | Review smaller scope |
| Capacity unavailable | No old free-space number is shown as current. | Retry capacity read |

All states need full keyboard access, VoiceOver labels that include amounts and
freshness, adequate contrast in both appearances, and no status conveyed by
color alone. The collapsed surface must expose a descriptive accessibility
label and a keyboard route to the expanded island. An interrupted scan must
never show a `No candidates` empty state.

## Review item and MCP contract

The app window, MCP, and export consume one versioned `ReviewReport` read
model. At minimum it contains:

- `scope`, `started_at`, `completed_at`, `coverage`, `status`, and
  `limitations` at report level;
- current path or privacy-shaped path, object type, project, allocated bytes,
  estimated reclaimable bytes **or unknown**, last activity, and verification
  time for each item;
- observation method, supported attribution, reasons to review, reasons to
  keep, and a linkable evidence reference;
- a stable distinction among **present and verified**, **stale**, **partial**,
  and **unknown**. There is no `safe_to_delete` boolean.

MCP health reads must always return live volume capacity and detail status,
even if the detailed store is over budget. `get_latest_review`,
`list_review_items`, and `get_review_item_evidence` are bounded read-only
queries over that report. An MCP call must not silently start a large scan.
When a user asks an agent for help, the agent can quote the current report,
its freshness, and its uncertainty. The app remains usable without MCP.

## Resource and lifecycle contract

- Quiet guard has no continuous file traversal. Its capacity history is a
  small, capped ring, independent of the detailed evidence database.
- A review job is cancellable and isolated from the menu process where
  possible; the supervisor owns descendants and verifies exit on stop.
- At most one review per scope runs at once. A repeated request joins it or
  asks to replace it explicitly.
- Report size, item count, and retained review count are capped. Expiration
  removes app-owned cached review data according to a documented policy;
  manual exports and user files are never part of this retention.
- Store pressure returns aggregate health and a precise `detail unavailable`
  state. It cannot make the basic free-space query fail.
- An unfinished review never auto-resumes after relaunch. A stopped job keeps
  a partial report only if that partial coverage can be stated truthfully.

Proposed performance gates for a real Mac with the user's `localGit` scope:

1. Over 24 hours in quiet mode, no file traversal occurs; average app CPU is
   below 1% of one core and the guard creates only a small, bounded history.
2. On-demand review stops within its advertised budget, including on an
   inaccessible or million-file tree. Stop releases all owned workers.
3. Live headroom remains queryable through the UI and MCP under a corrupt,
   full, stale, or over-budget detail store.
4. A complete review supports a correct zero-result state; a partial review
   never claims that nothing is present.
5. A real developer can reach a justified keep-or-review decision for a
   meaningful object faster than with Finder or a generic disk scan. Record
   task completion time, false leads, and background CPU, not app-open count.

## Delivery sequence

1. Repair the current health contract: independent live capacity, honest
   stale/over-budget state, and a hard stop for nonconverging scans.
2. Ship quiet guard as the default, with migration from the current watched
   roots and preservation of their old evidence for explicit review/export.
3. Ship one bounded project review that groups build output and generated
   artifacts, then validate it against a real large repository.
4. Add the shared review read model to MCP and export; test a human and an
   agent on the same evidence and uncertainty labels.
5. Add other developer caches only when they fit the same ownership and
   revalidation contract.

The current `.pyramid` graph covers object grouping and review presentation,
but its always-on scanning assumption and release gates require a replan
before implementation. This design does not mark any existing task complete.

## Design references

- [Apple macOS Storage](https://support.apple.com/guide/mac-help/optimize-storage-space-sysp4ee93ca4/mac)
- [Apple alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)
- [Apple menus](https://developer.apple.com/design/human-interface-guidelines/menus)
- [Component Gallery: popover](https://component.gallery/components/popover/)
- [Component Gallery: progress bar](https://component.gallery/components/progress-bar/)
- [Component Gallery: empty state](https://component.gallery/components/empty-state/)
- [Apple: camera-housing safe-area compatibility](https://developer.apple.com/documentation/bundleresources/information-property-list/nsprefersdisplaysafeareacompatibilitymode)
- [DaisyDisk](https://web.daisydiskapp.com/)
- [GrandPerspective](https://grandperspectiv.sourceforge.net/)
- [DevCleaner for Xcode](https://github.com/vashpan/xcode-dev-cleaner)
