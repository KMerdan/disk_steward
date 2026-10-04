# TASK-623: review window

Candidate input `0b9f7cff5d23f3b330152d959ba42a41963a92a9497209b769960ddbe1d23e28` (on main after `c7639c9`). Nothing has
been installed or published.

## Change

- **Review window** (`Sources/DiskStewardApp/Review/ReviewWindowView.swift`,
  `ReviewWindowModel.swift`). It is a regular window, opened from the menu
  (**Review Storage…**, ⌘R, first item) and from a button on the status
  board. It has:
  - a scope picker: each monitored folder, plus the opted-in tool caches;
  - one primary action: Review Storage, Stop Review, Refresh Review, Choose
    Another Scope, Review a Smaller Scope, or Retry Capacity Read, depending
    on the state;
  - a summary: free space and the reserve on one line, and the review
    estimate on its own line, never added together;
  - items grouped by project, with tool caches as their own group;
  - a detail pane: reclaim estimate with evidence and check time, origin, why
    it may be disposable, reasons to keep it, how to recreate it, the owning
    tool's cleanup command as text, **Reveal in Finder** and **Copy Review
    Brief**.

  The brief ends with "it does not say it is safe to delete".
- **Progress.** `ReviewWalker.withProgress(_:)` reports entries, folders,
  objects found, elapsed time and the current top-level folder. Reports are
  throttled to every 256 folders or 0.25 s. The reviewing line shows these
  counts, never a percentage. `ReviewService.stop()` is `nonisolated`, so
  Stop works while the review holds the actor.
- **Honest states.**
  - A stopped or incomplete review is always **partial**, even with nothing
    found yet. It is never "nothing found".
  - A complete review with no items says only that nothing in *that scope*
    met the rules.
  - Reopening the window loads the latest stored review for the scope.
    Because the stored report keeps its limitations but not the uncovered
    paths, the window shows the stored limitation and says the rest of the
    scope is unknown, without inventing a count.
  - A review that **ran to the end but could not read some folders** (the
    real `~/Library/Caches` has 11 TCC-protected ones) is partial, but it
    did not stop. It says "The review finished, but some folders could not
    be read". Its action is Refresh Review, or Choose Another Scope when
    nothing was found, never Review a Smaller Scope, which would not help.
  - **Item evidence.** The walker keeps an object only once it has
    measured all of it, so each listed size is whole even when the review
    stopped. An item is **Partial** only when folders inside it could not
    be read, which makes its size a lower bound. The ranking's reason
    sentence for this is a shared constant
    (`ReviewRanking.unreadableInside`), so a reopened item is still
    recognised.
- **Keyboard and VoiceOver.**
  - Shortcuts: ⌘R reviews or refreshes, ⌘. stops, ⇧⌘C copies the brief.
  - The summary is one labelled element: free space, the review state and
    when the last review ran.
  - Each row reads its name, size, evidence and check time.
  - The primary action has a hint that says nothing is deleted.

## Evidence

| Run | Result |
| --- | --- |
| `focused-green/` | 46 tests pass |
| `full-suite/` | `verify_candidate.py` on the same input: 696 tests, 0 failures, 11 skipped, candidate `passed`. Attempts 1 and 2 stopped in the test stage on the supervisor's process-classification race (FIND-R4-SUPERVISOR-RACE) before any result, while overlay runs for TASK-661 shared the machine; attempt 3 is the record |
| `brief-says-safe-red/` | The review brief calls the item safe to delete fails `ReviewWindowTests.testCompleteWithItemsGroupsByProjectAndShowsTheDetail` |
| `finished-says-stopped-red/` | A review that finished with unreadable folders is announced as stopped fails `ReviewWindowTests.testACompletedReviewWithUnreadableFoldersDoesNotClaimItStopped`, `ReviewWindowTests.testAStoredCompletedReviewWithUnreadableFoldersReadsTheSame` |
| `free-space-merged-red/` | Free space is combined with the review estimate fails `ReviewWindowTests.testCompleteWithItemsGroupsByProjectAndShowsTheDetail` |
| `interrupted-shows-zero-red/` | An interrupted review is shown as complete fails `ReviewWindowTests.testACompletedReviewWithUnreadableFoldersDoesNotClaimItStopped`, `ReviewWindowTests.testAReopenedInterruptedReviewStaysPartial`, `ReviewWindowTests.testAStoredCompletedReviewWithUnreadableFoldersReadsTheSame`, `ReviewWindowTests.testAccessibilityLabelsCarryAmountsAndFreshness`, `ReviewWindowTests.testAnInterruptedReviewIsPartialAndNeverNothingFound` |
| `invented-percentage-red/` | The reviewing line invents a percentage fails `ReviewWindowTests.testReviewingShowsConcreteCountsAndStop` |
| `lower-bound-not-partial-red/` | A reopened item whose size is a lower bound reads as fully measured fails `ReviewWindowTests.testAReopenedInterruptedReviewStaysPartial` |
| `no-menu-entry-red/` | The menu has no way to open the review window fails `DiskStewardAppTests.testTheUtilityMenuOpensTheReviewWindowFirst` |
| `no-stop-red/` | A running review offers no Stop fails `ReviewWindowTests.testReviewingShowsConcreteCountsAndStop` |
| `row-label-no-freshness-red/` | VoiceOver row labels lose evidence and freshness fails `ReviewWindowTests.testAccessibilityLabelsCarryAmountsAndFreshness` |
| `stale-capacity-red/` | An unreadable volume shows a remembered free-space figure fails `ReviewWindowTests.testAccessibilityLabelsCarryAmountsAndFreshness`, `ReviewWindowTests.testDetailUnavailableAndCapacityUnavailable` |
| `summary-unlabelled-red/` | The summary is not one labelled accessibility element fails `ReviewWindowTests.testAccessibilityLabelsCarryAmountsAndFreshness` |

