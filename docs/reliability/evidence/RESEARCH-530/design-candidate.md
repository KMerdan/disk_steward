# Bounded traversal: component decision and remaining storage gate

17 September 2026. **Research candidate, not an approved production migration.**
Read with `benchmark-progress.md`, `prototype-review-reconciliation.md` and the
versioned run collections. Production storage tasks remain behind RESEARCH-530.
The later `query-and-decision.md` records the bounded query comparison, existing
migration checks and an explicit production-implementation block with a finite
follow-up validation matrix. This component recommendation is not schema approval.

## What the evidence supports

The useful boundary is a bounded unit of **work**, not merely a bounded array.
The current lexical scanner limits retained names but repeatedly rereads the
entire directory. The current JSON frontier makes queue persistence proportional
to all pending directories. The current reconciliation transaction retains
atomicity, but combines all preparation/history/current-state writes and staging
cleanup into one unbounded final call.

The smallest promising component combination is:

1. One process-local directory stream; at most 512 retained names. Durable pass
   epochs invalidate unfinished work after handle loss. Never persist a native
   directory cookie. If a batch fails after consuming names, poison the instance
   and reopen/replay rather than attempting an unsafe same-stream retry.
2. Indexed durable pending-directory rows; page/delta persistence only. Verify the
   actual query plan. The first prototype's unforced index still allowed a full
   temporary queue sort. The corrected measured shape needs at most 31 SQLite VM
   steps per queue lookup on the tested 100k-directory fixture.
3. Prepare next-visible evidence in bounded transactions; an original-revision
   permit protects a short atomic publication. Keep prior visible evidence
   unchanged until every required producing pass and coverage condition is valid.
4. Reclaim retired scratch/prepared state in bounded transactions, separately from
   publication. Physical old epochs, WAL and pinned readers still count toward
   capacity even when those rows are no longer logically visible.

The name spool remains a comparison option, not the default recommendation yet.
It can resume metadata sampling without rereading a fully spooled directory, but
adds name writes, reads and reclamation. The 100k-directory experiment completed
in 25.088 seconds streaming versus 39.881 seconds spooling. Two generations over
100k files distributed through 32 directory levels took 1.879 versus 2.349 seconds.
These are single-run experimental observations, not app speed guarantees. The
million-file fresh candidate published its first generation in 68.094 seconds
streaming versus 71.734 seconds spooling. Both stopped during their second
generation at the unchanged 120-second experiment limit, preserving generation 1.
That initial attempt does not prove two-generation completion or full product costs.
The subsequent `recovery-and-space-progress.md` records successful generation-2
recovery in both modes, but also admission stops when a long reader pins the WAL.
The real 10k-file product-schema accounting in that report separates live b-tree
pages, reusable pages and peak WAL; full product costs are materially higher than
this compact traversal schema.

## Lifecycle requirements the production adaptation must preserve

| Object | Lifetime / visibility | Failure and reclamation rule |
| --- | --- | --- |
| Native directory stream | One process and one active pass | Close on EOF, cancellation, error or shutdown. On loss, replay that unfinished pass with a new durable epoch. |
| Pending directory row | One root-specific generation/pass lineage | Do not materialize the entire frontier in Swift. Invalid lineage is never proof of absence. Bounded cleanup must prevent orphan-heavy dequeue scans. |
| Prepared file/path contribution | Its own root, producing pass, identity and real sample time | Hidden until that producing pass is complete and validated. Never authorize a failed overlapping root using another root's pass. |
| Published current evidence | Last successfully published generation/revision | Survives failed scans, capacity stops, restart and history eviction. Unavailable coverage is unknown/stale, not deleted. |
| Receipt revision | From notification admission through durable invalidation/reconciliation | A replacement permit cannot approve observations from the old revision. Restart must establish uncertainty before accepting fresh publication. |
| Spool/old-epoch rows | Scratch only; physical until actually reclaimed | Charge storage until bounded deletion/checkpoint reuse succeeds. Logical invisibility is not recovered disk headroom. |
| Historical evidence | User-visible retention contract, distinct from live truth | Aggregate/evict with explicit coverage gaps. Never prune live state merely to satisfy history limits. |
| MCP/export read view | One bounded operation and its explicit revision | Avoid holding a SQLite reader indefinitely across client requests. Detect changed revision rather than silently combining pages. |

