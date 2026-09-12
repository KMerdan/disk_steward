# Endpoint Security Feasibility and Fallback Decision

Status: feasible as an optional privileged extension; not a prerequisite for the standard product path.

## Decision

Disk Steward will ship useful snapshot/FSEvents-based monitoring without Endpoint Security. A separately packaged, notification-only Endpoint Security system extension may add exact process-to-file provenance when—and only when—the development team has Apple’s restricted entitlement, valid signing/provisioning, the extension activates successfully, and the user grants the required approvals.

The standard app must never report `exact` attribution from timestamps, FSEvents, or snapshot differences. Those paths produce `inferred`, `tool-linked`, or `unknown` evidence with limitations. Failure or absence of the extension degrades fidelity, not availability.

## Official capability evidence

- Apple describes Endpoint Security as a C API whose clients subscribe to authorization or notification events, packaged as a system extension inside an app: [Endpoint Security overview](https://developer.apple.com/documentation/endpointsecurity).
- The API exposes file-system events including create, rename, truncate, write, and related file operations: [Endpoint Security event types](https://developer.apple.com/documentation/endpointsecurity/event-types).
- `es_new_client` requires `com.apple.developer.endpoint-security.client` and user TCC approval through Full Disk Access; failure results distinguish not-entitled, not-privileged, not-permitted, too-many-clients, invalid argument, and internal errors: [es_new_client](https://developer.apple.com/documentation/endpointsecurity/es_new_client%28_%3A_%3A%29).
- Apple states the Endpoint Security entitlement must be requested; without it, client creation returns `ES_NEW_CLIENT_RESULT_ERR_NOT_ENTITLED`: [Endpoint Security client entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.endpoint-security.client).
- System extensions ship in `Contents/Library/SystemExtensions`; activation verifies location, signatures, granted entitlements, and identifiers: [Installing System Extensions and Drivers](https://developer.apple.com/documentation/systemextensions/installing-system-extensions-and-drivers).
- Activation can remain pending for explicit user approval and may require restart when replacing an active extension: [activationRequest](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequest/activationrequest%28forextensionwithidentifier%3Aqueue%3A%29) and [requestNeedsUserApproval](https://developer.apple.com/documentation/systemextensions/ossystemextensionrequestdelegate/requestneedsuserapproval%28_%3A%29).
- Apple’s sample installation sequence requires Developer ID/provisioning, the requested entitlement, a signed app and extension, placement in `/Applications`, extension approval, Full Disk Access, and verification with `systemextensionsctl list`: [Monitoring System Events with Endpoint Security](https://developer.apple.com/documentation/endpointsecurity/monitoring-system-events-with-endpoint-security).

## Local observations (2026-09-12)

- Xcode SDK: `/Applications/Xcode.app/.../MacOSX26.2.sdk`.
- Headers: `usr/include/EndpointSecurity/EndpointSecurity.h` is present.
- Link interfaces: `usr/lib/libEndpointSecurity.tbd` and `libEndpointSecuritySystem.tbd` are present.
- `security find-identity -v -p codesigning`: `0 valid identities found`.
- `systemextensionsctl list`: failed with `OSSystemExtensionErrorDomain error 1` in the current environment, so installed/active extension state is unobserved—not empty.
- No entitlement grant or provisioning profile was supplied or observed.

Therefore compilation of an adapter boundary is locally testable, while signed activation, live event receipt, and release distribution are currently untestable and must remain blocked.

## Implementation boundary

The optional extension will:

1. subscribe to the minimum required `NOTIFY` events only;
2. filter watched roots before IPC;
3. copy only normalized metadata needed after the callback returns;
4. coalesce repeated writes and report dropped events/deadline pressure;
5. send versioned metadata to the app-owned service;
6. never authorize, deny, block, delete, or modify a filesystem operation.

The containing app owns activation UI, status, persistence, retention, export, and recovery. The standard collector owns snapshot/FSEvents evidence and remains active when the extension is absent.

## Entitlement and distribution checklist

- [ ] Enroll the distributing team and create valid Development/Developer ID identities.
- [ ] Request and receive `com.apple.developer.endpoint-security.client` from Apple for the intended product.
- [ ] Create matching app and system-extension identifiers and provisioning profiles.
- [ ] Embed the extension at `Contents/Library/SystemExtensions` and sign app plus extension consistently.
- [ ] Install the containing app in `/Applications` and submit `OSSystemExtensionRequest.activationRequest`.
- [ ] Handle pending user approval, denial, replacement, restart-required, and activation failure states.
- [ ] Guide the user to Full Disk Access; distinguish not-permitted from not-entitled.
- [ ] Verify activation with `systemextensionsctl list` and runtime service state on an unlocked test Mac.
- [ ] Notarize and test the exact distribution artifact and upgrade/deactivation path.
- [ ] Keep extension status and evidence gaps visible in exports and service responses.

Unchecked items are release blockers for exact provenance, not blockers for the standard app.

## Testability and fallback matrix

| Condition | Locally testable now | Required behavior | Maximum confidence |
|---|---|---|---|
| No extension or entitlement | Yes | Snapshot and watched-root collectors continue; report extension unavailable | inferred/tool-linked/unknown |
| Adapter protocol and event normalization | Yes, with synthetic messages | Version rejection, root filtering, coalescing, and gap reporting pass unit tests | no live exact claim |
| Entitled but Full Disk Access denied | Not on this host | Surface `not-permitted`; standard monitoring continues | inferred/tool-linked/unknown |
| Activation awaiting user approval | Not on this host | Surface pending state without retry storm | inferred/tool-linked/unknown |
| Live entitled extension receives NOTIFY event | Requires signed/approved test host | Preserve supporting event reference and process identity | exact when semantics support it |
| Dropped/overloaded event window | Synthetic now; live later | Mark gap/degraded status and never infer exact attribution across it | inferred/unknown |
| Extension crash/restart | Synthetic service test now; live later | App stays alive, records gap, reconnects with backoff | inferred/unknown during gap |
| Signed distribution/upgrade | No valid local identity | Verify notarized install, replacement, restart, and deactivation | release blocker |

## Fallback acceptance contract

The non-privileged path is acceptable only if it continues whole-volume snapshots, bounded watched-root detail, evidence retention, export, and MCP queries; labels every attribution with method/confidence; exposes extension absence and observation gaps; and never silently promotes fallback evidence to `exact`. Endpoint Security availability may improve provenance precision but cannot change the product’s safety or read-only guarantees.
