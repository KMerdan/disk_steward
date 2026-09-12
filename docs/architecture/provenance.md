# Privileged provenance contract

## Boundary

Endpoint Security is an optional notification-only metadata observer. It does not authorize, deny, delete, move, or modify filesystem operations. The standard snapshot/FSEvents recorder remains active before activation, while user approval is pending, after denial, during overload, and after extension failure.

The extension filters to normalized watched roots and exclusions before crossing the bridge. It copies only the closed `privileged-event-v1` metadata shape while the Endpoint Security message is valid, then releases the source message. File contents, environment variables, process arguments, and arbitrary payloads are not representable.

## Transport and ownership

The extension and containing app use a versioned, current-user local bridge authenticated by code-signing requirement and an application-group container. The app owns persistent SQLite evidence, retention, export, MCP queries, activation state, and recovery. The extension owns subscriptions, early path filtering, bounded coalescing, sequence numbers, and loss/overload reports. Unknown schema versions fail closed and trigger fallback status rather than best-effort decoding.

The stream is monotonically sequenced. A stream-ID change, sequence discontinuity, callback deadline miss, bounded-queue overflow, extension restart, or malformed message opens an evidence gap. Exact attribution is forbidden across that gap until a later complete event independently re-establishes process and file identity.

## Exact attribution eligibility

An event may be labeled `exact` only when one Endpoint Security notification supports all of the following:

1. operation is a subscribed create, rename, or close-backed write;
2. process identity is the pair `(pid, start_time)`, not PID alone;
3. file identity contains volume ID and file ID, and rename carries both paths;
4. the normalized path is inside one watched root and outside every exclusion;
5. before/after or close-time size measurement is complete;
6. no sequence gap or callback deadline failure precedes the event; and
7. method is `endpoint-security-file-process`.

Repeated writes for the same process identity and file identity may coalesce within a bounded window. The bridge preserves the count and net measured delta; it never coalesces across a rename, process start-time change, file-identity change, gap, or window boundary.

Incomplete file/process linkage, unknown measurement, PID reuse ambiguity, missed deadlines, and dropped events must downgrade to `inferred` or `unknown` with limitations. Tool registration can separately support `tool-linked` task context, but cannot upgrade incomplete filesystem provenance to exact.

## Status and deterministic fallback

`privileged-bridge-status-v1` makes absence and loss explicit. `not-entitled`, `not-permitted`, and pending approval require user action and do not retry aggressively. Transient unavailability, too many clients, and overload use bounded exponential backoff. Every status keeps `snapshot-fsevents` active and declares a maximum fallback confidence that is never exact.

| Privileged state | Fallback label | Maximum attribution |
|---|---|---|
| available with complete event | endpoint-security | exact for that event only |
| pending approval / not entitled / not permitted | snapshot-fsevents | inferred or unknown |
| unavailable / restart / too many clients | snapshot-fsevents-gap | unknown during the gap |
| dropped events / overload / deadline miss | snapshot-fsevents-gap | unknown across the gap |

The user and exported evidence see state, gap, dropped count, retry posture, and limitations. Absence of privileged evidence is never represented as zero activity.

## Resource controls

Subscriptions are limited to the minimum NOTIFY event set. Filtering precedes allocation-heavy enrichment. The queue has fixed event and byte ceilings; write coalescing has a bounded duration; IPC messages have a fixed maximum size; retry delay has a floor and ceiling. Overload drops metadata rather than blocking a filesystem callback, increments an explicit counter, and activates fallback sampling.
