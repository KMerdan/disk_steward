# HOTFIX-1.5.1: review-tool fixes found in the first real cleanup

On 2026-10-05 the maintainer used the installed, notarized 1.5.0 (12) for a
real cleanup. Its MCP helper was called over stdio, following the agent skill
(`get_health`, then `list_review_items`, then `get_review_item_evidence`).
Three defects showed up. PLAN-DISK-STEWARD-006 is closed, so they are fixed
here as a hotfix, like HOTFIX-1.2.4, rather than as a new intent.

Candidate input: `6acbcbec55a99610aa34053b28586d1aa07912ade605502e5e56be0d6557ac0c` (on `main` after `0b003ba`). It is committed
locally only: there is no version bump, and nothing is installed or published.

## Defects and fixes

### 1. A scope name did not round-trip

- **Defect.** `get_health` shows each review's `scope` with the default path
  detail: `basename`, for example `localGit`. Passing that name to
  `list_review_items` answered `report: null` with "No review of that scope
  is stored."
  - `list_largest_objects` silently listed nothing for it.
  - The backend `realpath`ed the bare name against the app's working
    directory.
- **Fix** (`AppEvidenceQueryBackend.reviewScope`). A `scope` is resolved as
  follows:
  - `caches`, or an absolute or `~` path, as before;
  - otherwise, a name is matched against the stored reviews' scopes and the
    watched folders, by basename or by its `sha256:` form, and never
    against the working directory;
  - a name that matches several scopes is never picked;
  - a name that matches none, or several, answers `report: null` with a
    limitation and `available_scopes`. Shared names are listed in their
    `sha256:` form so the choices differ.

  `list_largest_objects` answers the same way instead of listing nothing.
  `measure_path` now refuses a relative `path` (`invalid_request`).
- **Contract.** The tool descriptions, `Fixtures/MCP/readonly-inventory.json`,
  `docs/architecture/mcp.md` and the agent skill say a scope may be the name
  `get_health` shows.

### 2. Cargo `target` folders were labelled downloadable caches

- **Defect.** Cargo writes `CACHEDIR.TAG` into `target/`. The classifier's
  self-marker rule decided first, so these folders were treated as follows:
  - `kind: cache` and `recreate_class: re-download`;
  - "Recreated by the tool that owns it the next time it needs the cache.";
  - "It can be downloaded again."

  Examples: `ai-gateway/apps/gateway/target` (4.15 GB) and
  `causation-agent/…/src-tauri/target` (4.66 GB). RESEARCH-601's corpus had
  recorded them the same way.
- **Fix** (`ObjectClassifier.classify`, `ObjectDetectionRules.cacheTaggedOutputs`).
  A `target` holding `CACHEDIR.TAG` with `Cargo.toml` beside it is:
  - build output (`artifact`, rule `manifest`, high confidence);
  - owned by that folder, so ranking offers `cargo build` and the class
    `rebuild`.

  The exception is deliberately narrow:
  - `.pytest_cache`, `.mypy_cache` and every other tagged folder stay caches;
  - so does a tagged `target` with no `Cargo.toml` beside it.

  The CONTRACT-601 object contract and RESEARCH-601's detection rules record
  the exception.
- **Existing reviews keep their stored classification** until the next review
  of that scope.

### 3. "It can be rebuilt from source" with no known rebuild command

- **Defect.** An item whose rebuild command is unknown said both "It can be
  rebuilt from source." (why it may be disposable) and "No rebuild command
  is known for it." (reason to keep). The example was
  `disk_steward/build`, the release workspace.
- **Fix.**
  - `ReviewRanking.rank` no longer adds the rebuild sentence when the command
    is unknown.
  - `ReviewItemPresentation` drops it from reviews stored by 1.5.0, so the
    window and the agent tools stop contradicting themselves without
    needing a new review.

## Evidence

**Green** ([`green/`](green/)). A focused isolated run passed 70 tests with
0 failures. It covered `ObjectClassificationTests`, `ReviewRankingTests`,
`ReviewToolsTests`, `ReviewWalkerTests`, `ReviewWindowTests`,
`ReviewCatalogIncrementTests`, `DiskStewardMCPTests` and `MCPContractTests`.