The pinned-reader experiment makes that final row load-bearing: admission must
stop new writes before headroom is exhausted, end/cancel owned expired read views,
checkpoint only after the reader constraint is removed, and remeasure actual
headroom before resuming. Never spin on checkpoints or fabricate successful space
recovery while an external/unknown reader still pins required pages.

The prototype's fenced restart intentionally refuses publication and retains old
visible evidence. That proves fail-closed behavior, **not** the final production
restart/reconciliation path. The product must also make progress after recovery.

## Why pointer-switch timings do not settle the product design

The compact schema records only path membership and sampled metadata, retaining
at most one prior and one preparing/published generation. It does not perform the
product's object occurrence reconciliation, path-binding history, change-event
construction, root overlap resolution, failed-root carry-forward, privacy DTOs or
migration. Its sub-millisecond pointer switch measures the switch, not all that
missing preparation.

The production `EvidenceStore.reconcileCompletedScanGeneration` reserves an
estimated per-file cost, then inside one transaction writes observation/snapshot
metadata, deduplicates overlapping staging, reconciles objects, updates current
state/history/events and deletes staging/passes. Current state and baseline
history repeat object IDs and full paths across several tables/indexes. A missing
open-path object index explains part of the CPU cost, but cannot remove this
storage amplification. Unchanged scans already avoid adding a history row for
every unchanged file; do not claim that optimization as a new fix.

Before selecting a production layout, measure a semantically representative store
including current state, changed-state history, path aliases, producing-pass
provenance, actual sample times and uncertainty. A compact substitute that omits
these is only a lower bound. Avoid extrapolating the prototype's bytes per file
into a promise that the current full schema fits one million files under 512 MiB.

Required peak-space accounting is:

`visible state + prepared work + retained history + unreclaimed rows/pages + WAL/SHM + recovery/migration copies`.

The prototype's 4 MiB reserve is a research heuristic, not a proof of worst-case
per-transaction growth. Long paths, index page splits, failed/replayed passes and
pinned readers must be measured. Keep product limits unchanged; if required
authoritative state cannot fit, report the coverage/capacity limitation explicitly.

## Migration and rollback alternatives to evaluate

- **Add only the open-path index:** smallest schema change and already measured
  CPU benefit, but does not fix repeated enumeration, JSON frontier cost or large
  final publication. Not a complete solution.
- **Normalize only pending traversal:** fixes queue representation and enumeration
  work, but leaves the current publication/storage problem. Useful component, not
  sufficient acceptance for the full incident.
- **Bounded prepared generations with atomic visibility:** best experimental
  direction, but requires all production queries/exports to respect the same
  visibility and provenance rules. Measure full semantic preparation and cleanup,
  not just the pointer update. Do not expose partial current-state rewrites.
- **Shadow-database migration:** makes verification and atomic handoff easier to
  reason about, but needs simultaneous old/new/WAL/recovery space and a tested
  interrupted-swap recovery journal. A nearly full existing store may lack that
  headroom. It must refuse safely before changing authority if space is inadequate.
- **In-place staged migration:** can reduce duplicate-file space, but old tables,
  new tables, WAL and rollback data still overlap. Cancellation must leave either
  the old usable schema or a resumable migration, never a partially relabeled DB.
  Bounded batches alone do not prove that rolling back schema/semantics is safe.

Neither migration is selected here. Do not change a schema version or declare
TASK-531/TASK-532 complete on these research-only results. The remaining decision
needs a product-equivalent sizing/semantic experiment plus pinned-reader,
mutation/restart and bounded-reclamation evidence, or an explicit documented
implementation block under the unchanged acceptance contract.
