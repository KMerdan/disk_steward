# Disk Steward Evidence Brief

Requested period: 2033-05-18T03:33:20.000Z through 2033-05-18T03:35:20.000Z

This bundle is a consistent, time-bounded view of previously recorded metadata. It does not rescan the disk.

## Summary

- Raw events: 1
- Hourly rollup rows: 0
- Daily rollup rows: 0
- Storage snapshots: 1
- Net allocated-byte delta across retained detail and rollups: 4096

| Consumer category | Events | Allocated-byte delta |
|---|---:|---:|
| developer-cache | 1 | 4096 |

## Largest retained events

- `cache.bin` — create, 4096 allocated bytes, inferred via snapshot-delta.

## Limitations

- Creator process and agent session fields are null unless a recorded attribution source established them.
- Fixture snapshot limitation.

## How to inspect

Verify `manifest.json` hashes, read `summary.json` and `rollups.json`, and decompress `events.jsonl.zlib` as zlib-compressed JSON Lines. Every attribution includes confidence and method. No file contents or environment variables are included.
