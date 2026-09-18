import CryptoKit
import Darwin
import DiskStewardCore
import Foundation

actor AppEvidenceQueryBackend: DiskStewardIPCRequestHandling {
    private let store: EvidenceStore
    private let exporter = EvidenceBundleExporter()
    private let registry: AgentSessionRegistry
    private let challengeDigest: String
    private let processInspector = LocalProcessInspector()
    private let inlineExportBase: URL
    private let retentionPolicyProvider: @Sendable () async throws -> EvidenceStoreRetentionPolicy
    private struct CursorLease {
        let query: String
        let raw: String
        let expiresAt: TimeInterval
    }
    private var cursorLeases: [String: CursorLease] = [:]

    init(databaseURL: URL, temporaryExportDirectory: URL? = nil, retentionPolicyProvider: @escaping @Sendable () async throws -> EvidenceStoreRetentionPolicy = { try .init() }) throws {
        self.retentionPolicyProvider = retentionPolicyProvider
        // Database fixtures own their scratch space too. Opening a backend must
        // never sweep the shared process-user temp directory or another instance.
        inlineExportBase = temporaryExportDirectory ?? databaseURL.deletingLastPathComponent()
            .appending(path: "temporary-exports", directoryHint: .isDirectory)
        let evidenceStore = try EvidenceStore(url: databaseURL)
        store = evidenceStore
        let seed = Data(UUID().uuidString.utf8)
        challengeDigest = SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined()
        registry = AgentSessionRegistry(
            expectedPeerUID: getuid(),
            expectedChallengeDigest: challengeDigest,
            evidenceStore: evidenceStore
        )
    }

    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        try Task.checkCancellation()
        let result = try await performIPC(method: method, payload: payload, peer: peer)
        try Task.checkCancellation()
        return result
    }

    private func performIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        switch method {
        case "tools/call":
            guard let object = payload.objectValue,
                  let name = object["name"]?.stringValue,
                  let arguments = object["arguments"]?.objectValue
            else { throw DiskStewardIPCError.remote(code: "invalid_request", message: "Missing tool name or arguments.", retryable: false) }
            return try await query(tool: name, arguments: arguments)
        case "resources/read":
            guard let uri = payload.objectValue?["uri"]?.stringValue else {
                throw DiskStewardIPCError.remote(code: "invalid_request", message: "Missing resource URI.", retryable: false)
            }
            return try await resource(uri: uri)
        case "sessions/register":
            return try await registerSession(payload: payload, peer: peer)
        case "sessions/end":
            return try await endSession(payload: payload, peer: peer)
        case "sessions/heartbeat":
            return try await heartbeatSession(payload: payload, peer: peer)
        default:
            throw DiskStewardIPCError.remote(code: "unknown_method", message: "Unsupported local IPC method: \(method)", retryable: false)
        }
    }

    private func query(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        var queryArguments = arguments
        queryArguments.removeValue(forKey: "cursor")
        let queryKey = tool + ":" + SHA256.hash(data: try JSONEncoder.diskSteward.encode(JSONValue.object(queryArguments))).map { String(format: "%02x", $0) }.joined()
        cursorLeases = cursorLeases.filter { $0.value.expiresAt > ProcessInfo.processInfo.systemUptime }
        if let token = arguments["cursor"]?.stringValue {
            guard let lease = cursorLeases[token], lease.query == queryKey else {
                throw DiskStewardIPCError.remote(code: "cursor_expired", message: "This page cursor expired or belongs to a different query. Start again without a cursor.", retryable: false)
            }
            queryArguments["cursor"] = .string(lease.raw)
        }
        let result = try await rawQuery(tool: tool, arguments: queryArguments)
        try Task.checkCancellation()
        return wrapCursors(result, query: queryKey)
    }

    private func wrapCursors(_ value: JSONValue, query: String) -> JSONValue {
        switch value {
        case .object(var object):
            for (key, child) in object {
                if key == "next_cursor", let raw = child.stringValue {
                    if cursorLeases.count >= 256, let oldest = cursorLeases.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key { cursorLeases.removeValue(forKey: oldest) }
                    let token = "ds-page-" + UUID().uuidString.lowercased()
                    cursorLeases[token] = .init(query: query, raw: raw, expiresAt: ProcessInfo.processInfo.systemUptime + 600)
                    object[key] = .string(token)
                } else { object[key] = wrapCursors(child, query: query) }
            }
            return .object(object)
        case .array(let children): return .array(children.map { wrapCursors($0, query: query) })
        default: return value
        }
    }

    private func rawQuery(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        switch tool {
        case "get_storage_summary":
            return try await storageSummary()
        case "get_evidence_lifecycle":
            return try await evidenceLifecycle()
        case "list_current_consumers":
            return try await currentConsumers(arguments: arguments)
        case "export_evidence":
            return try await inlineBundle(arguments: arguments)
        case "explain_growth":
            return try await explainGrowth(arguments: arguments)
        case "get_provenance":
            return try await provenance(arguments: arguments)
        case "find_cleanup_candidates":
            return try await cleanupCandidates(arguments: arguments)
        case "list_active_agent_sessions", "list_active_writers":
            return try await activeAgentSessions(arguments: arguments, compatibilityAlias: tool == "list_active_writers")
        case "get_task_impact":
            return try await taskImpact(arguments: arguments)
        default:
            throw DiskStewardIPCError.remote(code: "unknown_tool", message: "Unknown read-only tool: \(tool)", retryable: false)
        }
    }

    private func storageSummary() async throws -> JSONValue {
        let snapshot = try VolumeSnapshotService().capture()
        let lifecycle = try await store.lifecycleStatus(retentionPolicyProvider())
        let diagnostics = try await store.diagnostics()
        let latestObservation = try await store.latestObservationAt()
        let volumes = snapshot.volumes.map { volume in
            JSONValue.object([
                "mount_path": .string(volume.mountPath),
                "total_bytes": .integer(volume.totalBytes),
                "used_bytes": .integer(volume.usedBytes),
                "available_bytes": .integer(volume.availableBytes),
            ])
        }
        return .object([
            "schema": .string("storage-summary-v1"),
            "live_volume_observed_at": .string(snapshot.observedAt),
            "persisted_state_as_of": latestObservation.map { .string(timestamp($0)) } ?? .null,
            "volumes": .array(volumes),
            "current_consumer_count": .integer(Int64(lifecycle.currentStateCount)),
            "current_allocated_bytes": .integer(lifecycle.currentStateAllocatedBytes),
            "database_bytes": .integer(lifecycle.databaseBytes),
            "database_cap_bytes": .integer(lifecycle.databaseCapBytes),
            "database_file_bytes": .integer(diagnostics.databaseFileBytes),
            "wal_bytes": .integer(diagnostics.walBytes),
            "shared_memory_bytes": .integer(diagnostics.sharedMemoryBytes),
            "storage_admission": .string(lifecycle.databaseBytes < lifecycle.databaseCapBytes ? "available" : "retention-required"),
            "coverage": .string(coverage(observationGaps: lifecycle.observationGaps)),
            "freshness": .string("live-volume-plus-persisted-current-state"),
            "limitations": .array((snapshot.limitations + ["Detailed current state covers configured roots; whole-volume capacity does not imply whole-volume file attribution."]).map(JSONValue.string)),
        ])
    }

    private func evidenceLifecycle() async throws -> JSONValue {
        let policy = try await retentionPolicyProvider()
        let status = try await store.lifecycleStatus(policy)
        return .object([
            "schema": .string("evidence-lifecycle-v1"),
            "policy": try jsonValue(policy),
            "status": try lifecycleSummary(status),
            "coverage": .string(coverage(observationGaps: status.observationGaps)),
            "limitations": .array([.string("Actual retained intervals may be shorter than policy after startup, collection gaps, or forced capacity eviction.")]),
        ])
    }

    private func currentConsumers(arguments: [String: JSONValue]) async throws -> JSONValue {
        let detail = pathDetail(arguments)
        let limit = Int(arguments["limit"]?.integerValue ?? 100)
        let page = try await store.queryCurrentConsumers(
            rootPath: arguments["root_path"]?.stringValue,
            category: arguments["category"]?.stringValue,
            minimumAllocatedBytes: arguments["minimum_bytes"]?.integerValue ?? 0,
            cursor: arguments["cursor"]?.stringValue,
            limit: limit
        )
        let now = Date()
        let stateAsOf = try await store.latestObservationAt()
        let gaps = try await store.coverageGaps()
        return pageObject(
            query: "list_current_consumers",
            observedAt: now,
            stateAsOf: stateAsOf,
            requestedFrom: stateAsOf ?? now,
            requestedThrough: now,
            retainedFrom: stateAsOf,
            retainedThrough: stateAsOf,
            coverage: coverage(observationGaps: gaps),
            precision: "current",
            matchedCount: page.matchedCount,
            nextCursor: page.nextCursor,
            items: page.items.map { currentItem($0, detail: detail) },
            limitations: ["Only actionable present objects from the latest persisted complete evidence are returned."]
        )
    }

    private func lifecycleSummary(_ status: EvidenceLifecycleStatus) throws -> JSONValue {
        // Never serialize the internal traversal queue to answer a status query.
        var withoutQueue = status
        withoutQueue.scanCoverage = nil
        var summary = try jsonValue(withoutQueue).objectValue ?? [:]
        if let coverage = status.scanCoverage {
            func generation(_ value: MetadataScanGeneration?) -> JSONValue {
                guard let value else { return .null }
                return .object([
                    "generation_id": .string(value.generationID), "status": .string(value.status.rawValue),
                    "started_at": .string(timestamp(value.startedAt)), "updated_at": .string(timestamp(value.updatedAt)),
                    "completed_at": value.completedAt.map { .string(timestamp($0)) } ?? .null,
                    "processed_entry_count": .integer(Int64(value.processedEntryCount)),
                    "staged_file_count": .integer(Int64(value.stagedFileCount)),
                    "completed_root_count": .integer(Int64(value.completedRootCount)),
                    "pending_directory_count": .integer(Int64(value.roots.reduce(0) { $0 + $1.frontier.count })),
                    "frontier_omitted": .bool(true),
                    "limitations": .array(value.limitations.prefix(32).map(JSONValue.string)),
                ])
            }
            summary["scan_coverage"] = .object([
                "configured_roots": .array(coverage.configuredRoots.map(JSONValue.string)),
                "excluded_paths": .array(coverage.excludedPaths.map(JSONValue.string)),
                "detail_coverage": .string(coverage.detailCoverage),
                "active_generation": generation(coverage.activeGeneration),
                "latest_generation": coverage.latestGeneration?.generationID == coverage.activeGeneration?.generationID ? .null : generation(coverage.latestGeneration),
                "last_complete_generation_at": coverage.lastCompleteGenerationAt.map { .string(timestamp($0)) } ?? .null,
            ])
        }
        return .object(summary)
    }

    private func explainGrowth(arguments: [String: JSONValue]) async throws -> JSONValue {
        let (from, through) = try requestedRange(arguments)
        let detail = pathDetail(arguments)
        let model = try await store.queryGrowth(
            from: from,
            through: through,
            cursor: arguments["cursor"]?.stringValue,
            limit: Int(arguments["limit"]?.integerValue ?? 100)
        )
        let lifecycle = try await store.lifecycleStatus(retentionPolicyProvider())
        let actualDates = model.page.items.map(\.observedAt)
        let precisions = Set(model.page.items.map(\.precision))
        let precision = precisions.isEmpty ? "unknown" : (precisions.count == 1 ? precisions.first! : "mixed")
        var result = pageObject(
            query: "explain_growth",
            observedAt: Date(),
            stateAsOf: try await store.latestObservationAt(),
            requestedFrom: from,
            requestedThrough: through,
            retainedFrom: retainedOldest(lifecycle),
            retainedThrough: retainedNewest(lifecycle),
            coverage: coverage(observationGaps: lifecycle.observationGaps, from: from, through: through),
            precision: precision,
            matchedCount: model.aggregate.matchedCount,
            nextCursor: model.page.nextCursor,
            items: model.page.items.map { growthItem($0, detail: detail) },
            limitations: actualDates.isEmpty ? ["No retained evidence rows overlap the requested interval."] : []
        ).objectValue ?? [:]
        result["summary"] = .object([
            "growth_bytes": .integer(model.aggregate.growthBytes),
            "shrink_bytes": .integer(model.aggregate.shrinkBytes),
            "churn_bytes": .integer(model.aggregate.churnBytes),
            "net_allocated_delta": .integer(model.aggregate.netAllocatedDelta),
            "surviving_object_count": .integer(Int64(model.aggregate.survivingObjectCount)),
            "surviving_current_bytes": .integer(model.aggregate.survivingAllocatedBytes),
        ])
        return .object(result)
    }

    private func provenance(arguments: [String: JSONValue]) async throws -> JSONValue {
        let query = arguments["path_query"]?.stringValue ?? ""
        let detail = pathDetail(arguments)
        let chain = try await store.provenanceChain(
            pathQuery: query,
            cursor: arguments["cursor"]?.stringValue,
            limit: Int(arguments["limit"]?.integerValue ?? 100)
        )
        let claimsByEvent = Dictionary(grouping: chain.claims, by: { $0.event.eventID })
        var items = chain.currentStates.map { state in
            JSONValue.object([
                "kind": .string("current-state"),
                "object_id": .string(state.objectID),
                "path": .string(shape(path: state.path, detail: detail)),
                "presence": .string(state.presence.rawValue),
                "state_as_of": .string(timestamp(state.observedAt)),
                "logical_bytes": .integer(state.logicalBytes),
                "allocated_bytes": .integer(state.allocatedBytes),
            ])
        }
        items += chain.events.map { event in
            .object([
                "kind": .string("change"),
                "event_id": .string(event.eventID),
                "observed_at": .string(timestamp(event.observedAt)),
                "operation": .string(event.operation.rawValue),
                "path": .string(shape(path: event.path, detail: detail)),
                "logical_delta": .integer(event.logicalDelta),
                "allocated_delta": .integer(event.allocatedDelta),
                "confidence": .string(event.confidence.rawValue),
                "provenance_claims": .array((claimsByEvent[event.eventID] ?? []).map { claimItem($0, detail: detail) }),
            ])
        }
        let dates = chain.events.map(\.observedAt)
        var result = pageObject(
            query: "get_provenance",
            observedAt: Date(),
            stateAsOf: chain.currentStates.map(\.observedAt).max(),
            requestedFrom: dates.min() ?? Date(),
            requestedThrough: dates.max() ?? Date(),
            retainedFrom: dates.min(),
            retainedThrough: dates.max(),
            coverage: coverage(observationGaps: chain.observationGaps),
            precision: dates.isEmpty ? "unknown" : "raw",
            matchedCount: chain.matchedCount + chain.currentStates.count,
            nextCursor: chain.nextCursor,
            items: items,
            limitations: chain.objectIDs.count > 1 ? ["The basename matched multiple historical file identities; each object ID remains distinct."] : []
        ).objectValue ?? [:]
        result["object_ids"] = .array(chain.objectIDs.map(JSONValue.string))
        result["sessions"] = .array(chain.sessions.map(sessionItem))
        result["coverage_gaps"] = .array(chain.observationGaps.map(gapItem))
        return .object(result)
    }

    private func activeAgentSessions(arguments: [String: JSONValue], compatibilityAlias: Bool) async throws -> JSONValue {
        let now = Date()
        let cutoff = now.addingTimeInterval(-TimeInterval(arguments["minutes"]?.integerValue ?? 60) * 60)
        let all = try await registry.activeRegistrations(proof: proof(), now: now)
            .filter { $0.lastHeartbeatAt >= cutoff }
            .sorted { ($0.lastHeartbeatAt, $0.registrationID.uuidString) > ($1.lastHeartbeatAt, $1.registrationID.uuidString) }
        let limit = Int(arguments["limit"]?.integerValue ?? 100)
        let offset = decodeOffsetCursor(arguments["cursor"]?.stringValue)
        let page = Array(all.dropFirst(offset).prefix(limit))
        let next = offset + page.count < all.count ? encodeOffsetCursor(offset + page.count) : nil
        let sessionValues = page.map(sessionItem)
        return .object([
            "schema": .string(compatibilityAlias ? "active-writers-v1" : "active-agent-sessions-v1"),
            "observed_at": .string(timestamp(now)),
            "matched_count": .integer(Int64(all.count)),
            "returned_count": .integer(Int64(page.count)),
            "truncated": .bool(next != nil),
            "next_cursor": next.map(JSONValue.string) ?? .null,
            "sessions": .array(sessionValues),
            "writers": compatibilityAlias ? .array(sessionValues) : .null,
            "compatibility_alias": .bool(compatibilityAlias),
            "limitations": .array([.string("These are authenticated active task contexts, not observed file writers. Writer identity requires direct provenance evidence.")]),
        ])
    }

    private func cleanupCandidates(arguments: [String: JSONValue]) async throws -> JSONValue {
        let now = Date()
        let olderThanDays = Int(arguments["older_than_days"]?.integerValue ?? 0)
        let cutoff = olderThanDays > 0 ? now.addingTimeInterval(-TimeInterval(olderThanDays) * 86_400) : nil
        let detail = pathDetail(arguments)
        let page = try await store.queryCurrentConsumers(
            rootPath: arguments["root_path"]?.stringValue,
            category: arguments["category"]?.stringValue,
            minimumAllocatedBytes: max(1, arguments["minimum_bytes"]?.integerValue ?? 1),
            modifiedBefore: cutoff,
            cursor: arguments["cursor"]?.stringValue,
            limit: Int(arguments["limit"]?.integerValue ?? 100)
        )
        let candidates = page.items.compactMap { revalidatedCandidate($0, detail: detail, at: now) }
        return .object([
            "schema": .string("cleanup-candidates-v2"),
            "observed_at": .string(timestamp(now)),
            "state_as_of": (try await store.latestObservationAt()).map { .string(timestamp($0)) } ?? .null,
            "matched_count": .null,
            "prevalidation_matched_count": .integer(Int64(page.matchedCount)),
            "returned_count": .integer(Int64(candidates.count)),
            "truncated": .bool(page.truncated),
            "next_cursor": page.nextCursor.map(JSONValue.string) ?? .null,
            "items": .array(candidates),
            "safety": .string("review-required-never-safe-to-delete-claim"),
            "limitations": .array([
                .string("Only present actionable records whose live path, stable identity, size, and modification time still match are returned."),
                .string("Path-temporal identities, inaccessible paths, changed files, symlinks, and stale or reused paths are excluded."),
                .string("Candidates are evidence for human review, not deletion instructions."),
            ]),
        ])
    }

    private func resource(uri: String) async throws -> JSONValue {
        switch uri {
        case "disk-steward://status":
            let diagnostics = try await store.diagnostics()
            return .object([
                "schema": .string("service-status-v1"),
                "state": .string(diagnostics.integrity == "ok" ? "active" : "degraded"),
                "component": .string("evidence-store"),
                "detail": .string("SQLite schema \(diagnostics.schemaVersion), \(diagnostics.eventCount) retained raw events."),
                "limitations": .array([]),
            ])
        case "disk-steward://evidence-guide":
            return .object([
                "schema": .string("evidence-guide-v1"),
                "text": .string("Exact means a direct observer linked an operation to a process. Tool-linked means authenticated process ancestry linked a local task. Inferred is a supported hypothesis. Unknown means no actor claim is justified. Cleanup candidates always require human review."),
            ])
        default:
            throw DiskStewardIPCError.remote(code: "unknown_resource", message: "Unknown evidence resource.", retryable: false)
        }
    }

    private func registerSession(payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        guard let object = payload.objectValue,
              let sessionID = object["session_id"]?.stringValue,
              let clientName = object["client"]?.stringValue,
              let client = AgentClientKind(rawValue: clientName),
              case let .array(rootValues)? = object["workspace_roots"]
        else { throw DiskStewardIPCError.remote(code: "invalid_registration", message: "Session registration is incomplete.", retryable: false) }
        let roots = rootValues.compactMap(\.stringValue)
        guard roots.count == rootValues.count else {
            throw DiskStewardIPCError.remote(code: "invalid_registration", message: "Workspace roots must be strings.", retryable: false)
        }
        let requestedPID = Int32(object["process_pid"]?.integerValue ?? Int64(peer.pid))
        let ancestry = processInspector.snapshot(startingAt: peer.pid)
        guard let process = ancestry.records.keys.first(where: { $0.pid == requestedPID }) else {
            throw DiskStewardIPCError.remote(code: "invalid_registration", message: "The requested process is not the authenticated peer or one of its ancestors.", retryable: false)
        }
        let now = Date()
        let lease = min(max(TimeInterval(object["lease_seconds"]?.integerValue ?? 7_200), 60), 86_400)
        let registration = try await registry.register(
            SessionRegistrationRequest(
                client: client,
                sessionID: sessionID,
                process: process,
                workspaceRoots: roots,
                registeredAt: now,
                expiresAt: now.addingTimeInterval(lease),
                taskContext: object["task_context"]?.stringValue
            ),
            proof: proof(uid: peer.uid),
            now: now
        )
        return .object([
            "schema": .string("session-registration-result-v1"),
            "registration_id": .string(registration.registrationID.uuidString.lowercased()),
            "session_id": .string(registration.sessionID),
            "process_pid": .integer(Int64(registration.process.pid)),
            "confidence": .string("tool-linked"),
            "limitations": .array([.string("Registration links a local process tree to a task but does not prove individual file operations.")]),
        ])
    }

    private func heartbeatSession(payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        guard let value = payload.objectValue?["registration_id"]?.stringValue,
              let id = UUID(uuidString: value)
        else { throw DiskStewardIPCError.remote(code: "invalid_registration", message: "registration_id is invalid.", retryable: false) }
        let lease = min(max(TimeInterval(payload.objectValue?["lease_seconds"]?.integerValue ?? 7_200), 60), 86_400)
        let registration = try await registry.heartbeat(
            registrationID: id,
            extendBy: lease,
            proof: proof(uid: peer.uid),
            now: Date()
        )
        return .object([
            "schema": .string("session-heartbeat-result-v1"),
            "registration_id": .string(registration.registrationID.uuidString.lowercased()),
            "lifecycle": .string(registration.lifecycle.rawValue),
            "expires_at": .string(ISO8601DateFormatter().string(from: registration.expiresAt)),
        ])
    }

    private func endSession(payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        guard let value = payload.objectValue?["registration_id"]?.stringValue,
              let id = UUID(uuidString: value)
        else { throw DiskStewardIPCError.remote(code: "invalid_registration", message: "registration_id is invalid.", retryable: false) }
        let ended = try await registry.end(registrationID: id, proof: proof(uid: peer.uid), now: Date())
        return .object([
            "schema": .string("session-end-result-v1"),
            "registration_id": .string(ended.registrationID.uuidString.lowercased()),
            "lifecycle": .string(ended.lifecycle.rawValue),
        ])
    }

    private func taskImpact(arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let sessionID = arguments["session_id"]?.stringValue else {
            throw DiskStewardIPCError.remote(code: "invalid_request", message: "session_id is required.", retryable: false)
        }
        let registrations = try await registry.historicalRegistrations(sessionID: sessionID, proof: proof(), now: Date())
        guard !registrations.isEmpty else {
            throw DiskStewardIPCError.remote(code: "session_unavailable", message: "No retained session evidence matches that session ID.", retryable: false)
        }
        let from = arguments["from"]?.stringValue.flatMap(parseTimestamp)
            ?? registrations.map(\.registeredAt).min()!
        let through = arguments["through"]?.stringValue.flatMap(parseTimestamp)
            ?? max(Date(), registrations.compactMap { $0.endedAt ?? $0.expiresAt }.max()!)
        guard from < through else {
            throw DiskStewardIPCError.remote(code: "invalid_range", message: "A valid from/through range is required.", retryable: false)
        }
        let sourceEvents = try await store.events(from: from, through: through, limit: 100_000)
        let correlated = TaskImpactCorrelationEngine().correlate(
            sourceEvents.map { CorrelationObservation(event: $0, writer: nil) },
            registrations: registrations,
            ancestry: .init(records: [])
        )
        let impact = TaskImpactCorrelationEngine().impact(for: sessionID, correlated: correlated)
        let persistedAttributions = try await store.provenanceAttributions(
            registrationIDs: registrations.map(\.registrationID),
            from: from,
            through: through
        )
        let directlyAttributedIDs = Set(persistedAttributions.map(\.eventID))
        let correlatedIDs = Set(impact.eventIDs).union(directlyAttributedIDs)
        let correlatedEvents = sourceEvents.filter { correlatedIDs.contains($0.eventID) }
            .sorted { ($0.observedAt, $0.eventID) < ($1.observedAt, $1.eventID) }
        let eventIDs = correlatedEvents.map(\.eventID)
        let surviving = try await store.survivingImpact(eventIDs: eventIDs)
        let limit = min(max(Int(arguments["limit"]?.integerValue ?? 500), 1), 500)
        let returnedIDs = Array(eventIDs.prefix(limit))
        let growth = correlatedEvents.reduce(Int64(0)) { $0 + max(0, $1.allocatedDelta) }
        let shrink = correlatedEvents.reduce(Int64(0)) { $0 + max(0, -$1.allocatedDelta) }
        let logicalDelta = correlatedEvents.reduce(Int64(0)) { $0 + $1.logicalDelta }
        let allocatedDelta = correlatedEvents.reduce(Int64(0)) { $0 + $1.allocatedDelta }
        var confidenceValues = persistedAttributions.map(\.confidence)
        if !impact.eventIDs.isEmpty { confidenceValues.append(impact.confidence) }
        let confidence = weakestConfidence(confidenceValues)
        let gaps = try await store.coverageGaps()
        return .object([
            "schema": .string("task-impact-v1"),
            "session_id": .string(sessionID),
            "requested_interval": interval(from: from, through: through),
            "event_ids": .array(returnedIDs.map(JSONValue.string)),
            "matched_count": .integer(Int64(eventIDs.count)),
            "returned_count": .integer(Int64(returnedIDs.count)),
            "truncated": .bool(returnedIDs.count < eventIDs.count || sourceEvents.count == 100_000),
            "logical_delta": .integer(logicalDelta),
            "allocated_delta": .integer(allocatedDelta),
            "historical_growth_bytes": .integer(growth),
            "historical_shrink_bytes": .integer(shrink),
            "historical_churn_bytes": .integer(growth + shrink),
            "surviving_object_count": .integer(Int64(surviving.objectCount)),
            "surviving_logical_bytes": .integer(surviving.logicalBytes),
            "surviving_allocated_bytes": .integer(surviving.allocatedBytes),
            "confidence": .string(confidence.rawValue),
            "session_lifecycle": .array(registrations.map { .string($0.lifecycle.rawValue) }),
            "sessions": .array(registrations.map(sessionItem)),
            "coverage": .string(coverage(observationGaps: gaps, from: from, through: through)),
            "coverage_gaps": .array(gaps.filter { $0.startedAt <= through && ($0.endedAt == nil || $0.endedAt! >= from) }.map(gapItem)),
            "method": .string(directlyAttributedIDs.isEmpty ? "retained-session-temporal-and-workspace-correlation" : "persisted-provenance-and-session-correlation"),
            "limitations": .array((impact.limitations + [
                "Ended or expired session evidence can support historical temporal/workspace inference but cannot establish a writer without direct process-file evidence.",
                sourceEvents.count == 100_000 ? "The internal retained-event scan reached its 100000-row safety ceiling." : "",
            ].filter { !$0.isEmpty }).map(JSONValue.string)),
        ])
    }

    private func inlineBundle(arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let fromText = arguments["from"]?.stringValue,
              let throughText = arguments["through"]?.stringValue,
              let from = parseTimestamp(fromText),
              let through = parseTimestamp(throughText),
              from < through
        else { throw DiskStewardIPCError.remote(code: "invalid_range", message: "A valid from/through range is required.", retryable: false) }
        let detail = EvidencePathDetail(rawValue: arguments["path_detail"]?.stringValue ?? "basename") ?? .basename
        let maximumEvents = Int(arguments["max_events"]?.integerValue ?? arguments["limit"]?.integerValue ?? 500)
        try Task.checkCancellation()
        // Actor reentrancy permits overlapping exports. Each call gets its own
        // private directory, including cleanup when export construction throws.
        let workspace = try InlineExportWorkspace(parent: inlineExportBase)
        defer { workspace.removeIfOwned() }
        let result: EvidenceBundleExportResult
        do { result = try await exporter.export(
            store: store,
            options: .init(from: from, through: through, pathDetail: detail, maximumEvents: min(max(maximumEvents, 1), 10_000), limits: .inline),
            to: workspace.directory,
            kind: .temporary
        ) } catch { throw exportFailure(error) }
        do {
            try Task.checkCancellation()
            // Bound the total decoded source, not each file independently. A
            // large response must fail before materializing multiple JSON trees.
            var remaining = EvidenceExportLimits.inline.maximumPayloadBytes
            func read(_ name: String) throws -> Data {
                let handle = try FileHandle(forReadingFrom: result.bundleURL.appending(path: name))
                defer { try? handle.close() }
                var bytes = Data()
                while true {
                    try Task.checkCancellation()
                    let chunk = try handle.read(upToCount: min(64 * 1_024, remaining + 1)) ?? Data()
                    guard chunk.count <= remaining else { throw DiskStewardIPCError.responseTooLarge }
                    if chunk.isEmpty { return bytes }
                    remaining -= chunk.count
                    bytes.append(chunk)
                }
            }
            func decode(_ name: String) throws -> JSONValue {
                try JSONDecoder().decode(JSONValue.self, from: read(name))
            }
            let manifest = try decode("manifest.json")
            let summary = try decode("summary.json")
            let rollups = try decode("rollups.json")
            let snapshots = try decode("snapshots.json")
            let currentState = try decode("current-state.json")
            let provenance = try decode("provenance.json")
            let sessions = try decode("sessions.json")
            let coverage = try decode("coverage.json")
            let lifecycle = try decode("lifecycle.json")
            guard let brief = String(data: try read("codex-brief.md"), encoding: .utf8) else { throw EvidenceBundleExportError.invalidEvidence }
            let compressed = try read("events.jsonl.zlib")
            let eventData = try ZlibCodec.decompress(compressed, maximumOutputBytes: remaining)
            guard let eventText = String(data: eventData, encoding: .utf8) else { throw EvidenceBundleExportError.invalidEvidence }
            let events = try eventText.split(separator: "\n").map { line in
                try Task.checkCancellation()
                return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            }
            let manifestObject = manifest.objectValue ?? [:]
            let limitations = manifestObject["limitations"] ?? .array([])
            let truncated = limitationsContainsTruncation(limitations)
            let response = JSONValue.object([
                "schema": .string("inline-evidence-bundle-v1"),
                "manifest": manifest,
                "summary": summary,
                "rollups": rollups,
                "snapshots": snapshots,
                "current_state": currentState,
                "provenance": provenance,
                "sessions": sessions,
                "coverage": coverage,
                "lifecycle": lifecycle,
                "events": .array(events),
                "brief": .string(brief),
                "truncated": .bool(truncated),
            ])
            // MCP emits both structuredContent and escaped text; reserve ample
            // space below its 4 MiB transport ceiling for that envelope.
            guard try JSONEncoder().encode(response).count <= 1_024 * 1_024 else { throw DiskStewardIPCError.responseTooLarge }
            try Task.checkCancellation()
            try await destroyTemporaryExport(result)
            return response
        } catch {
            try? await destroyTemporaryExport(result)
            throw exportFailure(error)
        }
    }

    private func exportFailure(_ error: Error) -> Error {
        if error as? EvidenceBundleExportError == .budgetExceeded { return DiskStewardIPCError.responseTooLarge }
        if error is DecodingError || error as? EvidenceBundleExportError == .invalidEvidence
            || error as? EvidenceBundleExportError == .compressionFailed {
            return DiskStewardIPCError.remote(code: "invalid_evidence", message: "Stored evidence could not be decoded; no partial result was returned.", retryable: false)
        }
        if error as? EvidenceBundleExportError == .destinationOwnershipChanged {
            return DiskStewardIPCError.remote(code: "export_cleanup_failed", message: "The temporary export destination changed; replacement data was preserved.", retryable: false)
        }
        return error
    }

    private func destroyTemporaryExport(_ result: EvidenceBundleExportResult) async throws {
        try result.destroyTemporaryPayload()
        // An owned cleanup is still awaited/counts toward the request lifetime,
        // but must not inherit the cancellation that caused the cleanup.
        try await Task { [store] in try await store.markTemporaryExportDestroyed(id: result.exportID) }.value
    }

    private func limitationsContainsTruncation(_ value: JSONValue) -> Bool {
        guard case let .array(values) = value else { return false }
        return values.contains { $0.stringValue?.lowercased().contains("truncat") == true }
    }

    private func pageObject(
        query: String,
        observedAt: Date,
        stateAsOf: Date?,
        requestedFrom: Date,
        requestedThrough: Date,
        retainedFrom: Date?,
        retainedThrough: Date?,
        coverage: String,
        precision: String,
        matchedCount: Int?,
        nextCursor: String?,
        items: [JSONValue],
        limitations: [String]
    ) -> JSONValue {
        let retained: JSONValue
        if let retainedFrom, let retainedThrough {
            retained = interval(from: retainedFrom, through: retainedThrough)
        } else {
            retained = .null
        }
        return .object([
            "schema": .string("evidence-query-page-v1"),
            "query": .string(query),
            "observed_at": .string(timestamp(observedAt)),
            "state_as_of": stateAsOf.map { .string(timestamp($0)) } ?? .null,
            "requested_interval": interval(from: requestedFrom, through: requestedThrough),
            "retained_interval": retained,
            "coverage": .string(coverage),
            "precision": .string(precision),
            "matched_count": matchedCount.map { .integer(Int64($0)) } ?? .null,
            "returned_count": .integer(Int64(items.count)),
            "truncated": .bool(nextCursor != nil),
            "next_cursor": nextCursor.map(JSONValue.string) ?? .null,
            "items": .array(items),
            "limitations": .array(limitations.map(JSONValue.string)),
        ])
    }

    private func interval(from: Date, through: Date) -> JSONValue {
        .object(["from": .string(timestamp(from)), "through": .string(timestamp(through))])
    }

    private func currentItem(_ record: CurrentConsumerRecord, detail: EvidencePathDetail) -> JSONValue {
        let state = record.state
        return .object([
            "object_id": .string(state.objectID),
            "identity_method": .string(state.identityMethod.rawValue),
            "path": .string(shape(path: state.path, detail: detail)),
            "root_path": .string(shape(path: state.rootPath, detail: detail)),
            "consumer_category": .string(record.consumerCategory),
            "logical_bytes": .integer(state.logicalBytes),
            "allocated_bytes": .integer(state.allocatedBytes),
            "modified_at": state.modifiedAt.map { .string(timestamp($0)) } ?? .null,
            "presence": .string(state.presence.rawValue),
            "state_as_of": .string(timestamp(state.observedAt)),
            "state_as_of_observation_id": .string(state.stateAsOfObservationID),
        ])
    }

    private func growthItem(_ item: EvidenceGrowthItem, detail: EvidencePathDetail) -> JSONValue {
        .object([
            "row_id": .string(item.rowID),
            "observed_at": .string(timestamp(item.observedAt)),
            "precision": .string(item.precision),
            "operation": .string(item.operation.rawValue),
            "path": .string(shape(path: item.path, detail: detail)),
            "event_count": .integer(Int64(item.eventCount)),
            "logical_delta": .integer(item.logicalDelta),
            "allocated_delta": .integer(item.allocatedDelta),
            "consumer_category": .string(item.consumerCategory),
            "confidence": .string(item.confidence.rawValue),
        ])
    }

    private func claimItem(_ claim: ProvenanceClaim, detail: EvidencePathDetail) -> JSONValue {
        .object([
            "claim_id": .string(claim.claimID),
            "event_id": .string(claim.event.eventID),
            "path": .string(shape(path: claim.event.path, detail: detail)),
            "confidence": .string(claim.confidence.rawValue),
            "method": .string(claim.method),
            "detected_at": .string(timestamp(claim.detectedAt)),
            "occurred_interval": interval(from: claim.occurredStart, through: claim.occurredEnd),
            "actor": claim.actor.map { actor in
                .object([
                    "pid": .integer(Int64(actor.process.pid)),
                    "start_time": .string(timestamp(actor.process.startTime)),
                    "executable": actor.process.executablePath.map { .string(shape(path: $0, detail: detail)) } ?? .null,
                    "relationship": .string(actor.relationship),
                ])
            } ?? .null,
            "session": claim.session.map { session in
                .object([
                    "registration_id": .string(session.registrationID.uuidString.lowercased()),
                    "session_id": .string(session.sessionID),
                    "client": .string(session.client.rawValue),
                    "relationship": .string(session.relationship),
                ])
            } ?? .null,
            "support": .array(claim.support.map { source in
                .object(["kind": .string(source.kind.rawValue), "identifier": .string(source.identifier), "supports": .string(source.supports)])
            }),
            "limitations": .array(claim.limitations.map(JSONValue.string)),
            "contradictions": .array(claim.contradictions.map(JSONValue.string)),
            "supersedes_claim_id": claim.supersedesClaimID.map(JSONValue.string) ?? .null,
            "superseded_by_claim_id": claim.supersededByClaimID.map(JSONValue.string) ?? .null,
        ])
    }

    private func sessionItem(_ registration: AgentSessionRegistration) -> JSONValue {
        .object([
            "registration_id": .string(registration.registrationID.uuidString.lowercased()),
            "session_id": .string(registration.sessionID),
            "client": .string(registration.client.rawValue),
            "lifecycle": .string(registration.lifecycle.rawValue),
            "pid": .integer(Int64(registration.process.pid)),
            "process_start_time": .string(timestamp(registration.process.startTime)),
            "executable": registration.process.executablePath.map { .string(shape(path: $0, detail: .basename)) } ?? .null,
            "workspace_roots": .array(registration.workspaceRoots.map { .string(shape(path: $0, detail: .basename)) }),
            "registered_at": .string(timestamp(registration.registeredAt)),
            "last_heartbeat_at": .string(timestamp(registration.lastHeartbeatAt)),
            "expires_at": .string(timestamp(registration.expiresAt)),
            "ended_at": registration.endedAt.map { .string(timestamp($0)) } ?? .null,
            "task_context": registration.taskContext.map(JSONValue.string) ?? .null,
            "confidence": .string("tool-linked"),
            "method": .string("authenticated-session-context"),
            "writer_identity_observed": .bool(false),
        ])
    }

    private func gapItem(_ gap: EvidenceCoverageGap) -> JSONValue {
        .object([
            "gap_id": .string(gap.gapID),
            "observation_id": .string(gap.observationID),
            "root_path": .string(shape(path: gap.rootPath, detail: .basename)),
            "reason": .string(gap.reason),
            "started_at": .string(timestamp(gap.startedAt)),
            "ended_at": gap.endedAt.map { .string(timestamp($0)) } ?? .null,
        ])
    }

    private func revalidatedCandidate(_ record: CurrentConsumerRecord, detail: EvidencePathDetail, at date: Date) -> JSONValue? {
        let state = record.state
        guard state.presence == .present, state.actionable, state.identityMethod != .pathTemporal else { return nil }
        var information = stat()
        guard lstat(state.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1
        else { return nil }
        let liveObjectID: String
        switch state.identityMethod {
        case .volumeFileGeneration:
            liveObjectID = "file:\(information.st_dev):\(information.st_ino):\(information.st_gen)"
        case .volumeFile:
            liveObjectID = "file:\(information.st_dev):\(information.st_ino)"
        case .pathTemporal:
            return nil
        }
        let liveModified = Date(timeIntervalSince1970: TimeInterval(information.st_mtimespec.tv_sec) + TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000)
        guard liveObjectID == state.objectID,
              Int64(information.st_size) == state.logicalBytes,
              state.modifiedAt.map({ abs($0.timeIntervalSince(liveModified)) < 0.001 }) ?? false
        else { return nil }
        return .object([
            "object_id": .string(state.objectID),
            "path": .string(shape(path: state.path, detail: detail)),
            "consumer_category": .string(record.consumerCategory),
            "logical_bytes": .integer(Int64(information.st_size)),
            "allocated_bytes": .integer(Int64(information.st_blocks) * 512),
            "modified_at": .string(timestamp(liveModified)),
            "state_as_of": .string(timestamp(state.observedAt)),
            "revalidated_at": .string(timestamp(date)),
            "identity_method": .string(state.identityMethod.rawValue),
            "review_required": .bool(true),
        ])
    }

    private func requestedRange(_ arguments: [String: JSONValue]) throws -> (Date, Date) {
        guard let fromText = arguments["from"]?.stringValue,
              let throughText = arguments["through"]?.stringValue,
              let from = parseTimestamp(fromText),
              let through = parseTimestamp(throughText),
              from < through
        else { throw DiskStewardIPCError.remote(code: "invalid_range", message: "A valid from/through range is required.", retryable: false) }
        return (from, through)
    }

    private func pathDetail(_ arguments: [String: JSONValue]) -> EvidencePathDetail {
        EvidencePathDetail(rawValue: arguments["path_detail"]?.stringValue ?? "basename") ?? .basename
    }

    private func shape(path: String, detail: EvidencePathDetail) -> String {
        let shaped: String
        switch detail {
        case .full: shaped = path
        case .basename: shaped = URL(fileURLWithPath: path).lastPathComponent
        case .hashed: return "sha256:" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let pattern = #"(?i)(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|AKIA[A-Z0-9]{16}|(?:token|password|secret|api[_-]?key)=[^/\s]+)"#
        return shaped.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
    }

    private func coverage(observationGaps: [EvidenceCoverageGap], from: Date? = nil, through: Date? = nil) -> String {
        let relevant = observationGaps.filter { gap in
            guard let from, let through else { return gap.endedAt == nil }
            return gap.startedAt <= through && (gap.endedAt == nil || gap.endedAt! >= from)
        }
        return relevant.isEmpty ? "complete" : "partial"
    }

    private func weakestConfidence(_ values: [EvidenceStoreEvent.Confidence]) -> EvidenceStoreEvent.Confidence {
        let order: [EvidenceStoreEvent.Confidence] = [.exact, .toolLinked, .inferred, .unknown]
        return values.max {
            (order.firstIndex(of: $0) ?? 3) < (order.firstIndex(of: $1) ?? 3)
        } ?? .unknown
    }

    private func retainedOldest(_ status: EvidenceLifecycleStatus) -> Date? {
        status.tiers.compactMap(\.actualOldest).min()
    }

    private func retainedNewest(_ status: EvidenceLifecycleStatus) -> Date? {
        status.tiers.compactMap(\.actualNewest).max()
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }

    private func encodeOffsetCursor(_ offset: Int) -> String {
        Data("offset:\(offset)".utf8).base64EncodedString()
    }

    private func decodeOffsetCursor(_ cursor: String?) -> Int {
        guard let cursor,
              let data = Data(base64Encoded: cursor),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("offset:"),
              let value = Int(text.dropFirst(7)), value >= 0
        else { return 0 }
        return value
    }

    private func timestamp(_ date: Date) -> String {
        EvidenceTimestamp.format(date)
    }

    private func proof(uid: uid_t = getuid()) -> SessionAuthenticationProof {
        SessionAuthenticationProof(peerUID: uid, socketMode: 0o600, challengeDigest: challengeDigest)
    }

    private func parseTimestamp(_ value: String) -> Date? {
        EvidenceTimestamp.parse(value)
    }

}

/// A request may remove only the directory it created, never sibling exports.
/// Interrupted-request recovery needs a separate owned lease/manifest protocol;
/// age alone is not proof that another instance's directory is abandoned.
final class InlineExportWorkspace {
    let directory: URL
    private let device: dev_t
    private let inode: ino_t

    init(parent: URL) throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var parentMetadata = stat()
        guard lstat(parent.path, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR,
              parentMetadata.st_uid == getuid(), parentMetadata.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var template = Array(parent.appending(path: "request-XXXXXX").path.utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let address = buffer.baseAddress, let result = mkdtemp(address) else { return nil }
            return String(cString: result)
        }
        guard let created else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard lstat(created, &metadata) == 0 else {
            _ = rmdir(created) // Empty directory created by this call, not recursive cleanup.
            throw CocoaError(.fileReadUnknown)
        }
        directory = URL(fileURLWithPath: created, isDirectory: true)
        device = metadata.st_dev
        inode = metadata.st_ino
    }

    func removeIfOwned() {
        var current = stat()
        guard lstat(directory.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFDIR, current.st_uid == getuid(),
              current.st_dev == device, current.st_ino == inode else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