**New tests:**
- `ReviewToolsTests.testAScopeNameFromHealthIsAcceptedBack`:
  - `get_health`'s `scope` goes back into `list_review_items` and
    `list_largest_objects`, as does its `sha256:` form;
  - an unknown name returns `available_scopes`, and `list_largest_objects`
    lists nothing for it;
  - two scopes named `code` are never resolved to either, and each listed
    `sha256:` choice works;
  - a relative `measure_path` is refused.
- `ObjectClassificationTests.testACargoTargetTaggedAsACacheIsItsProjectsBuildOutput`:
  - a tagged `target` beside `Cargo.toml` is build output owned by that
    folder;
  - a tagged `.pytest_cache` and a tagged `target` without `Cargo.toml`
    stay caches.
- `ReviewRankingTests.testAnUnknownRebuildIsNeverCalledRebuildable`: a new
  ranking, and a review stored by 1.5.0, never say "It can be rebuilt" with
  no known command.
- `ReviewRankingTests.testTheReviewStoresRankedItemsWithTheirCommands`: its
  cargo fixture now carries `CACHEDIR.TAG`, as real cargo writes it, and the
  stored item is `artifact`, `rebuild`, `cargo build`.

**Reds** ([`reds/`](reds/), specs in [`mutations/`](mutations/)). Each
mutation runs on a snapshot of input `6acbcbec`; the repository is never
modified. Each fails only the test it targets.

| Mutation | Fails |
| --- | --- |
| `scope-as-before`: the 1.5.0 resolution (`realpath` of any name) | `testAScopeNameFromHealthIsAcceptedBack` |
| `scope-basename-ignored`: only the `sha256:` form matches | `testAScopeNameFromHealthIsAcceptedBack` |
| `scope-ambiguous-picked`: a shared name resolves to the first scope | `testAScopeNameFromHealthIsAcceptedBack` |
| `largest-unmatched-lists-all`: an unknown name lists every object | `testAScopeNameFromHealthIsAcceptedBack` |
| `measure-relative-resolved`: a relative `measure_path` is resolved | `testAScopeNameFromHealthIsAcceptedBack` |
| `cargo-tag-decides`: the 1.5.0 classification | `testACargoTargetTaggedAsACacheIsItsProjectsBuildOutput`, `testTheReviewStoresRankedItemsWithTheirCommands` |
| `tag-overridden-for-every-output`: any output name with its manifest overrides the tag | `testACargoTargetTaggedAsACacheIsItsProjectsBuildOutput` (the `.pytest_cache` case) |
| `ranking-claims-rebuildable`: the 1.5.0 ranking sentence | `testAnUnknownRebuildIsNeverCalledRebuildable` |
| `stored-claim-shown`: a stored claim is shown | `testAnUnknownRebuildIsNeverCalledRebuildable` |

**Real tree.** The two cargo `target` folders still present under
`~/localGit` both have `CACHEDIR.TAG` inside and `Cargo.toml` beside:
`ai-gateway/apps/gateway` and `causation-agent/desktop_src/causation-core`.

**Full verification** ([`full-1/`](full-1/), [`full-2/`](full-2/)). Two
`verify_candidate.py --xcodegen` runs were made on input `6acbcbec`:
- Each ran 730 tests (11 opt-in skips) with one failure, the accepted
  FIND-R4-OBJECT-CONVERGENCE-FLAKE: `ObjectConvergenceTests` seeds the retired
  scanner's store and reports "change evidence is later than observation
  publication". Its fixture holds only `node_modules`, and no changed code
  runs in it.
- Three focused reruns of `ObjectConvergenceTests` on the same input all
  passed ([`convergence-reruns.txt`](convergence-reruns.txt)).
- The packaged-build stage did not run, because the tests stage stops a
  verification first. That is the only stage this hotfix has not shown green.

## Limitations

- **Packaged build not shown.** Both full runs stopped at the flaky test
  before the packaged-build stage. A 1.5.1 release build would run it.
- **Not installed.** The installed 1.5.0 (12) keeps the defects until a
  1.5.1 is built, notarized and published, which needs the maintainer's
  go-ahead.
- **Existing reviews.** Cargo targets keep their stored `cache`
  classification until that scope is reviewed again. The wording fix applies
  to stored reviews at once.
- **Scope names.** A bare name is matched only against stored reviews and
  watched folders. A folder that is neither has no name to match, and its
  absolute path is still needed.