### Every state in light and dark ([`screenshots/`](screenshots/))

The hosted tests render `ReviewWindowView` in an `NSHostingView` at 900×600
in both appearances. They read the bitmap back with Vision OCR and check the
state's text, so a state that renders but shows the wrong words fails.

| Design state | Screenshot | Checked text |
| --- | --- | --- |
| Comfortable | `review-comfortable-*.png` | "free", "above your", "No review", Review Storage |
| Below reserve | `review-below-reserve-*.png` | "below your", Review Storage |
| Reviewing | `review-reviewing-*.png` | 812,400 entries in 96,120 folders, Stop Review, no "%" |
| Complete with items | `review-complete-with-items-*.png` | "worth reviewing", both items, detail pane, `pnpm install`, Reveal in Finder, Copy Review Brief |
| Complete with zero items | `review-complete-zero-*.png` | "Nothing in the completed scope met review rules", "rest of the disk" |
| Partial (budget-stopped) | `review-partial-*.png`, `review-partial-empty-*.png` | "stopped before covering", "2 folders were not reviewed and are unknown, not empty", "Not reviewed"; the empty case excludes "No candidates" and "Nothing in the completed scope" |
| Partial, reopened from storage | `review-reopened-partial-*.png` | the stored limitation ("huge"); only the item with unreadable folders is Partial |
| Finished with unreadable folders | `review-finished-unreadable-*.png` | "The review finished, but some folders could not be read", "11 folders could not be read", Refresh Review; excludes "stopped before covering" and Review a Smaller Scope |
| Detail unavailable | `review-detail-unavailable-*.png` | "File detail is unavailable", free space still shown |
| Capacity unavailable | `review-capacity-unavailable-*.png` | "Capacity unavailable", Retry Capacity Read, no "GB free" |

`testAReviewRunsEndToEndThroughTheWindow` starts a real review through the
window, using `ReviewService` and `ReviewIndex` on a temporary
`steward.sqlite`. It waits for completion, checks that both items are
revalidated as Verified now, and checks that a newly opened window shows the
stored review.

## Defects found while testing

- **`1 folders`, `1 items`.** The partial and complete lines did not
  singularise. Counts now go through one `count(_:_:_:)` helper.
- **Reopened partial review.** The window would have said "0 folders were
  not reviewed", because a stored report has no uncovered paths. An item
  whose size was a lower bound also lost its Partial mark after a reopen.
  Both are fixed and covered by `testAReopenedInterruptedReviewStaysPartial`.
- **A finished review announced as stopped.** Any incomplete review read
  "The review stopped before covering everything", including one that ran
  to the end and only met unreadable folders. Fixed and covered for the
  live and stored paths
  (`testACompletedReviewWithUnreadableFoldersDoesNotClaimItStopped`,
  `testAStoredCompletedReviewWithUnreadableFoldersReadsTheSame`).
- **Every item of an incomplete review marked Partial.** The mark said that
  each size was a lower bound, which was not true. Now only an item with
  unreadable folders inside is Partial.
- **Test-only problems** (the app was not affected):
  - A programmatic `NSWindow` closed with the default
    `isReleasedWhenClosed = true` over-released under ARC and killed the
    test process after the first window test. The app's own windows
    already set it to `false`.
  - `cacheDisplay` does not draw the window's backdrop. Vision reads
    transparent pixels as black, so light-mode text disappeared for OCR;
    image viewers show them as white, so dark-mode text disappeared
    there. The renders now draw `windowBackgroundColor` behind the view.

- **The menu entry was untested.** The first `no-menu-entry` mutation
  survived, because the menu test compared label constants only. The menu
  is now built from `StatusItemController.menuEntries`, and
  `testTheUtilityMenuOpensTheReviewWindowFirst` checks the built entries
  and the action each one sends.

## Limitations

- **The VoiceOver tree is not inspected.** SwiftUI builds its accessibility
  tree only for an assistive client, so a hosted test sees an empty tree.
  The labels are checked where they are made, in the model, and a source
  check confirms the view uses them. A hands-on VoiceOver pass belongs to
  GATE-669.
- **Stored reports keep their limitation text, not the uncovered paths**
  (CONTRACT-602's `review_reports` has no column for them). A reopened
  partial review shows that text instead of a folder list.
- **Offscreen rendering differs from a key window.** The screenshots come
  from a window that is not key, so the prominent primary button draws as a
  plain bordered button.
- **The status board's Review Storage… button** is wired through
  `StatusBoardViewModel.openReview`, but it is not opened in a hosted test.
