# CONTRACT-602: fixed-cap store contract

Candidate input `fca64a1f17c43b39e5b4f703ad0043551bd4a23fc935375be9dd90edde35d152`. Contract:
[bounded-store-contract.md](bounded-store-contract.md). Code:
`Sources/DiskStewardCore/EvidenceStore/BoundedStore.swift`, plus a
`changeCount()` accessor on `SQLiteConnection`. Tests:
`Tests/DiskStewardCoreTests/EvidenceStore/BoundedStoreContractTests.swift`.
Nothing is committed with this task's evidence yet, and no consumer uses the
API: TASK-651, 652, 621, 622 and 671 will.

| Run | Result |
| --- | --- |
| `focused-green/` | 7 contract tests pass. The worst case across both files is 28.44 MiB, under the 32 MiB ceiling. Cap + 1 holds on every table, and the byte cap evicts the oldest rows. An oversized row is refused at write. An oversized group batch is refused whole. Every reader at cap answers under 1 MiB. Journal modes are `delete` and `wal` |
| `no-eviction-red/` | Enforcement removed: cap + 1 and byte-cap tests fail |
| `no-size-refusal-red/` | Write-time limit removed: the oversized row lands |
| `no-index-term-red/` | Index entries dropped from the budget: a table over the ceiling passes validation |

The first green run found two problems in this contract's own table
definitions, which validation rejected:

- three eviction-order columns were not indexed;
- the worst case was 36.4 MiB.

The caps were then set to the values in the contract table.

The static check meets AC-CONTRACT-602-01 in byte-cap form; the contract
document explains why. The design document's data-model table is superseded
by the contract and will be corrected in a separate docs change, because
`docs/product/` is outside this task's assets.
