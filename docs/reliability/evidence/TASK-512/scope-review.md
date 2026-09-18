# TASK-512 — application and socket ownership

Source candidate: `9546220c27852fa5ce07726087db12e855e6b9818afacc2e063ad723595ba2b2`.
Only two product/test files changed in this task: the core Unix socket server
and SocketOwnershipRegressionTests. Existing main.swift still holds the
independent application.lock lifetime lease before starting app services.
No installed app, real client configuration or evidence database was changed.

## Reproduction and engineering decisions

The legacy collision probe compiled four unchanged IPC sources from commit
`cf313e4527a3bd30dae217d2c1ff68d7a7a87b60`. Its second start replaced the live
same-owner endpoint; stopping the first removed the replacement. The primitive
Swift throwing initializer also confirmed that explicit close followed by
deinit could close twice. Logs and reusable probe sources accompany this report.

The lease now initializes its stored descriptor only after all throwing checks.
Its lock inode is persistent and never unlinked. The nonblocking listener's
DispatchSource cancel handler alone closes its descriptor; stop revokes and
cancels without freeing a descriptor still referenced by an old callback.
The epoch check and accept are serialized under the state lock.

Startup journals a private staging-directory identity before bind, and the
endpoint identity before exclusive publication. Two bounded 2 KiB journal slots
with checksums retain the previous complete record across a partial write.
Recovery may remove only the socket named s in the matching private workspace;
it preserves regular files, links, substituted directories and unrelated siblings.
Public cleanup requires the recorded socket's device/inode. Unknown public
listeners are refused without even making a probe connection.

Publication uses Darwin RENAME_EXCL, never overwrite-style rename. Apple documents
exclusive rename support: https://developer.apple.com/documentation/foundation/urlresourcevalues/volumesupportsexclusiverenaming
The local macOS rename(2) manual specifies EEXIST when the destination exists.
The fixture verifies a late occupant survives publication failure and verifies
clients can connect after the staged Unix socket is renamed.

## Evidence scope

- 17 socket tests (one is the explicitly selected subprocess fixture entrypoint).
- Ten abrupt checkpoint exits: five startup boundaries, each repeated with an
  existing journal, including a partial endpoint-record write.
- Five throwing-startup checkpoints prove owned cleanup and successful retry.
- A held accept callback spans stop/restart; the old descriptor stays allocated
  until its callback drains, and the successor answers its first request.
- Forty immediate restart/query cycles; full-capacity public Unix socket path
  connects and restarts using compact staging in its private ancestor.
- 64 scoped integration/isolation tests pass; actual smoke subprocesses preserve
  fake-production endpoint and sentinels, and fixture helper queries still work.

An intermediate candidate failed three tests because Foundation createDirectory
without intermediates rejects an already-existing directory. Replacing that with
mkdir plus explicit EEXIST/identity validation corrected reuse. These failures
were not counted as product passes. The old 92cb candidate review is stale:
long-path and checkpoint fixes changed that tree while its final feedback was
pending. Final review uses a newly copied, untouched snapshot instead.

## Limits and remaining work

This proves cooperative process-lifetime ownership, not hostile same-user path
races or filesystem power-loss durability. A very long public path needs a
short enough private same-filesystem ancestor for staging; the standard app path
and a maximum-length fixture are covered. Unknown legacy endpoints fail closed.
The persistent per-service metadata is one private directory and a journal
bounded to 4 KiB; it is not an ever-growing crash log.

Suspended backend handlers may still retain cross-epoch connection capacity.
TASK-541 owns cancellation/draining and its explicit adversarial tests;
FIND-SERVICE remains open. Query, scale, migration/rollback and release assurance
also remain unfinished. No audit or release pass is implied by this task's tests.
