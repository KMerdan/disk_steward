import CryptoKit
import Darwin
import DiskStewardCore
import Foundation

actor AppEvidenceQueryBackend: DiskStewardIPCRequestHandling {
    /// Where file-level answers come from. TASK-653 retires the per-file
    /// scanner: in `.retired` the evidence store is never opened (or created),
    /// file-level tools say so, and `export_evidence` reads a clone of the
    /// newest legacy set.
    enum FileDetailSource: Sendable {
        case live
        case retired(supportDirectory: URL)
    }

    static let retiredDetailMessage = "File-level scanning is retired: Disk Steward no longer scans files while idle. get_storage_summary answers capacity and its history, explain_growth answers the capacity change and changed folders, and export_evidence exports the legacy evidence."
    private static var retiredDetailError: DiskStewardIPCError {
        .remote(code: "detail_unavailable", message: retiredDetailMessage, retryable: false)
    }

    static let legacyExportTooLargeMessage = "The legacy evidence is too large for an inline export. Export it to a file from Disk Steward: Settings, Legacy evidence, Export Legacy Evidence."

    private let fileDetail: FileDetailSource
    private var isRetired: Bool {
        if case .retired = fileDetail { return true }
        return false
    }
    private var legacyExport: (name: String, store: EvidenceStore, directory: URL)?
    private let databaseURL: URL
    private let capacityRingURL: URL
    private let changeJournalURL: URL
    private var openedJournal: ChangeJournal?
    /// TASK-661: measured attribution; nil where the app does not run it.
    private let growthAttribution: GrowthAttributionService?
    /// TASK-672: sessions kept in the steward file, the object index, and the
    /// watched roots whose own rows are the journal's overflow collapse.
    private let sessionStore: SessionStore?
    private let reviewIndex: ReviewIndex?
    private let watchedRoots: @Sendable () async -> [String]
    private let reserveProvider: @Sendable (Int64) async -> Int64?
    private var openedRing: CapacityRing?
    private var openedStore: EvidenceStore?
    /// The evidence store opens lazily and is retried on every use, so a
    /// missing, locked or corrupt store never takes the socket or live
    /// capacity down with it.
    private var store: EvidenceStore {
        get throws {
            if let openedStore { return openedStore }
            if case .retired = fileDetail { throw Self.retiredDetailError }
            do {
                let opened = try EvidenceStore(url: databaseURL)
                openedStore = opened
                return opened
            } catch {
                throw DiskStewardIPCError.remote(
                    code: "detail_unavailable",
                    message: "File-detail evidence is unavailable: the evidence store could not be opened (\(error.localizedDescription)). Live capacity is still answered by get_storage_summary.",
                    retryable: true)
            }
        }
    }
    private let exporter = EvidenceBundleExporter()
    private let registry: AgentSessionRegistry
    private let challengeDigest: String
    private let processInspector = LocalProcessInspector()
    private let inlineExportBase: URL
    private let retentionPolicyProvider: @Sendable () async throws -> EvidenceStoreRetentionPolicy
    private let queryScopeProvider: @Sendable () async throws -> EvidenceQueryScope?
    /// Hard ceiling for one encoded response. Row limits are clamped before
    /// the store reads so a page cannot be materialized beyond it.
    private let responseByteCeiling: Int
    /// Retained-evidence overlap admission for task impact: rows and SQLite
    /// byte lengths are checked before any row is copied into Swift.
    private let taskImpactMaximumRows: Int
    private let taskImpactMaximumBytes: Int
    private struct RowBudget {
        let requested: Int
        let applied: Int
        var clamped: Bool { applied < requested }
    }
    private struct CursorLease {
        let query: String
        let raw: String
        let expiresAt: TimeInterval
    }
    private var cursorLeases: [String: CursorLease] = [:]

    init(
        databaseURL: URL,
        temporaryExportDirectory: URL? = nil,
        retentionPolicyProvider: @escaping @Sendable () async throws -> EvidenceStoreRetentionPolicy = { try .init() },
        queryScopeProvider: @escaping @Sendable () async throws -> EvidenceQueryScope? = { nil },
        responseByteCeiling: Int = 1_024 * 1_024,
        taskImpactMaximumRows: Int = 100_000,
        taskImpactMaximumBytes: Int = 8 * 1_024 * 1_024,
        capacityRingURL: URL? = nil,
        reserveProvider: @escaping @Sendable (Int64) async -> Int64? = { _ in nil },
        changeJournalURL: URL? = nil,
        fileDetail: FileDetailSource = .live,
        growthAttribution: GrowthAttributionService? = nil,
        sessionStore: SessionStore? = nil,
        reviewIndex: ReviewIndex? = nil,
        watchedRoots: @escaping @Sendable () async -> [String] = { [] }
    ) throws {
        self.fileDetail = fileDetail
        self.growthAttribution = growthAttribution
        self.sessionStore = sessionStore
        self.reviewIndex = reviewIndex
        self.watchedRoots = watchedRoots
        self.capacityRingURL = capacityRingURL ?? CapacityRing.defaultURL(beside: databaseURL)
        self.changeJournalURL = changeJournalURL ?? ChangeJournal.defaultURL(beside: databaseURL)
        self.reserveProvider = reserveProvider
        self.retentionPolicyProvider = retentionPolicyProvider
        self.queryScopeProvider = queryScopeProvider
        self.responseByteCeiling = min(max(responseByteCeiling, 4 * 1_024), 4 * 1_024 * 1_024)
        self.taskImpactMaximumRows = min(max(taskImpactMaximumRows, 1), 100_000)
        self.taskImpactMaximumBytes = min(max(taskImpactMaximumBytes, 4 * 1_024), 8 * 1_024 * 1_024)
        // Database fixtures own their scratch space too. Opening a backend must
        // never sweep the shared process-user temp directory or another instance.
        inlineExportBase = temporaryExportDirectory ?? databaseURL.deletingLastPathComponent()
            .appending(path: "temporary-exports", directoryHint: .isDirectory)
        self.databaseURL = databaseURL
        // Retired: sessions are kept in memory, and nothing opens or creates
        // the old store path.
        let evidenceStore: EvidenceStore?
        if case .retired = fileDetail { evidenceStore = nil } else { evidenceStore = try? EvidenceStore(url: databaseURL) }
        openedStore = evidenceStore
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
        let result: JSONValue
        do { result = try await performIPC(method: method, payload: payload, peer: peer) }
        catch EvidenceStoreError.cursorExpired {
            throw DiskStewardIPCError.remote(code: "cursor_expired", message: "Evidence changed since the previous page. Start again without a cursor.", retryable: false)
        }
        catch EvidenceLifecycleSummaryError.budgetExceeded {
            throw DiskStewardIPCError.remote(code: "query_budget_exceeded", message: "Lifecycle metadata exceeds the summary budget; no partial coverage result was returned.", retryable: false)
        }
        // Session registry outcomes are client-actionable; never let them
        // degrade into a generic retryable failure at the socket boundary.
        catch SessionRegistryError.duplicateSession, SessionRegistryError.processAlreadyRegistered {
            throw DiskStewardIPCError.remote(code: "session_conflict", message: "That session or process is already registered to another active session.", retryable: false)
        }
        catch SessionRegistryError.notFound, SessionRegistryError.staleRegistration {
            throw DiskStewardIPCError.remote(code: "invalid_registration", message: "The registration is unknown or no longer active.", retryable: false)
        }
        catch let SessionRegistryError.invalidRequest(reason) {
            throw DiskStewardIPCError.remote(code: "invalid_registration", message: "Session registration was rejected: \(reason).", retryable: false)
        }
        catch SessionRegistryError.unauthenticated {
            throw DiskStewardIPCError.remote(code: "permission_denied", message: "The session proof did not match the private socket.", retryable: false)
        }
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
        let wrapped = wrapCursors(result, query: queryKey)
        let encodedBytes = try JSONEncoder.diskSteward.encode(wrapped).count
        guard encodedBytes <= responseByteCeiling else {
            throw DiskStewardIPCError.remote(
                code: "response_too_large",
                message: "The \(tool) response would be \(encodedBytes) bytes, above the \(responseByteCeiling)-byte ceiling. Request a smaller limit; no partial page was returned.",
                retryable: false)
        }
        return wrapped
    }

    private func rowBudget(_ arguments: [String: JSONValue], defaultLimit: Int = 100, worstCaseItemBytes: Int) -> RowBudget {
        let requested = Int(arguments["limit"]?.integerValue ?? Int64(defaultLimit))
        let envelopeBytes = 8 * 1_024
        let affordable = max(1, (responseByteCeiling - envelopeBytes) / max(1, worstCaseItemBytes))
        return .init(requested: max(requested, 1), applied: min(max(requested, 1), affordable, 500))
    }

    private func scopeObject(_ scope: EvidenceQueryScope?, hiddenCount: Int?) -> JSONValue {
        guard let scope else {
            return .object(["applied": .bool(false), "reason": .string("No current monitoring policy was supplied; retained evidence is shown as scanned.")])
        }
        return .object([
            "applied": .bool(true),
            "scope_version_id": .string(scope.scopeVersionID),
            "active_root_count": .integer(Int64(scope.rootPaths.count)),
            "excluded_path_count": .integer(Int64(scope.excludedPaths.count)),
            "hidden_by_scope_count": hiddenCount.map { .integer(Int64($0)) } ?? .null,
        ])
    }

    private func budgetObject(_ budget: RowBudget?) -> JSONValue {
        guard let budget else { return .null }
        return .object([
            "row_limit_requested": .integer(Int64(budget.requested)),
            "row_limit_applied": .integer(Int64(budget.applied)),
            "response_byte_ceiling": .integer(Int64(responseByteCeiling)),
        ])
    }

    private func policyLimitations(scope: EvidenceQueryScope?, hiddenCount: Int?, budget: RowBudget?, coverage: String) -> [String] {
        var values: [String] = []
        if let hiddenCount, hiddenCount > 0 {
            values.append("\(hiddenCount) retained rows are hidden by the current watched roots and exclusions; they were not observed as deleted and remain until the next scan reconciles them.")
        }
        if let scope, scope.rootPaths.isEmpty {
            values.append("No watched root is active; file-level evidence is withheld until a root is configured.")
        }
        if let budget, budget.clamped {
            values.append("The requested limit of \(budget.requested) rows was reduced to \(budget.applied) to honor the \(responseByteCeiling)-byte response ceiling.")
        }
        if coverage == "none" {
            values.append("No completed observation exists; empty results are not evidence of absence.")
        }
        return values
    }

    /// Coverage that distinguishes missing evidence from complete evidence: a
    /// store with no completed observation cannot report complete coverage.
    private func evidenceCoverage(observationGaps: [EvidenceCoverageGap], stateAsOf: Date?, hasRows: Bool, from: Date? = nil, through: Date? = nil) -> String {
        let base = coverage(observationGaps: observationGaps, from: from, through: through)
        guard stateAsOf == nil, base == "complete" else { return base }
        return hasRows ? "partial" : "none"
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
            do { return try await inlineBundle(arguments: arguments) }
            catch DiskStewardIPCError.responseTooLarge where isRetired {
                // A legacy store can hold far more current state than an
                // inline answer; retrying cannot help, the file export can.
                throw DiskStewardIPCError.remote(code: "legacy_export_too_large", message: Self.legacyExportTooLargeMessage, retryable: false)
            }
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

    /// Live capacity never depends on the evidence store. Each detail part is
    /// read on its own; a failing part becomes null with `detail_status`
    /// unavailable and its reason, so freshness survives a refused summary.
    private func storageSummary() async throws -> JSONValue {
        let snapshot = try VolumeSnapshotService().capture()
        let volumes = snapshot.volumes.map { volume in
            JSONValue.object([
                "mount_path": .string(volume.mountPath),
                "total_bytes": .integer(volume.totalBytes),
                "used_bytes": .integer(volume.usedBytes),
                "available_bytes": .integer(volume.availableBytes),
            ])
        }
        // A locked store must not hold capacity hostage: detail shares one
        // short budget, and an expired read is cancelled.
        let deadline = Date().addingTimeInterval(Self.storageDetailBudget)
        let (latestObservation, observationFailure) = try await readDetail("persisted state", deadline: deadline) { try await $0.latestObservationAt() }
        let (publicLifecycle, lifecycleFailure) = try await readDetail("lifecycle summary", deadline: deadline) { try await $0.lifecycleSummary(self.retentionPolicyProvider()) }
        let (diagnostics, diagnosticsFailure) = try await readDetail("store diagnostics", deadline: deadline) { try await $0.diagnostics() }
        try Task.checkCancellation()
        let reasons = [observationFailure, lifecycleFailure, diagnosticsFailure].compactMap { $0 }
        let selected = selectedCapacityVolume(in: snapshot)
        var reserve: Int64?
        if let selected { reserve = await reserveProvider(selected.totalBytes) }
        let history = await capacityHistory(mountPath: selected?.mountPath)
        let lifecycle = publicLifecycle?.status
        var limitations = snapshot.limitations + ["Detailed current state covers configured roots; whole-volume capacity does not imply whole-volume file attribution."]
        if !reasons.isEmpty {
            limitations.append("File-detail evidence is partly unavailable (\(reasons.joined(separator: "; "))); the volume figures are live and do not depend on it.")
        }
        var fields: [String: JSONValue] = [:]
        fields["schema"] = .string(StorageSummaryContract.schema)
        fields[StorageSummaryContract.liveVolumeObservedAt] = .string(snapshot.observedAt)
        fields[StorageSummaryContract.persistedStateAsOf] = latestObservation.flatMap { $0 }.map { .string(timestamp($0)) } ?? .null
        fields["volumes"] = .array(volumes)
        fields["reserve_bytes"] = reserve.map(JSONValue.integer) ?? .null
        if let reserve, let selected {
            fields["free_above_reserve_bytes"] = .integer(selected.availableBytes - reserve)
        } else {
            fields["free_above_reserve_bytes"] = .null
        }
        fields["capacity_history"] = history
        fields["detail_status"] = .string(reasons.isEmpty ? "available" : "unavailable")
        fields["detail_reasons"] = .array(reasons.map(JSONValue.string))
        fields["current_consumer_count"] = lifecycle.map { .integer(Int64($0.currentStateCount)) } ?? .null
        fields["current_allocated_bytes"] = lifecycle.map { .integer($0.currentStateAllocatedBytes) } ?? .null
        fields["database_bytes"] = lifecycle.map { .integer($0.databaseBytes) } ?? .null
        fields["database_cap_bytes"] = lifecycle.map { .integer($0.databaseCapBytes) } ?? .null
        fields["database_file_bytes"] = diagnostics.map { .integer($0.databaseFileBytes) } ?? .null
        fields["wal_bytes"] = diagnostics.map { .integer($0.walBytes) } ?? .null
        fields["shared_memory_bytes"] = diagnostics.map { .integer($0.sharedMemoryBytes) } ?? .null
        fields["storage_admission"] = lifecycle.map { .string($0.databaseBytes < $0.databaseCapBytes ? "available" : "retention-required") } ?? .null
        fields["coverage"] = .string(publicLifecycle.map(lifecycleCoverage) ?? "unavailable")
        fields["freshness"] = .string("live-volume-plus-persisted-current-state")
        fields["limitations"] = .array(limitations.map(JSONValue.string))
        return .object(fields)
    }

    static let storageDetailBudget: TimeInterval = 3

    /// Opens the store in the calling task, off this actor, so a lock wait can
    /// be cancelled by that task's deadline without blocking other requests.
    private nonisolated func detailStore() async throws -> EvidenceStore {
        if let cached = await openedStoreIfAny() { return cached }
        if case .retired = fileDetail { throw Self.retiredDetailError }
        do {
            return await adopt(try EvidenceStore(url: databaseURL))
        } catch {
            throw DiskStewardIPCError.remote(code: "detail_unavailable", message: "The evidence store could not be opened.", retryable: true)
        }
    }

    private func openedStoreIfAny() -> EvidenceStore? { openedStore }

    private func adopt(_ store: EvidenceStore) async -> EvidenceStore {
        if let openedStore {
            await store.close()
            return openedStore
        }
        openedStore = store
        return store
    }

    private enum DetailOutcome<Value: Sendable>: Sendable {
        case value(Value)
        case failed(String)
        case timedOut
    }

    /// One detail part before `deadline`: its value, or a path-free reason.
    /// An expired read is cancelled, which also ends SQLite's busy waiting;
    /// the caller's own cancellation still propagates.
    private func readDetail<Value: Sendable>(
        _ part: String, deadline: Date, _ read: @escaping @Sendable (EvidenceStore) async throws -> Value
    ) async throws -> (Value?, String?) {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return (nil, "\(part): not read within the detail budget") }
        let outcome = try await withThrowingTaskGroup(of: DetailOutcome<Value>.self) { group in
            group.addTask {
                do { return .value(try await read(self.detailStore())) }
                catch { return .failed(Self.detailFailureReason(error)) }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return .timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? .timedOut
        }
        try Task.checkCancellation()
        switch outcome {
        case let .value(value): return (value, nil)
        case let .failed(reason): return (nil, "\(part): \(reason)")
        case .timedOut: return (nil, "\(part): not read within the detail budget")
        }
    }

    /// Capacity history from its own file, independent of the evidence store.
    /// The capacity ring if the app has created it; a read never creates it.
    private func existingRing() throws -> CapacityRing? {
        if let openedRing { return openedRing }
        guard FileManager.default.fileExists(atPath: capacityRingURL.path) else { return nil }
        let ring = try CapacityRing(url: capacityRingURL)
        openedRing = ring
        return ring
    }

    private func capacityHistory(mountPath: String?) async -> JSONValue {
        do {
            guard let ring = try existingRing(), let mountPath, let uuid = try await ring.volumeUUID(mountPath: mountPath) else {
                return .object(["status": .string("empty"), "sample_count": .integer(0)])
            }
            let summary = try await ring.summary(volumeUUID: uuid)
            return .object([
                "status": .string("available"),
                "sample_count": .integer(Int64(summary.sampleCount)),
                "oldest_sample_at": summary.oldest.map { .string(timestamp($0)) } ?? .null,
                "newest_sample_at": summary.newest.map { .string(timestamp($0.observedAt)) } ?? .null,
                "minimum_available_bytes_last_day": summary.minimumAvailableLastDay.map(JSONValue.integer) ?? .null,
            ])
        } catch {
            return .object(["status": .string("unavailable"), "reason": .string(Self.detailFailureReason(error))])
        }
    }

    /// A short, path-free reason for a detail failure.
    private static func detailFailureReason(_ error: Error) -> String {
        if case EvidenceLifecycleSummaryError.budgetExceeded? = error as? EvidenceLifecycleSummaryError {
            return "lifecycle metadata exceeds the summary budget"
        }
        if case let DiskStewardIPCError.remote(code, message, _)? = error as? DiskStewardIPCError {
            return message == retiredDetailMessage ? "file-level scanning is retired" : code
        }
        if case let EvidenceStoreError.sqlite(code, _)? = error as? EvidenceStoreError { return "SQLite error \(code)" }
        return error is EvidenceStoreError ? "evidence store error" : "unexpected error"
    }

    private func evidenceLifecycle() async throws -> JSONValue {
        let policy = try await retentionPolicyProvider()
        let scope = try await queryScopeProvider()
        let status = try await store.lifecycleSummary(policy)
        var limitations = ["Actual retained intervals may be shorter than policy after startup, collection gaps, or forced capacity eviction."]
        let listedRetentionGaps = status.status.retentionGaps.count
        if let totalRetentionGaps = status.status.retentionGapCount, totalRetentionGaps > listedRetentionGaps {
            limitations.append("retention_gaps lists the newest \(listedRetentionGaps) of \(totalRetentionGaps) retention coverage gaps; older gaps are counted in retention_gap_count, not listed.")
        }
        let listedObservationGaps = status.status.observationGaps.count
        if let totalObservationGaps = status.status.observationGapCount, totalObservationGaps > listedObservationGaps {
            limitations.append("observation_gaps lists the newest \(listedObservationGaps) of \(totalObservationGaps) observation coverage gaps; coverage is judged from every gap, including unlisted ones.")
        }
        let effectiveScope: JSONValue
        if let scope {
            let latest = try await store.latestObservationScope().map(EvidenceQueryScope.init)
            let matchesLatestScan = latest.map { $0.rootPaths == scope.rootPaths && $0.excludedPaths == scope.excludedPaths }
            if matchesLatestScan == false {
                limitations.append("The current watched roots or exclusions differ from the latest scan; queries apply the current policy immediately and the next scan reconciles retained detail.")
            }
            effectiveScope = .object([
                "scope_version_id": .string(scope.scopeVersionID),
                "roots": .array(scope.rootPaths.map { .string(shape(path: $0, detail: .basename)) }),
                "excluded": .array(scope.excludedPaths.map { .string(shape(path: $0, detail: .basename)) }),
                "matches_latest_scan": matchesLatestScan.map(JSONValue.bool) ?? .null,
            ])
        } else {
            effectiveScope = .null
        }
        return .object([
            "schema": .string("evidence-lifecycle-v1"),
            "policy": try jsonValue(policy),
            "status": try lifecycleSummary(status),
            "effective_scope": effectiveScope,
            "coverage": .string(lifecycleCoverage(status)),
            "limitations": .array(limitations.map(JSONValue.string)),
        ])
    }

    private func currentConsumers(arguments: [String: JSONValue]) async throws -> JSONValue {
        let detail = pathDetail(arguments)
        let scope = try await queryScopeProvider()
        // Current items carry both `path` and `root_path` at the requested
        // detail; two PATH_MAX strings plus the numeric fields bound one item.
        let budget = rowBudget(arguments, worstCaseItemBytes: 2_688)
        let page = try await store.queryCurrentConsumers(
            rootPath: arguments["root_path"]?.stringValue,
            category: arguments["category"]?.stringValue,
            minimumAllocatedBytes: arguments["minimum_bytes"]?.integerValue ?? 0,
            cursor: arguments["cursor"]?.stringValue,
            limit: budget.applied,
            scope: scope
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
            coverage: evidenceCoverage(observationGaps: gaps, stateAsOf: stateAsOf, hasRows: !page.items.isEmpty),
            precision: "current",
            matchedCount: page.matchedCount,
            nextCursor: page.nextCursor,
            items: page.items.map { currentItem($0, detail: detail) },
            limitations: ["Only actionable present objects from the latest persisted complete evidence are returned."],
            scope: scope,
            scopeHiddenCount: page.scopeHiddenCount,
            budget: budget
        )
    }

    private func lifecycleSummary(_ value: EvidenceLifecycleSummary) throws -> JSONValue {
        var summary = try jsonValue(value.status).objectValue ?? [:]
        // The no-argument lifecycle tool defaults to basename privacy. Explicit
        // DTOs prevent export paths/free-text diagnostics from bypassing it.
        summary["observation_gaps"] = .array(value.status.observationGaps.map(gapItem))
        summary["export_inventory"] = .array(try value.status.exportInventory.map { record in
            var fields = try jsonValue(record).objectValue ?? [:]
            fields["path"] = record.path.map { .string(shape(path: $0, detail: .basename)) } ?? .null
            fields["failure"] = record.failure == nil ? .null : .string("Export failed; free-text diagnostics are withheld from this summary.")
            fields["inventory_checked_at_request"] = .bool(false)
            return .object(fields)
        })
        if let coverage = value.scanCoverage {
            func generation(_ value: EvidenceScanGenerationSummary?) -> JSONValue {
                guard let value else { return .null }
                return .object([
                    "generation_id": .string(value.generationID), "status": .string(value.status),
                    "started_at": .string(timestamp(value.startedAt)), "updated_at": .string(timestamp(value.updatedAt)),
                    "completed_at": value.completedAt.map { .string(timestamp($0)) } ?? .null,
                    "processed_entry_count": .integer(Int64(value.processedEntryCount)),
                    "staged_file_count": .integer(Int64(value.stagedFileCount)),
                    "completed_root_count": value.completedRootCount.map(JSONValue.integer) ?? .null,
                    "pending_directory_count": value.pendingDirectoryCount.map(JSONValue.integer) ?? .null,
                    "frontier_omitted": .bool(true),
                    "limitations": .array(value.pendingDirectoryCount == nil ? [.string("Historical traversal counters were not projected; unknown values are not zero.")] : []),
                ])
            }
            summary["scan_coverage"] = .object([
                "schema": .string("scan-coverage-summary-v1"),
                "configured_roots": .array(coverage.latestGeneration.configuredRoots.map { .string(shape(path: $0, detail: .basename)) }),
                "excluded_paths": .array(coverage.latestGeneration.excludedPaths.map { .string(shape(path: $0, detail: .basename)) }),
                "detail_coverage": .string(coverage.detailCoverage),
                "active_generation": generation(coverage.activeGeneration),
                "latest_generation": coverage.latestGeneration.generationID == coverage.activeGeneration?.generationID ? .null : generation(coverage.latestGeneration),
                "last_complete_generation_at": coverage.lastCompleteGenerationAt.map { .string(timestamp($0)) } ?? .null,
            ])
        }
        return .object(summary)
    }

    private func lifecycleCoverage(_ summary: EvidenceLifecycleSummary) -> String {
        // The gap list is a newest-first window; the open count covers every row.
        if let open = summary.status.openObservationGapCount {
            if open > 0 { return "partial" }
        } else if coverage(observationGaps: summary.status.observationGaps) != "complete" {
            return "partial"
        }
        return summary.detailCoverage
    }

    private func growthCoverage(_ summary: EvidenceLifecycleSummary, from: Date, through: Date) -> String {
        // An active scan has an open-ended observation interval. Its scalar
        // projection preserves that uncertainty without decoding the traversal
        // frontier or making an earlier, disjoint historical window partial.
        if let active = summary.scanCoverage?.activeGeneration, active.startedAt <= through {
            return "partial"
        }
        if let overlap = summary.observationGapsOverlapWindow { return overlap ? "partial" : "complete" }
        return coverage(observationGaps: summary.status.observationGaps, from: from, through: through)
    }

    /// Growth for a window: the capacity change and the changed directories
    /// come from the ring and the change journal and are always answered;
    /// file-level detail is added when the evidence store can provide it.
    private func explainGrowth(arguments: [String: JSONValue]) async throws -> JSONValue {
        let (from, through) = try requestedRange(arguments)
        var result: [String: JSONValue]
        do {
            result = try await explainGrowthDetail(arguments: arguments, from: from, through: through)
            result["detail_status"] = .string("available")
        } catch is CancellationError {
            throw CancellationError()
        } catch EvidenceStoreError.cursorExpired {
            throw EvidenceStoreError.cursorExpired
        } catch let error as DiskStewardIPCError {
            // A request the client must change is still refused; only an
            // unreadable store degrades to the journal and ring answer.
            guard case let .remote(code, _, _) = error, code == "detail_unavailable" else { throw error }
            result = degradedGrowth(from: from, through: through, error: error)
        } catch {
            result = degradedGrowth(from: from, through: through, error: error)
        }
        let detail = pathDetail(arguments)
        result["capacity_change"] = await capacityChange(from: from, through: through)
        var journal = await journalAnswer(from: from, through: through, detail: detail)
        let (measured, attributions) = await measuredGrowth(from: from, through: through, detail: detail)
        result["measured_growth"] = measured
        if let attribution = attributions.first { journal["changed_directories"] = markMeasured(journal["changed_directories"], by: attribution, detail: detail) }
        for (key, value) in journal { result[key] = value }
        return .object(result)
    }

    /// TASK-661: the volume delta attributed to measured objects. A window
    /// reaching the present gets a fresh attribution (or one under two
    /// minutes old) within the request budget; any window gets the stored
    /// attributions it overlaps, newest first.
    private func measuredGrowth(from: Date, through: Date, detail: EvidencePathDetail) async -> (JSONValue, [GrowthAttribution]) {
        guard let growthAttribution else {
            return (.object(["status": .string("unavailable"), "limitations": .array([.string("Growth attribution does not run in this process; changed directories are unmeasured.")])]), [])
        }
        var notes: [String] = []
        if Date().timeIntervalSince(through) < GrowthAttributionService.presentSeconds {
            do { _ = try await growthAttribution.current() } catch GrowthAttributionError.busy {
                notes.append("An attribution was already measuring; stored attributions are shown.")
            } catch {
                notes.append("Measuring now failed (\(Self.detailFailureReason(error))); stored attributions are shown.")
            }
        }
        let overlapping = await growthAttribution.attributions(overlapping: from, through: through)
        guard !overlapping.isEmpty else {
            notes.append("No attribution covers this window. One runs when free space drops by the growth threshold, or when a growth question reaches the present.")
            return (.object(["status": .string("none"), "limitations": .array(notes.map(JSONValue.string))]), [])
        }
        let shown = Array(overlapping.prefix(Self.attributionsShown))
        if overlapping.count > shown.count { notes.append("\(overlapping.count - shown.count) older attributions overlap the window and are not shown.") }
        let known = shown.compactMap(\.volume)
        var answer: [String: JSONValue] = [
            "status": .string("measured"),
            "attributed_bytes": .integer(shown.map(\.attributedBytes).reduce(0, +)),
            "volume_delta_bytes": known.count == shown.count ? .integer(known.map(\.deltaBytes).reduce(0, +)) : .null,
            "unexplained_bytes": known.count == shown.count ? .integer(shown.compactMap(\.unexplainedBytes).reduce(0, +)) : .null,
            "remainder_covers": .string(GrowthAttribution.remainderCovers),
            "complete": .bool(shown.allSatisfy(\.isComplete)),
            "attributions": .array(shown.map { attributionValue($0, detail: detail) }),
        ]
        if shown.first?.from ?? from > from || (shown.last.map { $0.through < through } ?? false) || shown.contains(where: { $0.from < from || $0.through > through }) {
            notes.append("Attribution windows do not match the requested window exactly; each attribution states its own.")
        }
        answer["limitations"] = .array(notes.map(JSONValue.string))
        return (.object(answer), shown)
    }

    static let attributionsShown = 4
    static let attributedObjectsShown = 50

    private func attributionValue(_ attribution: GrowthAttribution, detail: EvidencePathDetail) -> JSONValue {
        func date(_ value: Date?) -> JSONValue { value.map { .string(timestamp($0)) } ?? .null }
        func bytes(_ value: Int64?) -> JSONValue { value.map(JSONValue.integer) ?? .null }
        let objects = attribution.objects.prefix(Self.attributedObjectsShown)
        return .object([
            "attribution_id": .string(attribution.attributionID),
            "trigger": .string(attribution.trigger.rawValue),
            "from": date(attribution.from),
            "through": date(attribution.through),
            "volume_delta_bytes": bytes(attribution.volume?.deltaBytes),
            "volume_first_sample_at": date(attribution.volume?.firstSampleAt),
            "volume_last_sample_at": date(attribution.volume?.lastSampleAt),
            "attributed_bytes": .integer(attribution.attributedBytes),
            "unexplained_bytes": bytes(attribution.unexplainedBytes),
            "complete": .bool(attribution.isComplete),
            "stop_reason": attribution.stopReason.map { .string($0.rawValue) } ?? .null,
            "objects": .array(objects.map { object in .object([
                "path": .string(shape(path: object.path, detail: detail)),
                "basis": .string(object.basis.rawValue),
                "changes": .integer(object.changes),
                "previous_bytes": bytes(object.previousBytes),
                "previous_measured_at": date(object.previousMeasuredAt),
                "current_bytes": bytes(object.currentBytes),
                "delta_bytes": bytes(object.deltaBytes),
                "unreadable_directories": .integer(Int64(object.unreadableDirectories)),
            ]) }),
            "objects_omitted": .integer(Int64(attribution.objectsOmitted + attribution.objects.count - objects.count)),
            "unmeasured_directories": .object([
                "count": .integer(Int64(attribution.unmeasuredDirectoryCount)),
                "items": .array(attribution.unmeasuredDirectories.map { .string(shape(path: $0, detail: detail)) }),
            ]),
            "journal_gaps": .array(attribution.gaps.map { gap in .object([
                "reason": .string(gap.reason), "path": .string(shape(path: gap.path, detail: detail)), "at": .string(timestamp(gap.at)),
            ]) }),
            "limitations": .array(attribution.limitations.map(JSONValue.string)),
        ])
    }

    /// A changed directory at or inside a measured object, or holding
    /// measured objects, says so; the rest stay unmeasured.
    private func markMeasured(_ value: JSONValue?, by attribution: GrowthAttribution, detail: EvidencePathDetail) -> JSONValue? {
        guard case var .object(changed)? = value, case let .array(items)? = changed["items"] else { return value }
        let measured = attribution.objects.filter { $0.deltaBytes != nil }
        let byShape = Dictionary(measured.map { (shape(path: $0.path, detail: detail), $0) }, uniquingKeysWith: { first, _ in first })
        changed["items"] = .array(items.map { item in
            guard case var .object(fields) = item, case let .string(path)? = fields["path"] else { return item }
            let related = byShape.filter { path == $0.key || path.hasPrefix($0.key + "/") || $0.key.hasPrefix(path + "/") }.map(\.value)
            guard !related.isEmpty else { return item }
            fields["measured"] = .bool(true)
            fields["measured_delta_bytes"] = .integer(related.compactMap(\.deltaBytes).reduce(0, +))
            fields["measured_objects"] = .integer(Int64(related.count))
            return .object(fields)
        })
        return .object(changed)
    }

    /// The same page shape with no file-level rows, saying why.
    private func degradedGrowth(from: Date, through: Date, error: Error) -> [String: JSONValue] {
        var page = pageObject(
            query: "explain_growth", observedAt: Date(), stateAsOf: nil, requestedFrom: from, requestedThrough: through,
            retainedFrom: nil, retainedThrough: nil, coverage: "unavailable", precision: "unknown", matchedCount: nil, nextCursor: nil,
            items: [], limitations: ["File-level detail is unavailable; the capacity change and changed directories do not depend on it."]
        ).objectValue ?? [:]
        page["detail_status"] = .string("unavailable")
        page["detail_reasons"] = .array([.string(Self.detailFailureReason(error))])
        return page
    }

    private func capacityChange(from: Date, through: Date) async -> JSONValue {
        do {
            guard let ring = try existingRing() else { return .object(["status": .string("no-samples")]) }
            let snapshot = try VolumeSnapshotService().capture()
            guard let selected = selectedCapacityVolume(in: snapshot), let uuid = try await ring.volumeUUID(mountPath: selected.mountPath),
                  let ends = try await ring.endpoints(volumeUUID: uuid, from: from, through: through) else {
                return .object(["status": .string("no-samples")])
            }
            let usedBefore = ends.first.totalBytes - ends.first.availableBytes
            let usedAfter = ends.last.totalBytes - ends.last.availableBytes
            return .object([
                "status": .string("available"),
                "first_sample_at": .string(timestamp(ends.first.observedAt)),
                "last_sample_at": .string(timestamp(ends.last.observedAt)),
                "used_delta_bytes": .integer(usedAfter - usedBefore),
            ])
        } catch {
            return .object(["status": .string("unavailable"), "reason": .string(Self.detailFailureReason(error))])
        }
    }

    /// The change journal if the app has created it; a read never creates it.
    private func existingJournal() throws -> ChangeJournal? {
        if let openedJournal { return openedJournal }
        guard FileManager.default.fileExists(atPath: changeJournalURL.path) else { return nil }
        let journal = try ChangeJournal(url: changeJournalURL)
        openedJournal = journal
        return journal
    }

    private func journalAnswer(from: Date, through: Date, detail: EvidencePathDetail) async -> [String: JSONValue] {
        do {
            guard let journal = try existingJournal() else {
                return ["changed_directories": .null, "journal_gaps": .array([]), "journal_coverage_start": .null,
                        "journal_limitations": .array([.string("The change journal has not started; which directories changed is unknown.")])]
            }
            let window = try await journal.changes(from: from, through: through, limit: 200)
            let start = try await journal.coverageStart()
            var limitations = ["Changed directories come from the file-system change journal. One is marked measured when an attribution measured objects at, inside or under it; measured_growth has the deltas."]
            if window.changes.truncated { limitations.append("changed_directories lists \(window.changes.items.count) of \(window.changes.total) directories, most changes first.") }
            if let start, start > from { limitations.append("The change journal starts at \(timestamp(start)); earlier changes are unknown, not absent.") }
            return [
                "changed_directories": .object([
                    "items": .array(window.changes.items.map { change in .object([
                        "path": .string(shape(path: change.path, detail: detail)),
                        "changes": .integer(change.changes),
                        "first_interval": .string(timestamp(change.firstInterval)),
                        "last_interval": .string(timestamp(change.lastInterval)),
                        "measured": .bool(false),
                    ]) }),
                    "total": .integer(Int64(window.changes.total)),
                    "truncated": .bool(window.changes.truncated),
                ]),
                "journal_gaps": .array(window.gaps.map { gap in .object([
                    "reason": .string(gap.reason), "path": .string(shape(path: gap.path, detail: detail)), "at": .string(timestamp(gap.at)),
                ]) }),
                "journal_coverage_start": start.map { .string(timestamp($0)) } ?? .null,
                "journal_limitations": .array(limitations.map(JSONValue.string)),
            ]
        } catch {
            return ["changed_directories": .null, "journal_gaps": .array([]), "journal_coverage_start": .null,
                    "journal_limitations": .array([.string("The change journal is unavailable (\(Self.detailFailureReason(error))).")])]
        }
    }

    private func explainGrowthDetail(arguments: [String: JSONValue], from: Date, through: Date) async throws -> [String: JSONValue] {
        let detail = pathDetail(arguments)
        let scope = try await queryScopeProvider()
        let budget = rowBudget(arguments, worstCaseItemBytes: 1_536)
        let model = try await store.queryGrowth(
            from: from,
            through: through,
            cursor: arguments["cursor"]?.stringValue,
            limit: budget.applied,
            scope: scope
        )
        let publicLifecycle = try await store.lifecycleSummary(retentionPolicyProvider(), gapWindow: (from, through))
        let lifecycle = publicLifecycle.status
        let actualDates = model.page.items.map(\.observedAt)
        let precisions = Set(model.page.items.map(\.precision))
        let precision = precisions.isEmpty ? "unknown" : (precisions.count == 1 ? precisions.first! : "mixed")
        let stateAsOf = try await store.latestObservationAt()
        // An active scan keeps "partial"; only a claim of complete coverage with
        // no completed observation and no rows is downgraded to "none".
        let baseCoverage = growthCoverage(publicLifecycle, from: from, through: through)
        let coverage = stateAsOf == nil && model.page.items.isEmpty && baseCoverage == "complete" ? "none" : baseCoverage
        var result = pageObject(
            query: "explain_growth",
            observedAt: Date(),
            stateAsOf: stateAsOf,
            requestedFrom: from,
            requestedThrough: through,
            retainedFrom: retainedOldest(lifecycle),
            retainedThrough: retainedNewest(lifecycle),
            coverage: coverage,
            precision: precision,
            matchedCount: model.aggregate.matchedCount,
            nextCursor: model.page.nextCursor,
            items: model.page.items.map { growthItem($0, detail: detail) },
            limitations: actualDates.isEmpty ? ["No retained evidence rows overlap the requested interval."] : [],
            scope: scope,
            scopeHiddenCount: nil,
            budget: budget
        ).objectValue ?? [:]
        result["summary"] = .object([
            "growth_bytes": .integer(model.aggregate.growthBytes),
            "shrink_bytes": .integer(model.aggregate.shrinkBytes),
            "churn_bytes": .integer(model.aggregate.churnBytes),
            "net_allocated_delta": .integer(model.aggregate.netAllocatedDelta),
            "surviving_object_count": .integer(Int64(model.aggregate.survivingObjectCount)),
            "surviving_current_bytes": .integer(model.aggregate.survivingAllocatedBytes),
        ])
        return result
    }

    private func provenance(arguments: [String: JSONValue]) async throws -> JSONValue {
        let query = arguments["path_query"]?.stringValue ?? ""
        let detail = pathDetail(arguments)
        let scope = try await queryScopeProvider()
        let budget = rowBudget(arguments, worstCaseItemBytes: 4_096)
        let chain = try await store.provenanceChain(
            pathQuery: query,
            cursor: arguments["cursor"]?.stringValue,
            limit: budget.applied,
            scope: scope
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
        items += try chain.events.map { event in
            .object([
                "kind": .string("change"),
                "event_id": .string(event.eventID),
                "observed_at": .string(timestamp(event.observedAt)),
                "timing": try jsonValue(EvidenceEventTimingPresentation(timing: event.timing)),
                "operation": .string(event.operation.rawValue),
                "path": .string(shape(path: event.path, detail: detail)),
                "logical_delta": .integer(event.logicalDelta),
                "allocated_delta": .integer(event.allocatedDelta),
                "confidence": .string(event.confidence.rawValue),
                "provenance_claims": .array((claimsByEvent[event.eventID] ?? []).map { claimItem($0, detail: detail) }),
            ])
        }
        let dates = chain.events.map(\.observedAt)
        var limitations: [String] = []
        if chain.objectIDs.count > 1 { limitations.append("The basename matched multiple historical file identities; each object ID remains distinct.") }
        if chain.identityLimitReached {
            limitations.append("More than \(EvidenceStore.provenanceIdentityLimit) file identities matched; results cover only the first \(EvidenceStore.provenanceIdentityLimit) by path order. Narrow the query to a fuller path.")
        }
        let latestObservation = try await store.latestObservationAt()
        let stateAsOf = chain.currentStateAsOf ?? latestObservation
        var result = pageObject(
            query: "get_provenance",
            observedAt: Date(),
            stateAsOf: chain.currentStateAsOf,
            requestedFrom: dates.min() ?? Date(),
            requestedThrough: dates.max() ?? Date(),
            retainedFrom: dates.min(),
            retainedThrough: dates.max(),
            coverage: evidenceCoverage(observationGaps: chain.observationGaps, stateAsOf: stateAsOf, hasRows: !items.isEmpty),
            precision: dates.isEmpty ? "unknown" : "raw",
            matchedCount: chain.matchedCount + chain.matchedCurrentStateCount,
            nextCursor: chain.nextCursor,
            items: items,
            limitations: limitations,
            scope: scope,
            scopeHiddenCount: nil,
            budget: budget
        ).objectValue ?? [:]
        result["object_ids"] = .array(chain.objectIDs.map(JSONValue.string))
        result["identity_limit_reached"] = .bool(chain.identityLimitReached)
        result["sessions"] = .array(chain.sessions.map { sessionItem($0, detail: detail) })
        result["coverage_gaps"] = .array(chain.observationGaps.map(gapItem))
        return .object(result)
    }

    private func activeAgentSessions(arguments: [String: JSONValue], compatibilityAlias: Bool) async throws -> JSONValue {
        let now = Date()
        let cutoff = now.addingTimeInterval(-TimeInterval(arguments["minutes"]?.integerValue ?? 60) * 60)
        let all = try await registry.activeRegistrations(proof: proof(), now: now)
            .filter { $0.lastHeartbeatAt >= cutoff }
            .sorted { ($0.lastHeartbeatAt, $0.registrationID.uuidString) > ($1.lastHeartbeatAt, $1.registrationID.uuidString) }
        let budget = rowBudget(arguments, worstCaseItemBytes: isRetired ? 2_048 : 1_024)
        // Bind the offset cursor to the ordered membership so a session that
        // registers, ends, or reorders between pages expires the page instead
        // of silently duplicating or skipping entries.
        let revision = SHA256.hash(data: Data(all.map { $0.registrationID.uuidString.lowercased() }.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let offset = try decodeOffsetCursor(arguments["cursor"]?.stringValue, revision: revision)
        let page = Array(all.dropFirst(offset).prefix(budget.applied))
        let next = offset + page.count < all.count ? encodeOffsetCursor(offset + page.count, revision: revision) : nil
        var sessionValues = page.map { sessionItem($0) }
        if isRetired {
            // TASK-672: which directories each session's workspace saw change.
            let watched = Set(await watchedRoots())
            for (index, registration) in page.enumerated() {
                guard case var .object(fields) = sessionValues[index] else { continue }
                fields["changed_directories"] = await directorySummary(registration, now: now, watched: watched)
                sessionValues[index] = .object(fields)
            }
        }
        return .object([
            "schema": .string(compatibilityAlias ? "active-writers-v1" : "active-agent-sessions-v1"),
            "observed_at": .string(timestamp(now)),
            "matched_count": .integer(Int64(all.count)),
            "returned_count": .integer(Int64(page.count)),
            "truncated": .bool(next != nil),
            "next_cursor": next.map(JSONValue.string) ?? .null,
            "budget": budgetObject(budget),
            "sessions": .array(sessionValues),
            "writers": compatibilityAlias ? .array(sessionValues) : .null,
            "compatibility_alias": .bool(compatibilityAlias),
            "limitations": .array(([
                "These are authenticated active task contexts, not observed file writers. Writer identity requires direct provenance evidence.",
            ] + policyLimitations(scope: nil, hiddenCount: nil, budget: budget, coverage: "n/a")).map(JSONValue.string)),
        ])
    }

    private func cleanupCandidates(arguments: [String: JSONValue]) async throws -> JSONValue {
        let now = Date()
        let olderThanDays = Int(arguments["older_than_days"]?.integerValue ?? 0)
        let cutoff = olderThanDays > 0 ? now.addingTimeInterval(-TimeInterval(olderThanDays) * 86_400) : nil
        let detail = pathDetail(arguments)
        let scope = try await queryScopeProvider()
        let budget = rowBudget(arguments, worstCaseItemBytes: 1_536)
        let page = try await store.queryCurrentConsumers(
            rootPath: arguments["root_path"]?.stringValue,
            category: arguments["category"]?.stringValue,
            minimumAllocatedBytes: max(1, arguments["minimum_bytes"]?.integerValue ?? 1),
            modifiedBefore: cutoff,
            cursor: arguments["cursor"]?.stringValue,
            limit: budget.applied,
            scope: scope
        )
        let candidates = page.items.compactMap { revalidatedCandidate($0, detail: detail, at: now) }
        let stateAsOf = try await store.latestObservationAt()
        let coverage = evidenceCoverage(observationGaps: try await store.coverageGaps(), stateAsOf: stateAsOf, hasRows: !page.items.isEmpty)
        return .object([
            "schema": .string("cleanup-candidates-v2"),
            "observed_at": .string(timestamp(now)),
            "state_as_of": stateAsOf.map { .string(timestamp($0)) } ?? .null,
            "state_age_seconds": stateAsOf.map { .integer(Int64(max(0, now.timeIntervalSince($0)))) } ?? .null,
            "coverage": .string(coverage),
            "matched_count": .null,
            "prevalidation_matched_count": .integer(Int64(page.matchedCount)),
            "returned_count": .integer(Int64(candidates.count)),
            "truncated": .bool(page.truncated),
            "next_cursor": page.nextCursor.map(JSONValue.string) ?? .null,
            "scope": scopeObject(scope, hiddenCount: page.scopeHiddenCount),
            "budget": budgetObject(budget),
            "items": .array(candidates),
            "safety": .string("review-required-never-safe-to-delete-claim"),
            "limitations": .array(([
                "Only present actionable records whose live path, stable identity, size, and modification time still match are returned.",
                "Path-temporal identities, inaccessible paths, changed files, symlinks, and stale or reused paths are excluded.",
                "Candidates are evidence for human review, not deletion instructions.",
            ] + policyLimitations(scope: scope, hiddenCount: page.scopeHiddenCount, budget: budget, coverage: coverage)).map(JSONValue.string)),
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
        await persistSession(registration)
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
        await persistSession(registration)
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
        await persistSession(ended)
        await freezeImpact(sessionID: ended.sessionID, startedAt: ended.registeredAt, roots: ended.workspaceRoots, through: ended.endedAt ?? Date())
        return .object([
            "schema": .string("session-end-result-v1"),
            "registration_id": .string(ended.registrationID.uuidString.lowercased()),
            "lifecycle": .string(ended.lifecycle.rawValue),
        ])
    }

    // MARK: Task impact from sessions and dirty sets (TASK-672)

    /// A session as the impact query sees it, from memory or the steward file.
    private struct SessionWindow {
        let key: String
        let client: String
        let roots: [String]
        let rootsTruncated: Bool
        let startedAt: Date
        /// When it ended, or when its lease ends.
        let endsAt: Date
        let source: String
    }

    private func persistSession(_ registration: AgentSessionRegistration) async {
        try? await sessionStore?.record(sessionID: registration.sessionID, client: registration.client.rawValue, roots: registration.workspaceRoots,
                                        startedAt: registration.registeredAt, endsAt: registration.endedAt ?? registration.expiresAt)
    }

    private func sessionWindows(sessionID: String, now: Date) async throws -> [SessionWindow] {
        let live = try await registry.historicalRegistrations(proof: proof(), now: now).filter { $0.sessionID == sessionID }
        var windows = live.map {
            SessionWindow(key: SessionStore.key($0.sessionID), client: $0.client.rawValue, roots: $0.workspaceRoots, rootsTruncated: false,
                          startedAt: $0.registeredAt, endsAt: $0.endedAt ?? $0.expiresAt, source: "registered")
        }
        if let sessionStore {
            for stored in (try? await sessionStore.sessions(sessionID: sessionID)) ?? []
            where !windows.contains(where: { $0.startedAt.timeIntervalSince1970 == stored.startedAt.timeIntervalSince1970 }) {
                windows.append(SessionWindow(key: stored.key, client: stored.client, roots: stored.roots, rootsTruncated: stored.rootsTruncated,
                                             startedAt: stored.startedAt, endsAt: stored.endsAt, source: "kept"))
            }
        }
        return windows.sorted { $0.startedAt < $1.startedAt }
    }

    /// The workspace roots of every other session overlapping the window.
    private func otherSessionRoots(excluding key: String, from: Date, through: Date, now: Date) async -> [[String]] {
        var seen = Set<String>()
        var roots: [[String]] = []
        for registration in (try? await registry.historicalRegistrations(proof: proof(), now: now)) ?? []
        where SessionStore.key(registration.sessionID) != key && registration.registeredAt <= through && (registration.endedAt ?? registration.expiresAt) >= from {
            if seen.insert("\(SessionStore.key(registration.sessionID))|\(registration.registeredAt.timeIntervalSince1970)").inserted { roots.append(registration.workspaceRoots) }
        }
        for stored in (try? await sessionStore?.sessions(overlapping: from, through: through)) ?? [] where stored.key != key {
            if seen.insert("\(stored.key)|\(stored.startedAt.timeIntervalSince1970)").inserted { roots.append(stored.roots) }
        }
        return roots
    }

    /// Keeps an ended session's directories so its impact outlives the
    /// journal's seven days. Only a window the journal fully covers is kept.
    private func freezeImpact(sessionID: String, startedAt: Date, roots: [String], through: Date) async {
        guard let sessionStore, let journal = try? existingJournal(),
              let start = try? await journal.coverageStart(), start <= startedAt,
              let window = try? await journal.changes(from: startedAt, through: through, relatedTo: roots, limit: SessionImpact.maximumDirectories + 64)
        else { return }
        let directories = SessionImpact.directories(changes: window.changes.items, roots: roots, watchedRoots: Set(await watchedRoots()), others: [])
        try? await sessionStore.freeze(sessionID: sessionID, startedAt: startedAt, directories: directories.items)
    }

    private static func relativePath(_ path: String, root: String, relation: SessionRelation) -> String {
        switch relation {
        case .at: return "."
        case .inside: return String(path.dropFirst(root == "/" ? 1 : root.count + 1))
        case .containsWorkspace:
            let levels = root.split(separator: "/").count - path.split(separator: "/").count
            return Array(repeating: "..", count: max(1, levels)).joined(separator: "/")
        }
    }

    private func objectValue(_ object: IndexedObject, root: String?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "name": .string(shape(path: object.path, detail: .basename)),
            "kind": .string(object.kind),
            "recreate_class": .string(object.recreateClass),
            "allocated_bytes": .integer(object.allocatedBytes),
            "measured_at": .string(timestamp(object.measuredAt)),
        ]
        if let root, let relation = SessionRelation.of(object.path, roots: [root])?.relation, relation != .containsWorkspace {
            fields["relative_path"] = .string(Self.relativePath(object.path, root: root, relation: relation))
        }
        return .object(fields)
    }

    /// TASK-672: a session's impact at directory and object granularity from
    /// the change journal's dirty sets; no per-file rows exist to return.
    private func sessionImpact(sessionID: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        let now = Date()
        let windows = try await sessionWindows(sessionID: sessionID, now: now)
        guard let first = windows.first else {
            throw DiskStewardIPCError.remote(code: "session_unavailable", message: "No registered or kept session matches that session ID.", retryable: false)
        }
        let from = arguments["from"]?.stringValue.flatMap(parseTimestamp) ?? first.startedAt
        let through = arguments["through"]?.stringValue.flatMap(parseTimestamp) ?? min(now, windows.map(\.endsAt).max() ?? now)
        guard from < through else {
            throw DiskStewardIPCError.remote(code: "invalid_range", message: "A valid from/through range is required.", retryable: false)
        }
        let roots = Array(Set(windows.flatMap(\.roots))).sorted()
        // Each directory row costs at most about 3 KiB with basename objects;
        // 96 KiB is kept for sessions, gaps and workspace objects.
        let affordable = max(1, (responseByteCeiling - 96 * 1_024) / (3 * 1_024))
        let limit = min(Int(arguments["limit"]?.integerValue ?? Int64(SessionImpact.maximumDirectories)), SessionImpact.maximumDirectories, affordable)
        let watched = Set(await watchedRoots())
        let others = await otherSessionRoots(excluding: first.key, from: from, through: through, now: now)
        var limitations = [
            "The change journal records that a directory changed during the session's window, not which process changed it; the user or other tools may have changed it too.",
            "Directories only: no file rows are kept or returned.",
        ]
        var directories = SessionImpact.Directories(items: [], total: 0, overflow: [])
        var gaps: [JournalGap] = []
        var coverageStart: Date?
        var coverage = "unknown"
        var source = "journal"
        var journalTotal = 0
        if let journal = try existingJournal() {
            let window = try await journal.changes(from: from, through: through, relatedTo: roots, limit: limit + 64)
            coverageStart = try await journal.coverageStart()
            gaps = window.gaps
            directories = SessionImpact.directories(changes: window.changes.items, roots: roots, watchedRoots: watched, others: others, limit: limit)
            journalTotal = max(directories.total, window.changes.total - directories.overflow.count)
            if let coverageStart, coverageStart <= from { coverage = gaps.isEmpty ? "complete" : "partial" } else if coverageStart != nil { coverage = "partial" }
            // Ended sessions the journal fully covers are kept for later.
            for window in windows where window.endsAt <= now {
                guard let sessionStore, let coverageStart, coverageStart <= window.startedAt else { continue }
                let kept = try? await sessionStore.frozen(sessionID: sessionID, startedAt: window.startedAt)
                if kept == nil {
                    await freezeImpact(sessionID: sessionID, startedAt: window.startedAt, roots: window.roots, through: window.endsAt)
                }
            }
        } else {
            limitations.append("The change journal has not started; which directories changed is unknown.")
        }
        // Where the journal no longer reaches back, a kept impact answers.
        if coverage != "complete", let sessionStore {
            var kept: [JournalChange] = []
            for window in windows where coverageStart.map({ $0 > window.startedAt }) ?? true {
                let rows = (try? await sessionStore.frozen(sessionID: sessionID, startedAt: window.startedAt)) ?? nil
                for row in rows ?? [] {
                    kept.append(JournalChange(path: row.path, changes: row.changes, firstInterval: window.startedAt, lastInterval: window.endsAt))
                }
            }
            if !kept.isEmpty {
                let frozen = SessionImpact.directories(changes: kept, roots: roots, watchedRoots: watched, others: others, limit: limit)
                let present = Set(directories.items.map(\.path))
                let merged = (directories.items + frozen.items.filter { !present.contains($0.path) }
                    .map { SessionDirectory(path: $0.path, relation: $0.relation, root: $0.root, changes: $0.changes, firstInterval: nil, lastInterval: nil, alsoActiveSessions: $0.alsoActiveSessions) })
                    .sorted { ($0.changes, $1.path) > ($1.changes, $0.path) }
                directories = SessionImpact.Directories(items: Array(merged.prefix(limit)), total: max(merged.count, directories.total), overflow: directories.overflow)
                journalTotal = max(journalTotal, merged.count)
                source = directories.items.contains { $0.firstInterval != nil } ? "journal-and-kept" : "kept"
                limitations.append("Part of this impact was kept when the session ended; kept directories have change counts but no intervals or gaps.")
            }
        }
        if let coverageStart, coverageStart > from {
            limitations.append("The change journal starts at \(timestamp(coverageStart)); earlier changes are unknown, not absent.")
        }
        if !directories.overflow.isEmpty {
            limitations.append("\(directories.overflow.count) rows sit at a watched root itself: more directories changed in an interval than the journal keeps, so those changes are known only at the root and are not attributed to this session.")
        }
        if directories.items.contains(where: { $0.relation == .containsWorkspace }) {
            limitations.append("A contains-workspace directory is coarser than the workspace: the journal collapsed a change two levels below its watched root, so it may lie outside this session's folders.")
        }
        if windows.contains(where: \.rootsTruncated) { limitations.append("Some workspace roots did not fit the kept session record and are not matched.") }

        // Objects: what the review index holds at or under each directory.
        var objects: [String: [IndexedObject]] = [:]
        var workspaceObjects: [IndexedObject] = []
        if let reviewIndex {
            let precise = directories.items.filter { $0.relation != .containsWorkspace }.map(\.path)
            let containing = (try? await reviewIndex.objectsContaining(precise)) ?? [:]
            let under = (try? await reviewIndex.objectsUnder(precise, limit: 3)) ?? [:]
            for path in precise { objects[path] = containing[path].map { [$0] } ?? Array((under[path] ?? []).prefix(3)) }
            let rootObjects = (try? await reviewIndex.objectsUnder(roots, limit: 20)) ?? [:]
            workspaceObjects = Array(roots.flatMap { rootObjects[$0] ?? [] }.sorted { $0.allocatedBytes > $1.allocatedBytes }.prefix(20))
        } else {
            limitations.append("The object index is not available here; objects are not listed.")
        }
        let items: [JSONValue] = directories.items.map { directory in
            var fields: [String: JSONValue] = [
                "path": .string(shape(path: directory.path, detail: .basename)),
                "relative_path": .string(Self.relativePath(directory.path, root: directory.root, relation: directory.relation)),
                "workspace_root": .string(shape(path: directory.root, detail: .basename)),
                "relation": .string(directory.relation.rawValue),
                "precision": .string(directory.relation == .containsWorkspace ? "coarser-than-workspace" : "workspace"),
                "changes": .integer(directory.changes),
                "first_interval": directory.firstInterval.map { .string(timestamp($0)) } ?? .null,
                "last_interval": directory.lastInterval.map { .string(timestamp($0)) } ?? .null,
                "also_active_sessions": .integer(Int64(directory.alsoActiveSessions)),
                "shared": .bool(directory.alsoActiveSessions > 0),
            ]
            fields["objects"] = .array((objects[directory.path] ?? []).map { objectValue($0, root: nil) })
            return .object(fields)
        }
        var answer: [String: JSONValue] = [
            "schema": .string("task-impact-v2"),
            "session_id": .string(sessionID),
            "observed_at": .string(timestamp(now)),
            "requested_interval": .object(["from": .string(timestamp(from)), "through": .string(timestamp(through))]),
            "sessions": .array(windows.prefix(20).map { window in .object([
                "client": .string(window.client),
                "workspace_roots": .array(window.roots.map { .string(shape(path: $0, detail: .basename)) }),
                "roots_truncated": .bool(window.rootsTruncated),
                "started_at": .string(timestamp(window.startedAt)),
                "ends_at": .string(timestamp(window.endsAt)),
                "state": .string(window.endsAt > now ? "lease-open" : "closed"),
                "source": .string(window.source),
            ]) }),
            "directories": .object([
                "items": .array(items),
                "total": .integer(Int64(journalTotal)),
                "returned_count": .integer(Int64(items.count)),
                "truncated": .bool(journalTotal > items.count),
            ]),
            "overflow": .array(directories.overflow.map { .object(["path": .string(shape(path: $0.path, detail: .basename)), "changes": .integer($0.changes)]) }),
            "journal_gaps": .array(gaps.map { gap in .object([
                "reason": .string(gap.reason), "path": .string(shape(path: gap.path, detail: .basename)), "at": .string(timestamp(gap.at)),
            ]) }),
            "journal_coverage_start": coverageStart.map { .string(timestamp($0)) } ?? .null,
            "coverage": .string(coverage),
            "source": .string(source),
            "confidence": .string(directories.items.isEmpty ? "unknown" : "inferred"),
            "method": .string("session-window-and-workspace-directory-correlation"),
            "attribution_semantics": .string("Directories that changed inside, at or above the session's workspace during its window; a correlation, never a claim about which process wrote."),
        ]
        answer["workspace_objects"] = .array(workspaceObjects.map { object in objectValue(object, root: roots.first { object.path.hasPrefix($0 + "/") || object.path == $0 }) })
        answer["limitations"] = .array(limitations.map(JSONValue.string))
        return .object(answer)
    }

    /// A short per-session summary for list_active_agent_sessions.
    private func directorySummary(_ registration: AgentSessionRegistration, now: Date, watched: Set<String>) async -> JSONValue {
        guard let journal = try? existingJournal(),
              let window = try? await journal.changes(from: registration.registeredAt, through: now, relatedTo: registration.workspaceRoots, limit: 64)
        else { return .null }
        let directories = SessionImpact.directories(changes: window.changes.items, roots: registration.workspaceRoots, watchedRoots: watched, others: [], limit: 3)
        return .object([
            "total": .integer(Int64(max(directories.total, window.changes.total - directories.overflow.count))),
            "items": .array(directories.items.map { directory in .object([
                "relative_path": .string(Self.relativePath(directory.path, root: directory.root, relation: directory.relation)),
                "workspace_root": .string(shape(path: directory.root, detail: .basename)),
                "relation": .string(directory.relation.rawValue),
                "changes": .integer(directory.changes),
            ]) }),
            "journal_gaps": .integer(Int64(window.gaps.count)),
        ])
    }

    private func taskImpact(arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let sessionID = arguments["session_id"]?.stringValue else {
            throw DiskStewardIPCError.remote(code: "invalid_request", message: "session_id is required.", retryable: false)
        }
        if isRetired { return try await sessionImpact(sessionID: sessionID, arguments: arguments) }
        let allRegistrations = try await registry.historicalRegistrations(proof: proof(), now: Date())
        let registrations = allRegistrations.filter { $0.sessionID == sessionID }
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
        let scope = try await queryScopeProvider()
        let candidates: [TaskImpactCandidate]
        do {
            candidates = try await store.taskImpactCandidates(
                from: from, through: through, maximumRows: taskImpactMaximumRows, maximumBytes: taskImpactMaximumBytes, scope: scope)
        }
        catch TaskImpactQueryError.budgetExceeded {
            throw DiskStewardIPCError.remote(code: "query_budget_exceeded",
                message: "Task impact exceeds the retained-evidence query budget. Use a narrower time window; no partial totals were returned.", retryable: false)
        }
        let gaps = try await store.coverageGaps()
        var correlatedEvents: [EvidenceStoreEvent] = []
        var confidenceValues: [EvidenceStoreEvent.Confidence] = []
        var usedDirectClaim = false
        let engine = ProvenanceEngine()
        for candidate in candidates {
            try Task.checkCancellation()
            let event = candidate.event
            let occurrence = candidate.currentClaim.map {
                (start: $0.occurredStart, end: $0.occurredEnd)
            } ?? event.timing.map { (start: $0.occurredStart, end: $0.occurredEnd) }
            let hasGap = gaps.contains { gap in
                let root = URL(fileURLWithPath: gap.rootPath).standardizedFileURL.path
                let path = URL(fileURLWithPath: event.path).standardizedFileURL.path
                guard gap.rootPath == "*" || path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { return false }
                guard let timing = occurrence else { return true }
                return gap.startedAt <= timing.end
                    && (timing.start.map { gap.endedAt == nil || gap.endedAt! >= $0 } ?? true)
            }
            guard let claim = engine.taskAttribution(for: event, currentClaim: candidate.currentClaim,
                registrations: allRegistrations, hasObservationGap: hasGap),
                claim.session?.sessionID == sessionID,
                claim.occurredEnd >= from, claim.occurredStart.map({ $0 <= through }) ?? true
            else { continue }
            correlatedEvents.append(event)
            confidenceValues.append(claim.confidence)
            usedDirectClaim = usedDirectClaim || claim.actor != nil
        }
        let eventIDs = correlatedEvents.map(\.eventID)
        let surviving = try await store.survivingImpact(eventIDs: eventIDs)
        let limit = min(max(Int(arguments["limit"]?.integerValue ?? 500), 1), 500)
        let returnedIDs = Array(eventIDs.prefix(limit))
        func sum(_ values: [Int64]) throws -> Int64 {
            try values.reduce(0) { total, value in
                let (result, overflow) = total.addingReportingOverflow(value)
                guard !overflow else {
                    throw DiskStewardIPCError.remote(code: "query_budget_exceeded", message: "Task impact totals exceed the representable byte range.", retryable: false)
                }
                return result
            }
        }
        let growth = try sum(correlatedEvents.map { max(0, $0.allocatedDelta) })
        let negative = try sum(correlatedEvents.map { min(0, $0.allocatedDelta) })
        guard negative != Int64.min else {
            throw DiskStewardIPCError.remote(code: "query_budget_exceeded", message: "Task impact shrinkage exceeds the representable byte range.", retryable: false)
        }
        let shrink = -negative
        let logicalDelta = try sum(correlatedEvents.map(\.logicalDelta))
        let allocatedDelta = try sum(correlatedEvents.map(\.allocatedDelta))
        let confidence = weakestConfidence(confidenceValues)
        return .object([
            "schema": .string("task-impact-v1"),
            "attribution_semantics": .string("occurrence-bounds-v1"),
            "window_semantics": .string("possible-occurrence-overlap"),
            "totals_scope": .string("whole-deltas-of-matched-events-not-time-prorated"),
            "session_id": .string(sessionID),
            "requested_interval": interval(from: from, through: through),
            "event_ids": .array(returnedIDs.map(JSONValue.string)),
            "matched_count": .integer(Int64(eventIDs.count)),
            "returned_count": .integer(Int64(returnedIDs.count)),
            "truncated": .bool(returnedIDs.count < eventIDs.count),
            "logical_delta": .integer(logicalDelta),
            "allocated_delta": .integer(allocatedDelta),
            "historical_growth_bytes": .integer(growth),
            "historical_shrink_bytes": .integer(shrink),
            "historical_churn_bytes": .integer(try sum([growth, shrink])),
            "surviving_object_count": .integer(Int64(surviving.objectCount)),
            "surviving_logical_bytes": .integer(surviving.logicalBytes),
            "surviving_allocated_bytes": .integer(surviving.allocatedBytes),
            "confidence": .string(confidence.rawValue),
            "session_lifecycle": .array(registrations.map { .string($0.lifecycle.rawValue) }),
            "sessions": .array(registrations.map { sessionItem($0) }),
            "coverage": .string(evidenceCoverage(observationGaps: gaps, stateAsOf: try await store.latestObservationAt(), hasRows: !candidates.isEmpty, from: from, through: through)),
            "coverage_gaps": .array(gaps.filter { $0.startedAt <= through && ($0.endedAt == nil || $0.endedAt! >= from) }.map(gapItem)),
            "scope": scopeObject(scope, hiddenCount: nil),
            "method": .string(usedDirectClaim ? "persisted-provenance-and-session-correlation" : "retained-session-temporal-and-workspace-correlation"),
            "limitations": .array([
                "Ended or expired session evidence can support historical temporal/workspace inference but cannot establish a writer without direct process-file evidence.",
                "Unknown occurrence lower bounds and competing or partially covering workspaces cannot establish a workspace/time attribution. Unverified observations are not task creation evidence.",
                "The window selects possible occurrence overlaps; totals include each matched event's whole delta, not bytes proven to have changed inside that window.",
                "No matching attribution means unknown impact, not proof that the task changed nothing."
            ].map(JSONValue.string)),
        ])
    }

    /// The store an export reads: the live store, or once file scanning is
    /// retired, a clone of the newest legacy set. The legacy files themselves
    /// are never opened; the clone is reused until a newer set appears.
    private func exportSource() async throws -> EvidenceStore {
        guard case let .retired(supportDirectory) = fileDetail else { return try store }
        guard let newest = try LegacyEvidence.sets(in: supportDirectory).first else {
            throw DiskStewardIPCError.remote(code: "no_legacy_evidence", message: "File-level scanning is retired and there is no legacy evidence to export.", retryable: false)
        }
        if let legacyExport, legacyExport.name == newest.name { return legacyExport.store }
        if let previous = legacyExport {
            legacyExport = nil
            await previous.store.close()
            try? FileManager.default.removeItem(at: previous.directory)
        }
        let clone = try LegacyEvidence.clone(newest, supportDirectory: supportDirectory)
        do {
            let opened = try EvidenceStore(url: clone)
            legacyExport = (newest.name, opened, clone.deletingLastPathComponent())
            return opened
        } catch {
            try? FileManager.default.removeItem(at: clone.deletingLastPathComponent())
            throw error
        }
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
        let scope = try await queryScopeProvider()
        let exportStore = try await exportSource()
        do { result = try await exporter.export(
            store: exportStore,
            options: .init(from: from, through: through, pathDetail: detail, maximumEvents: min(max(maximumEvents, 1), 10_000), limits: .inline, scope: scope),
            to: workspace.directory,
            kind: .temporary
        ) } catch { throw exportFailure(error) }
        var cleanup = TemporaryExportCleanup(result: result) { [exportStore] in
            try await exportStore.markTemporaryExportDestroyed(id: result.exportID)
        }
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
                "scope": scopeObject(scope, hiddenCount: nil),
            ])
            // MCP emits both structuredContent and escaped text; reserve ample
            // space below its 4 MiB transport ceiling for that envelope.
            guard try JSONEncoder().encode(response).count <= 1_024 * 1_024 else { throw DiskStewardIPCError.responseTooLarge }
            try Task.checkCancellation()
            try await cleanup.perform()
            return response
        } catch {
            try? await cleanup.perform()
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
        limitations: [String],
        scope: EvidenceQueryScope? = nil,
        scopeHiddenCount: Int? = nil,
        budget: RowBudget? = nil
    ) -> JSONValue {
        let retained: JSONValue
        if let retainedFrom, let retainedThrough {
            retained = interval(from: retainedFrom, through: retainedThrough)
        } else {
            retained = .null
        }
        let allLimitations = limitations + policyLimitations(scope: scope, hiddenCount: scopeHiddenCount, budget: budget, coverage: coverage)
        return .object([
            "schema": .string("evidence-query-page-v1"),
            "query": .string(query),
            "observed_at": .string(timestamp(observedAt)),
            "state_as_of": stateAsOf.map { .string(timestamp($0)) } ?? .null,
            "state_age_seconds": stateAsOf.map { .integer(Int64(max(0, observedAt.timeIntervalSince($0)))) } ?? .null,
            "requested_interval": interval(from: requestedFrom, through: requestedThrough),
            "retained_interval": retained,
            "coverage": .string(coverage),
            "precision": .string(precision),
            "matched_count": matchedCount.map { .integer(Int64($0)) } ?? .null,
            "returned_count": .integer(Int64(items.count)),
            "truncated": .bool(nextCursor != nil),
            "next_cursor": nextCursor.map(JSONValue.string) ?? .null,
            "scope": scopeObject(scope, hiddenCount: scopeHiddenCount),
            "budget": budgetObject(budget),
            "items": .array(items),
            "limitations": .array(allLimitations.map(JSONValue.string)),
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
            "schema": .string("provenance-claim-v3"),
            "timing_basis": .string(claim.timingBasis),
            "detected_at": .string(timestamp(claim.detectedAt)),
            "occurred_interval": .object([
                "from": claim.occurredStart.map { .string(timestamp($0)) } ?? .null,
                "through": .string(timestamp(claim.occurredEnd)),
            ]),
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

    private func sessionItem(_ registration: AgentSessionRegistration, detail: EvidencePathDetail = .basename) -> JSONValue {
        .object([
            "registration_id": .string(registration.registrationID.uuidString.lowercased()),
            "session_id": .string(registration.sessionID),
            "client": .string(registration.client.rawValue),
            "lifecycle": .string(registration.lifecycle.rawValue),
            "pid": .integer(Int64(registration.process.pid)),
            "process_start_time": .string(timestamp(registration.process.startTime)),
            "executable": registration.process.executablePath.map { .string(shape(path: $0, detail: detail)) } ?? .null,
            "workspace_roots": .array(registration.workspaceRoots.map { .string(shape(path: $0, detail: detail)) }),
            "registered_at": .string(timestamp(registration.registeredAt)),
            "last_heartbeat_at": .string(timestamp(registration.lastHeartbeatAt)),
            "expires_at": .string(timestamp(registration.expiresAt)),
            "ended_at": registration.endedAt.map { .string(timestamp($0)) } ?? .null,
            // Arbitrary text can name paths outside the registered workspace.
            // Do not claim basename/hashed privacy by filtering roots alone.
            "task_context": detail == .full ? (registration.taskContext.map(JSONValue.string) ?? .null) : .null,
            "task_context_withheld": .bool(detail != .full && registration.taskContext != nil),
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

    private func encodeOffsetCursor(_ offset: Int, revision: String) -> String {
        Data("offset:\(offset):\(revision)".utf8).base64EncodedString()
    }

    private func decodeOffsetCursor(_ cursor: String?, revision: String) throws -> Int {
        guard let cursor else { return 0 }
        guard let data = Data(base64Encoded: cursor),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("offset:")
        else { throw EvidenceStoreError.cursorExpired }
        let parts = text.dropFirst(7).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let value = Int(parts[0]), value >= 0, parts[1] == revision else {
            throw EvidenceStoreError.cursorExpired
        }
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

/// Retain proof of this request's successful removal across inventory retries.
/// A missing pathname on the first attempt is never treated as such proof.
struct TemporaryExportCleanup {
    let result: EvidenceBundleExportResult
    let finishInventory: @Sendable () async throws -> Void
    private var removedPayload = false

    init(result: EvidenceBundleExportResult, finishInventory: @escaping @Sendable () async throws -> Void) {
        self.result = result
        self.finishInventory = finishInventory
    }

    mutating func perform() async throws {
        if !removedPayload {
            try result.destroyTemporaryPayload()
            removedPayload = true
        }
        // Await cleanup without inheriting the cancelled request's task flag.
        let finish = finishInventory
        try await Task { try await finish() }.value
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
        // A bundle whose ownership check failed may remain here. Never bypass
        // that rejection by recursively deleting its enclosing workspace.
        _ = rmdir(directory.path)
    }
}
