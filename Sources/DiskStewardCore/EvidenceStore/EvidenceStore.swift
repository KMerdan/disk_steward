import CSQLite
import Darwin
import Foundation

public actor EvidenceStore {
    /// Highest schema this build understands; migrations run up to it and a
    /// newer on-disk schema is refused rather than partially interpreted.
    static let currentSchemaVersion: Int64 = 14

    public typealias DateSource = @Sendable () -> Date
    public typealias ReconciliationCheckpoint = @Sendable (String) throws -> Void
    public typealias MigrationCheckpoint = @Sendable (String) throws -> Void
    public typealias AvailableCapacitySource = @Sendable (URL) -> Int64?
    private static let maximumInlineCommitRows = 2_048

    private struct CurrentQueryCursor: Codable {
        let revision: String
        let allocatedBytes: Int64
        let path: String
        let objectID: String
    }

    private struct EventQueryCursor: Codable {
        let revision: String
        let observedAt: Date
        let eventID: String
    }

    private struct ProvenanceQueryCursor: Codable {
        let revision: String
        let currentStateOffset: Int
        let event: EventQueryCursor?
    }

    private var connection: SQLiteConnection?
    private let databaseURL: URL
    private let dateSource: DateSource
    private let reconciliationCheckpoint: ReconciliationCheckpoint
    private var storageCapBytes: Int64
    private let availableCapacitySource: AvailableCapacitySource
    private let retentionCheckpoint: ReconciliationCheckpoint
    private let walJournalSizeLimit: Int64
    /// The largest demand refused since retention last ran. It is cleared only
    /// when work of at least that size is admitted or when retention targets
    /// it, so an unrelated small write between a refusal and the retention it
    /// triggers cannot erase the demand. Callers that hold the refusal pass its
    /// demand explicitly as well.
    private var pendingStorageDemandBytes: Int64 = 0
    // Validation is deliberately process-local: after a crash every retained
    // directory proof is checked again, rather than trusting an old checkpoint.
    private var validatingGenerationID: String?
    private var validatedAfterDirectory = ""
    private var validatedAfterRoot = ""

    public init(
        url: URL,
        dateSource: @escaping DateSource = Date.init,
        reconciliationCheckpoint: @escaping ReconciliationCheckpoint = { _ in },
        migrationCheckpoint: @escaping MigrationCheckpoint = { _ in },
        availableCapacitySource: @escaping AvailableCapacitySource = { EvidenceStore.availableCapacity(at: $0) },
        maximumStorageBytes: Int64 = 512 * 1_024 * 1_024,
        retentionCheckpoint: @escaping ReconciliationCheckpoint = { _ in },
        maximumPageCount: Int64? = nil,
        walJournalSizeLimit: Int64 = EvidenceStore.defaultWALJournalSizeLimit
    ) throws {
        databaseURL = url
        self.dateSource = dateSource
        self.reconciliationCheckpoint = reconciliationCheckpoint
        self.retentionCheckpoint = retentionCheckpoint
        self.availableCapacitySource = availableCapacitySource
        self.walJournalSizeLimit = max(4_096, walJournalSizeLimit)
        storageCapBytes = max(1 * 1_024 * 1_024, maximumStorageBytes)
        try Self.prepareDatabaseForOpen(
            at: url,
            checkpoint: migrationCheckpoint,
            availableCapacitySource: availableCapacitySource
        )
        let connection = try SQLiteConnection(url: url)
        do {
            try Self.configure(connection, walJournalSizeLimit: self.walJournalSizeLimit)
            if let maximumPageCount {
                // Disk-full fixture: SQLite refuses growth beyond this page count
                // with SQLITE_FULL, exactly as a full volume would.
                try connection.execute("PRAGMA max_page_count=\(max(1, maximumPageCount))")
            }
            try Self.migrate(connection)
            try Self.recoverInterruptedLifecycles(connection, at: dateSource())
            self.connection = connection
        } catch {
            connection.close()
            throw error
        }
    }

    public func close() {
        connection?.close()
        connection = nil
    }

    public func insert(_ event: EvidenceStoreEvent) throws {
        try insert([event])
    }

    public func insert(_ events: [EvidenceStoreEvent]) throws {
        try admit(.generic(bytes: Int64(events.count * 512)))
        let connection = try requireConnection()
        try connection.transaction {
            for event in events {
                try Self.validate(event)
                try connection.withStatement(
                    """
                    INSERT INTO events (
                        event_id, observed_at, operation, path, logical_delta, allocated_delta,
                        consumer_category, confidence, is_anomaly, is_reviewed
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                ) { statement in
                    try connection.bind(event.eventID, at: 1, in: statement)
                    try connection.bind(event.observedAt.timeIntervalSince1970, at: 2, in: statement)
                    try connection.bind(event.operation.rawValue, at: 3, in: statement)
                    try connection.bind(event.path, at: 4, in: statement)
                    try connection.bind(event.logicalDelta, at: 5, in: statement)
                    try connection.bind(event.allocatedDelta, at: 6, in: statement)
                    try connection.bind(event.consumerCategory, at: 7, in: statement)
                    try connection.bind(event.confidence.rawValue, at: 8, in: statement)
                    try connection.bind(Int64(event.isAnomaly ? 1 : 0), at: 9, in: statement)
                    try connection.bind(Int64(event.isReviewed ? 1 : 0), at: 10, in: statement)
                    try connection.stepDone(statement)
                }
            }
        }
    }

    public func events(from: Date, through: Date, limit: Int = 1_000) throws -> [EvidenceStoreEvent] {
        guard from <= through else {
            throw EvidenceStoreError.invalidEvent("Evidence event query range is invalid")
        }
        let boundedLimit = min(max(limit, 1), 100_000)
        let connection = try requireConnection()
        return try connection.withStatement(
            """
            SELECT event_id, observed_at, operation, path, logical_delta, allocated_delta,
                   consumer_category, confidence, is_anomaly, is_reviewed,
                   occurred_start, occurred_end, detected_at
            FROM event_evidence
            WHERE observed_at >= ? AND observed_at <= ?
            ORDER BY observed_at, event_id
            LIMIT ?
            """
        ) { statement in
            try connection.bind(from.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(through.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(boundedLimit), at: 3, in: statement)
            var values: [EvidenceStoreEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let eventID = Self.columnString(statement, column: 0),
                      let operationText = Self.columnString(statement, column: 2),
                      let operation = EvidenceStoreEvent.Operation(rawValue: operationText),
                      let path = Self.columnString(statement, column: 3),
                      let category = Self.columnString(statement, column: 6),
                      let confidenceText = Self.columnString(statement, column: 7),
                      let confidence = EvidenceStoreEvent.Confidence(rawValue: confidenceText)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    eventID: eventID,
                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    operation: operation,
                    path: path,
                    logicalDelta: sqlite3_column_int64(statement, 4),
                    allocatedDelta: sqlite3_column_int64(statement, 5),
                    consumerCategory: category,
                    confidence: confidence,
                    isAnomaly: sqlite3_column_int64(statement, 8) != 0,
                    isReviewed: sqlite3_column_int64(statement, 9) != 0
                ).withTiming(try EvidenceEventTiming.read(statement)))
            }
            return values
        }
    }

    /// Candidate membership uses possible occurrence overlap, never discovery
    /// time. Select the newest non-superseded claim before filtering its bounds:
    /// filtering first could resurrect an older claim outside the current truth.
    public func taskImpactCandidates(
        from: Date, through: Date, maximumRows: Int = 100_000, maximumBytes: Int = 8 * 1_024 * 1_024,
        scope: EvidenceQueryScope? = nil
    ) throws -> [TaskImpactCandidate] {
        guard from.timeIntervalSince1970.isFinite, through.timeIntervalSince1970.isFinite, from <= through else {
            throw EvidenceStoreError.invalidEvent("Task impact query range is invalid")
        }
        let rows = min(100_000, max(1, maximumRows))
        let bytes = min(8 * 1_024 * 1_024, max(1, maximumBytes))
        let connection = try requireConnection()
        let scopePredicate = scope?.predicate(column: "e.path")
        let scopeClause = scopePredicate.map { " AND " + $0.sql } ?? ""
        return try connection.withStatement("""
            SELECT e.event_id, e.observed_at, e.operation, e.path, e.logical_delta, e.allocated_delta,
                   e.consumer_category, e.confidence, e.is_anomaly, e.is_reviewed,
                   e.occurred_start, e.occurred_end, e.detected_at, p.payload
            FROM event_evidence e
            LEFT JOIN provenance_claims p ON p.claim_id = (
                SELECT c.claim_id FROM provenance_claims c
                WHERE c.event_id = e.event_id AND c.timing_version = 1 AND c.superseded_by_claim_id IS NULL
                ORDER BY c.detected_at DESC, c.claim_id DESC LIMIT 1
            )
            WHERE ((p.claim_id IS NULL AND e.occurred_end >= ? AND (e.occurred_start IS NULL OR e.occurred_start <= ?))
               OR (p.occurred_end >= ? AND (p.occurred_start IS NULL OR p.occurred_start <= ?)))\(scopeClause)
            ORDER BY e.observed_at, e.event_id
            LIMIT ?
            """) { statement in
            var index: Int32 = 1
            try connection.bind(from.timeIntervalSince1970, at: index, in: statement); index += 1
            try connection.bind(through.timeIntervalSince1970, at: index, in: statement); index += 1
            try connection.bind(from.timeIntervalSince1970, at: index, in: statement); index += 1
            try connection.bind(through.timeIntervalSince1970, at: index, in: statement); index += 1
            for value in scopePredicate?.bindings ?? [] { try connection.bind(value, at: index, in: statement); index += 1 }
            try connection.bind(Int64(rows + 1), at: index, in: statement)
            var candidates: [TaskImpactCandidate] = []
            var admittedBytes = 0
            while true {
                try Task.checkCancellation()
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw connection.lastError(code) }
                // Check SQLite byte lengths before copying strings/JSON into
                // Swift. Refuse incomplete totals instead of returning a prefix
                // that looks like complete task impact.
                let rowBytes = [0, 2, 3, 6, 7, 13].reduce(256) { $0 + Int(sqlite3_column_bytes(statement, Int32($1))) }
                guard candidates.count < rows, rowBytes <= bytes - admittedBytes else {
                    throw TaskImpactQueryError.budgetExceeded
                }
                admittedBytes += rowBytes
                let event = try Self.readEvent(statement: statement, connection: connection)
                let claim: ProvenanceClaim? = sqlite3_column_type(statement, 13) == SQLITE_NULL ? nil
                    : try JSONDecoder().decode(ProvenanceClaim.self, from: Self.columnData(statement, column: 13, connection: connection))
                candidates.append(.init(event: event, currentClaim: claim))
            }
            return candidates
        }
    }

    public func beginOrResumeScanGeneration(
        scope: EvidenceScopeVersion,
        at date: Date = Date()
    ) throws -> MetadataScanGeneration {
        let connection = try requireConnection()
        if let active = try Self.readScanGeneration(status: .active, connection: connection),
           active.scopeVersionID == scope.scopeVersionID,
           active.passProvenanceVersion == 2,
           active.reconciliationToken != nil,
           active.status == .active
        {
            var refreshed = active
            try connection.transaction {
                refreshed = try Self.synchronizeFrontier(active, discovered: [], connection: connection)
                if refreshed != active {
                    try Self.persistScanGeneration(refreshed, rowStatus: .active, connection: connection)
                }
            }
            return refreshed
        }
        try admit(.generic(bytes: 4_096))

        let rootsJSON = String(data: try JSONEncoder().encode(scope.rootPaths), encoding: .utf8) ?? "[]"
        let exclusionsJSON = String(data: try JSONEncoder().encode(scope.excludedPaths), encoding: .utf8) ?? "[]"
        var created: MetadataScanGeneration!
        try connection.transaction {
            if let active = try Self.readScanGeneration(status: .active, connection: connection) {
                let abandoned = Self.copyScanGeneration(
                    active,
                    status: .abandoned,
                    updatedAt: date,
                    completedAt: date,
                    limitations: active.limitations + [active.scopeVersionID != scope.scopeVersionID
                        ? "Scope version changed before this scan generation completed; staged observations were discarded without reconciling absence."
                        : "Unpublished staging lacks resumable pass provenance or publication was interrupted; retained current evidence is unchanged and a fresh generation is required."]
                )
                try Self.persistScanGeneration(abandoned, rowStatus: .abandoned, connection: connection)
                try connection.execute("DELETE FROM scan_generation_entries WHERE generation_id = '\(Self.sqlLiteral(active.generationID))'")
                try connection.execute("DELETE FROM scan_directory_passes WHERE generation_id = '\(Self.sqlLiteral(active.generationID))'")
                try Self.deleteFrontier(generationID: active.generationID, connection: connection)
            }
            try connection.withStatement(
                "INSERT OR IGNORE INTO scope_versions (scope_version_id, effective_at, roots_json, exclusions_json, maximum_entries, maximum_depth) VALUES (?, ?, ?, ?, ?, ?)"
            ) { statement in
                try connection.bind(scope.scopeVersionID, at: 1, in: statement)
                try connection.bind(scope.effectiveAt.timeIntervalSince1970, at: 2, in: statement)
                try connection.bind(rootsJSON, at: 3, in: statement)
                try connection.bind(exclusionsJSON, at: 4, in: statement)
                try connection.bind(Int64(scope.maximumEntries), at: 5, in: statement)
                try connection.bind(Int64(scope.maximumDepth), at: 6, in: statement)
                try connection.stepDone(statement)
            }
            created = MetadataScanGeneration(
                generationID: "scan-generation-\(UUID().uuidString.lowercased())",
                scopeVersionID: scope.scopeVersionID,
                rootPaths: scope.rootPaths,
                excludedPaths: scope.excludedPaths,
                status: .active,
                roots: scope.rootPaths.map { .init(rootPath: $0) },
                processedEntryCount: 0,
                stagedFileCount: 0,
                startedAt: date,
                updatedAt: date,
                limitations: []
            )
            try Self.persistScanGeneration(created, rowStatus: .active, connection: connection)
            try connection.execute(
                "DELETE FROM scan_generations WHERE generation_id IN (SELECT generation_id FROM scan_generations WHERE status != 'active' ORDER BY updated_at DESC, generation_id DESC LIMIT -1 OFFSET 64)"
            )
        }
        return created
    }

    public func recordScanSlice(
        snapshot: StorageSnapshot,
        slice: MetadataScanSlice,
        scope: EvidenceScopeVersion,
        trigger: EvidenceObservationTrigger,
        eventGap: Bool = false,
        publicationPermit: ScanPublicationPermit? = nil
    ) throws -> ScanGenerationCommitResult {
        try publicationPermit?.validate()
        let connection = try requireConnection()
        guard slice.generation.scopeVersionID == scope.scopeVersionID else {
            throw EvidenceStoreError.invalidObservation("scan generation and scope version identifiers differ")
        }
        guard let active = try Self.readScanGeneration(status: .active, connection: connection),
              active.generationID == slice.generation.generationID
        else {
            throw EvidenceStoreError.invalidObservation("scan generation cursor is no longer active")
        }
        guard active.reconciliationToken != nil else {
            throw EvidenceStoreError.invalidObservation("scan generation lacks a dirty-evidence fence")
        }
        guard active.reconciliationToken == slice.generation.reconciliationToken else {
            // Receipt-order changes trump wall-clock order. Return the durable
            // reset cursor so the caller continues without publishing old work.
            return ScanGenerationCommitResult(generation: active, observation: nil)
        }
        guard active.processedEntryCount <= slice.generation.processedEntryCount else {
            throw EvidenceStoreError.invalidObservation("scan generation progress moved backwards")
        }
        guard slice.generation.passProvenanceVersion == 2 else {
            throw EvidenceStoreError.invalidObservation("scan generation has no current pass provenance")
        }
        try admit(.staging(rows: slice.entries.count, passes: slice.directoryPasses.count))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let snapshotPayload = try encoder.encode(snapshot)
        var persisted = slice.generation
        try connection.transaction {
            // Restarting a directory invalidates the preceding pass, including
            // descendants already staged. A lexical restart alone would retain
            // deleted files from the superseded pass and publish false presence.
            for invalidation in slice.invalidatedDirectoryPasses {
                try Self.invalidateDirectoryPass(invalidation.directoryPath, rootPath: invalidation.rootPath,
                                                 generationID: slice.generation.generationID, connection: connection)
            }
            try connection.withStatement("INSERT OR IGNORE INTO snapshots (snapshot_id, observed_at, payload) VALUES (?, ?, ?)") { statement in
                try connection.bind(snapshot.snapshotID, at: 1, in: statement)
                try connection.bind(slice.generation.updatedAt.timeIntervalSince1970, at: 2, in: statement)
                try connection.bind(snapshotPayload, at: 3, in: statement)
                try connection.stepDone(statement)
            }
            for entry in slice.entries {
                guard !slice.generation.roots.contains(where: { $0.rootPath == entry.rootPath && $0.status == .failed }) else { continue }
                guard let passID = entry.directoryPassID, !passID.isEmpty, let sampledAt = entry.observedAt else {
                    throw EvidenceStoreError.invalidObservation("staged file lacks producing-pass or sample-time provenance")
                }
                let payload = try encoder.encode(entry)
                try connection.withStatement(
                    "INSERT INTO scan_generation_entries (generation_id, path, payload, object_id, identity_method, root_path, logical_bytes, allocated_bytes, modified_at, link_count, directory_path, pass_id, observed_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(generation_id, root_path, path) DO UPDATE SET payload = excluded.payload, object_id = excluded.object_id, identity_method = excluded.identity_method, logical_bytes = excluded.logical_bytes, allocated_bytes = excluded.allocated_bytes, modified_at = excluded.modified_at, link_count = excluded.link_count, directory_path = excluded.directory_path, pass_id = excluded.pass_id, observed_at = excluded.observed_at"
                ) { statement in
                    try connection.bind(slice.generation.generationID, at: 1, in: statement)
                    try connection.bind(entry.path, at: 2, in: statement)
                    try connection.bind(payload, at: 3, in: statement)
                    try connection.bind(entry.objectID, at: 4, in: statement)
                    try connection.bind(entry.identityMethod.rawValue, at: 5, in: statement)
                    try connection.bind(entry.rootPath, at: 6, in: statement)
                    try connection.bind(entry.logicalBytes, at: 7, in: statement)
                    try connection.bind(entry.allocatedBytes, at: 8, in: statement)
                    try connection.bind(entry.modifiedAt?.timeIntervalSince1970, at: 9, in: statement)
                    try connection.bind(Int64(entry.linkCount), at: 10, in: statement)
                    try connection.bind(URL(fileURLWithPath: entry.path).deletingLastPathComponent().path, at: 11, in: statement)
                    try connection.bind(passID, at: 12, in: statement)
                    try connection.bind(sampledAt.timeIntervalSince1970, at: 13, in: statement)
                    try connection.stepDone(statement)
                }
            }
            for root in slice.generation.roots where root.status == .failed {
                try connection.withStatement("DELETE FROM scan_generation_entries WHERE generation_id = ? AND root_path = ?") { statement in
                    try connection.bind(slice.generation.generationID, at: 1, in: statement)
                    try connection.bind(root.rootPath, at: 2, in: statement)
                    try connection.stepDone(statement)
                }
                try connection.withStatement("DELETE FROM scan_directory_passes WHERE generation_id = ? AND root_path = ?") { statement in
                    try connection.bind(slice.generation.generationID, at: 1, in: statement)
                    try connection.bind(root.rootPath, at: 2, in: statement)
                    try connection.stepDone(statement)
                }
            }
            for pass in slice.directoryPasses {
                guard !slice.generation.roots.contains(where: { $0.rootPath == pass.rootPath && $0.status == .failed }) else { continue }
                // A new pass replaces only this root's immediate-directory
                // membership. Other roots retain independent successful evidence.
                try connection.withStatement("DELETE FROM scan_generation_entries WHERE generation_id = ? AND root_path = ? AND directory_path = ? AND (pass_id IS NULL OR pass_id != ?)") { statement in
                    try connection.bind(slice.generation.generationID, at: 1, in: statement)
                    try connection.bind(pass.rootPath, at: 2, in: statement)
                    try connection.bind(pass.directoryPath, at: 3, in: statement)
                    try connection.bind(pass.passID, at: 4, in: statement)
                    try connection.stepDone(statement)
                }
                try connection.withStatement("INSERT INTO scan_directory_passes (generation_id, directory_path, root_path, payload, pass_id) VALUES (?, ?, ?, ?, ?) ON CONFLICT(generation_id, root_path, directory_path) DO UPDATE SET payload = excluded.payload, pass_id = excluded.pass_id") { statement in
                    try connection.bind(slice.generation.generationID, at: 1, in: statement)
                    try connection.bind(pass.directoryPath, at: 2, in: statement)
                    try connection.bind(pass.rootPath, at: 3, in: statement)
                    try connection.bind(encoder.encode(pass), at: 4, in: statement)
                    try connection.bind(pass.passID, at: 5, in: statement)
                    try connection.stepDone(statement)
                }
            }
            let stagedCount = Int(try connection.scalarInt(
                "SELECT COUNT(DISTINCT path) FROM scan_generation_entries WHERE generation_id = '\(Self.sqlLiteral(slice.generation.generationID))'"
            ))
            persisted = Self.copyScanGeneration(slice.generation, stagedFileCount: stagedCount)
            if persisted.status != .abandoned {
                // Frontier deltas commit with the staging they belong to.
                persisted = try Self.synchronizeFrontier(persisted, discovered: slice.discoveredDirectories, connection: connection)
            }
            let rowStatus: MetadataScanGenerationStatus = persisted.status == .abandoned ? .abandoned : .active
            try Self.persistScanGeneration(persisted, rowStatus: rowStatus, connection: connection)
            if persisted.status == .abandoned {
                try connection.execute("DELETE FROM scan_generation_entries WHERE generation_id = '\(Self.sqlLiteral(persisted.generationID))'")
                try connection.execute("DELETE FROM scan_directory_passes WHERE generation_id = '\(Self.sqlLiteral(persisted.generationID))'")
                try Self.deleteFrontier(generationID: persisted.generationID, connection: connection)
            }
        }

        let validationIdentity = "\(persisted.generationID)|\(persisted.reconciliationToken ?? "legacy")"
        if validatingGenerationID != validationIdentity || !slice.directoryPasses.isEmpty || !slice.invalidatedDirectories.isEmpty {
            validatingGenerationID = validationIdentity
            validatedAfterDirectory = ""
            validatedAfterRoot = ""
        }

        guard persisted.status == .completed else {
            return ScanGenerationCommitResult(generation: persisted, observation: nil)
        }

        persisted = try validateDirectoryPasses(generation: persisted, scope: scope, connection: connection)
        guard persisted.status == .completed else {
            return ScanGenerationCommitResult(generation: persisted, observation: nil)
        }

        let observation = try reconcileCompletedScanGeneration(
            snapshot: snapshot,
            generation: persisted,
            scope: scope,
            trigger: trigger,
            eventGap: eventGap,
            publicationPermit: publicationPermit
        )
        return ScanGenerationCommitResult(generation: persisted, observation: observation)
    }

    /// A finished frontier is not proof that earlier directories stayed stable.
    /// Recheck bounded SQLite-backed batches after traversal, retaining no full
    /// directory list in Swift. This establishes an observation interval, not an
    /// atomic filesystem snapshot; metadata retains its original sample time.
    private func validateDirectoryPasses(
        generation: MetadataScanGeneration,
        scope: EvidenceScopeVersion,
        connection: SQLiteConnection
    ) throws -> MetadataScanGeneration {
        for root in generation.roots where root.status == .completed {
            let hasRootPass = try connection.withStatement("SELECT COUNT(*) FROM scan_directory_passes WHERE generation_id = ? AND directory_path = ? AND root_path = ?") { statement in
                try connection.bind(generation.generationID, at: 1, in: statement)
                try connection.bind(root.rootPath, at: 2, in: statement)
                try connection.bind(root.rootPath, at: 3, in: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
                return sqlite3_column_int64(statement, 0) == 1
            }
            guard hasRootPass else { throw EvidenceStoreError.invalidObservation("completed root has no membership pass") }
        }
        let budget = min(512, max(1, scope.maximumEntries))
        let afterDirectory = validatedAfterDirectory
        let afterRoot = validatedAfterRoot
        let passes = try connection.withStatement("SELECT payload FROM scan_directory_passes WHERE generation_id = ? AND (directory_path, root_path) > (?, ?) ORDER BY directory_path, root_path LIMIT ?") { statement -> [MetadataScanDirectoryPass] in
            try connection.bind(generation.generationID, at: 1, in: statement)
            try connection.bind(afterDirectory, at: 2, in: statement)
            try connection.bind(afterRoot, at: 3, in: statement)
            try connection.bind(Int64(budget), at: 4, in: statement)
            var result: [MetadataScanDirectoryPass] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw connection.lastError(SQLITE_CORRUPT) }
                result.append(try JSONDecoder().decode(MetadataScanDirectoryPass.self,
                    from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
            }
            return result
        }
        for pass in passes {
            guard let owner = generation.roots.first(where: { $0.rootPath == pass.rootPath && $0.status == .completed }) else {
                // Failed-only coverage cannot authorize absence, even if one of
                // its individual directory passes happened to finish earlier.
                continue
            }
            let signature = DirectoryMetadataScanner.directorySignature(atPath: pass.directoryPath)
            if signature != pass.signature {
                // If the directory itself vanished/replaced with a symlink, its
                // root must rediscover the tree rather than following that path.
                let restartPath = signature == nil ? owner.rootPath : pass.directoryPath
                var restarted: MetadataScanGeneration!
                try connection.transaction {
                    try Self.invalidateDirectoryPass(restartPath, rootPath: owner.rootPath,
                                                     generationID: generation.generationID, connection: connection)
                    let roots = generation.roots.map { root in
                        guard root.rootPath == owner.rootPath else { return root }
                        let rootRestart = restartPath
                        let depth = URL(fileURLWithPath: rootRestart).pathComponents.count - URL(fileURLWithPath: root.rootPath).pathComponents.count
                        return MetadataScanRootProgress(rootPath: root.rootPath, status: .active,
                            frontier: [.init(directoryPath: rootRestart, depth: depth)],
                            processedEntryCount: root.processedEntryCount,
                            observedFileCount: root.observedFileCount, limitations: root.limitations)
                    }
                    let count = try connection.scalarInt("SELECT COUNT(DISTINCT path) FROM scan_generation_entries WHERE generation_id = '\(Self.sqlLiteral(generation.generationID))'")
                    try Self.deleteFrontier(generationID: generation.generationID, rootPath: owner.rootPath, connection: connection)
                    restarted = Self.copyScanGeneration(generation, status: .active, stagedFileCount: Int(count), roots: roots)
                    try Self.persistScanGeneration(restarted, rowStatus: .active, connection: connection)
                }
                validatedAfterDirectory = ""
                validatedAfterRoot = ""
                return restarted
            }
        }
        let last = passes.last?.directoryPath ?? validatedAfterDirectory
        let lastRoot = passes.last?.rootPath ?? validatedAfterRoot
        let more = try connection.withStatement("SELECT EXISTS(SELECT 1 FROM scan_directory_passes WHERE generation_id = ? AND (directory_path, root_path) > (?, ?))") { statement in
            try connection.bind(generation.generationID, at: 1, in: statement)
            try connection.bind(last, at: 2, in: statement)
            try connection.bind(lastRoot, at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return sqlite3_column_int64(statement, 0) != 0
        }
        let result = more ? Self.copyScanGeneration(generation, status: .active) : generation
        try Self.persistScanGeneration(result, rowStatus: .active, connection: connection)
        validatedAfterDirectory = last
        validatedAfterRoot = lastRoot
        return result
    }

    private static func invalidateDirectoryPass(_ directory: String, rootPath: String, generationID: String, connection: SQLiteConnection) throws {
        let prefix = directory == "/" ? "/" : directory + "/"
        // Pending descendants in the durable frontier belong to the superseded
        // pass; the restarted pass rediscovers them.
        for (table, column, includeDirectory) in [("scan_generation_entries", "path", false), ("scan_directory_passes", "directory_path", true), ("scan_frontier", "directory_path", false)] {
            try connection.withStatement("DELETE FROM \(table) WHERE generation_id = ? AND (substr(\(column), 1, length(?)) = ? OR (? AND \(column) = ?)) AND root_path = ?") { statement in
                try connection.bind(generationID, at: 1, in: statement)
                try connection.bind(prefix, at: 2, in: statement)
                try connection.bind(prefix, at: 3, in: statement)
                try connection.bind(Int64(includeDirectory ? 1 : 0), at: 4, in: statement)
                try connection.bind(directory, at: 5, in: statement)
                try connection.bind(rootPath, at: 6, in: statement)
                try connection.stepDone(statement)
            }
        }
    }

    private static func path(_ path: String, isWithin root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Absence is bounded by a producing directory pass, not by publication.
    /// If a parent vanished, the nearest retained ancestor pass supplies the
    /// membership proof. Only completed roots are eligible. Each lookup is
    /// indexed and the walk retains at most one directory proof at a time.
    private static func coveredAbsenceDate(path: String, generation: MetadataScanGeneration, connection: SQLiteConnection) throws -> Date {
        var observedAt: Date?
        for root in generation.roots where root.status == .completed && Self.path(path, isWithin: root.rootPath) {
            var directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
            while Self.path(directory, isWithin: root.rootPath) {
                let pass: MetadataScanDirectoryPass? = try connection.withStatement("SELECT payload FROM scan_directory_passes WHERE generation_id = ? AND root_path = ? AND directory_path = ?") { statement in
                    try connection.bind(generation.generationID, at: 1, in: statement)
                    try connection.bind(root.rootPath, at: 2, in: statement)
                    try connection.bind(directory, at: 3, in: statement)
                    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                    guard let bytes = sqlite3_column_blob(statement, 0) else { throw connection.lastError(SQLITE_CORRUPT) }
                    return try JSONDecoder().decode(MetadataScanDirectoryPass.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
                }
                if let pass {
                    observedAt = max(observedAt ?? pass.completedAt, pass.completedAt)
                    break
                }
                if directory == root.rootPath || directory == "/" { break }
                directory = URL(fileURLWithPath: directory).deletingLastPathComponent().path
            }
        }
        guard let observedAt else { throw EvidenceStoreError.invalidObservation("absence lacks a covering directory pass") }
        return observedAt
    }

    private static func stagedReplacementDate(input: ReconciliationInput, generationID: String, path: String, objectID: String, connection: SQLiteConnection) throws -> Date? {
        try connection.withStatement("SELECT MAX(observed_at) FROM \(input.table) WHERE generation_id = ? AND path = ? AND object_id != ?") { statement in
            try connection.bind(generationID, at: 1, in: statement)
            try connection.bind(path, at: 2, in: statement)
            try connection.bind(objectID, at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return columnDate(statement, column: 0)
        }
    }

    public func recordReconciliationInvalidation(
        rootPath: String = "*",
        reason: String = "event-drop",
        at date: Date = Date()
    ) throws {
        let connection = try requireConnection()
        let normalizedRoot = rootPath == "*" ? "*" : URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let checkpoint = reconciliationCheckpoint
        try connection.transaction {
            try checkpoint("before-invalidation")
            try Self.upsertReconciliationInvalidation(
                rootPath: normalizedRoot,
                reason: reason,
                at: date,
                connection: connection
            )
        }
    }

    public func hasPendingReconciliation() throws -> Bool {
        try requireConnection().scalarInt(
            "SELECT EXISTS(SELECT 1 FROM reconciliation_invalidations WHERE state = 'open')"
        ) != 0
    }

    public func pendingReconciliationCount() throws -> Int {
        Int(try requireConnection().scalarInt(
            "SELECT COUNT(*) FROM reconciliation_invalidations WHERE state = 'open'"
        ))
    }

    /// Reconciles a complete generation directly from indexed staging rows.
    /// SQLite owns the working sets; Swift retains only one object and a
    /// bounded result window at a time.
    private func reconcileCompletedScanGeneration(
        snapshot: StorageSnapshot,
        generation: MetadataScanGeneration,
        scope: EvidenceScopeVersion,
        trigger: EvidenceObservationTrigger,
        eventGap: Bool,
        publicationPermit: ScanPublicationPermit?
    ) throws -> ObservationCommitResult {
        let connection = try requireConnection()
        let observationID = generation.generationID
        let observedAt = generation.completedAt ?? generation.updatedAt
        let hasDurableInvalidation = try hasPendingReconciliation()
        let effectiveEventGap = eventGap || hasDurableInvalidation

        if try observationExists(observationID, connection: connection) {
            try connection.transaction(publicationPermit: publicationPermit) {
                try Self.persistScanGeneration(generation, rowStatus: .completed, connection: connection)
                try connection.execute("DELETE FROM scan_generation_entries WHERE generation_id = '\(Self.sqlLiteral(observationID))'")
                try connection.execute("DELETE FROM scan_directory_passes WHERE generation_id = '\(Self.sqlLiteral(observationID))'")
                try Self.deleteFrontier(generationID: observationID, connection: connection)
            }
            return try boundedCommitResult(
                observationID: observationID,
                events: [],
                persistedEventCount: 0,
                connection: connection
            )
        }

        let previousScopeID = try latestScopeVersionID(connection: connection)
        // Publication creates indexes/current-state/history in addition to the
        // staging rows. Reserve this work before entering the atomic transaction.
        let priorCurrentCount = try connection.scalarInt("SELECT COUNT(*) FROM current_file_state")
        try admit(.publication(stagedRows: Int64(generation.stagedFileCount), priorCurrentRows: priorCurrentCount))
        let previousObservedAt = try Self.latestCurrentObservationDate(connection: connection)
        let snapshotPayload = try JSONEncoder().encode(snapshot)
        let rootsJSON = String(data: try JSONEncoder().encode(scope.rootPaths), encoding: .utf8) ?? "[]"
        let exclusionsJSON = String(data: try JSONEncoder().encode(scope.excludedPaths), encoding: .utf8) ?? "[]"
        let checkpoint = reconciliationCheckpoint
        let metadata = MetadataSnapshot(
            observationID: observationID,
            scopeVersionID: scope.scopeVersionID,
            observedAt: observedAt,
            entries: [:],
            rootCoverage: generation.roots.map { .init(rootPath: $0.rootPath, coverage: $0.status == .completed ? .complete : .failed, limitations: $0.limitations) },
            limitations: generation.limitations
        )
        var inlineEvents: [EvidenceStoreEvent] = []
        var persistedEventCount = 0

        try connection.transaction(publicationPermit: publicationPermit) {
            try connection.withStatement(
                "INSERT OR IGNORE INTO scope_versions (scope_version_id, effective_at, roots_json, exclusions_json, maximum_entries, maximum_depth) VALUES (?, ?, ?, ?, ?, ?)"
            ) { statement in
                try connection.bind(scope.scopeVersionID, at: 1, in: statement)
                try connection.bind(scope.effectiveAt.timeIntervalSince1970, at: 2, in: statement)
                try connection.bind(rootsJSON, at: 3, in: statement)
                try connection.bind(exclusionsJSON, at: 4, in: statement)
                try connection.bind(Int64(scope.maximumEntries), at: 5, in: statement)
                try connection.bind(Int64(scope.maximumDepth), at: 6, in: statement)
                try connection.stepDone(statement)
            }
            try connection.withStatement(
                "INSERT INTO observation_runs (observation_id, scope_version_id, trigger, started_at, completed_at, coverage, event_gap) VALUES (?, ?, ?, ?, ?, '\(metadata.coverage.rawValue)', ?)"
            ) { statement in
                try connection.bind(observationID, at: 1, in: statement)
                try connection.bind(scope.scopeVersionID, at: 2, in: statement)
                try connection.bind(trigger.rawValue, at: 3, in: statement)
                try connection.bind(generation.startedAt.timeIntervalSince1970, at: 4, in: statement)
                try connection.bind(observedAt.timeIntervalSince1970, at: 5, in: statement)
                try connection.bind(Int64(effectiveEventGap ? 1 : 0), at: 6, in: statement)
                try connection.stepDone(statement)
            }
            try connection.withStatement(
                "INSERT OR IGNORE INTO snapshots (snapshot_id, observed_at, payload) VALUES (?, ?, ?)"
            ) { statement in
                try connection.bind(snapshot.snapshotID, at: 1, in: statement)
                try connection.bind(observedAt.timeIntervalSince1970, at: 2, in: statement)
                try connection.bind(snapshotPayload, at: 3, in: statement)
                try connection.stepDone(statement)
            }
            for root in generation.roots {
                let complete = root.status == .completed
                try connection.withStatement(
                    "INSERT INTO observation_roots (observation_id, root_path, coverage, limitations_json) VALUES (?, ?, ?, ?)"
                ) { statement in
                    try connection.bind(observationID, at: 1, in: statement)
                    try connection.bind(root.rootPath, at: 2, in: statement)
                    try connection.bind(complete ? "complete" : "failed", at: 3, in: statement)
                    try connection.bind(String(decoding: JSONEncoder().encode(root.limitations), as: UTF8.self), at: 4, in: statement)
                    try connection.stepDone(statement)
                }
                if complete {
                    try Self.resolveCoverageGaps(rootPath: root.rootPath, endedAt: observedAt, connection: connection)
                } else {
                    try Self.insertCoverageGap(.init(gapID: "gap-\(observationID)-\(Self.sqlLiteral(root.rootPath))", observationID: observationID, rootPath: root.rootPath, reason: "root-scan-failed", startedAt: generation.startedAt, endedAt: nil), connection: connection)
                }
            }
            if effectiveEventGap {
                let startedAt = try Self.earliestOpenInvalidationDate(connection: connection) ?? observedAt
                let gap = EvidenceCoverageGap(
                    gapID: "gap-\(observationID)-event-stream",
                    observationID: observationID,
                    rootPath: "*",
                    reason: "event-drop",
                    startedAt: startedAt,
                    endedAt: nil
                )
                try Self.insertCoverageGap(gap, connection: connection)
            }
            if trigger == .startup, let previousObservedAt, previousObservedAt < observedAt {
                let gap = EvidenceCoverageGap(
                    gapID: "gap-\(observationID)-app-offline",
                    observationID: observationID,
                    rootPath: "*",
                    reason: "app-offline",
                    startedAt: previousObservedAt,
                    endedAt: observedAt
                )
                try Self.insertCoverageGap(gap, connection: connection)
            }
            try checkpoint("after-observation")

            // Every contribution must be authorized by its own root's completed
            // producing pass. Only after validation do overlapping observations
            // collapse to one (latest sampled) value for a physical path.
            let generationLiteral = Self.sqlLiteral(observationID)
            let unproven = try connection.scalarInt("""
                SELECT EXISTS(
                    SELECT 1 FROM scan_generation_entries AS e
                    LEFT JOIN scan_directory_passes AS p
                      ON p.generation_id = e.generation_id AND p.root_path = e.root_path
                     AND p.directory_path = e.directory_path AND p.pass_id = e.pass_id
                    WHERE e.generation_id = '\(generationLiteral)' AND p.pass_id IS NULL
                )
                """)
            guard unproven == 0 else { throw EvidenceStoreError.invalidObservation("staged membership has no matching completed producing pass") }
            try connection.execute("""
                DELETE FROM scan_generation_entries WHERE rowid IN (
                    SELECT entry_rowid FROM (
                        SELECT rowid AS entry_rowid,
                               ROW_NUMBER() OVER (PARTITION BY path ORDER BY observed_at DESC, root_path) AS rank
                        FROM scan_generation_entries WHERE generation_id = '\(generationLiteral)'
                    ) WHERE rank > 1
                )
                """)

            let reconciled = try Self.reconcileObjects(
                metadata: metadata, scope: scope, previousScopeID: previousScopeID,
                input: .generation(generation), inlineEventLimit: Self.maximumInlineCommitRows,
                checkpoint: checkpoint, connection: connection
            )
            inlineEvents = reconciled.events
            persistedEventCount = reconciled.count
            try checkpoint("before-finalize")
            try Self.persistScanGeneration(generation, rowStatus: .completed, connection: connection)
            try connection.withStatement("DELETE FROM scan_generation_entries WHERE generation_id = ?") { statement in
                try connection.bind(observationID, at: 1, in: statement)
                try connection.stepDone(statement)
            }
            // These are transient publication inputs, not per-scan history.
            // Reclaim them atomically with staging, before future admission.
            try connection.withStatement("DELETE FROM scan_directory_passes WHERE generation_id = ?") { statement in
                try connection.bind(observationID, at: 1, in: statement)
                try connection.stepDone(statement)
            }
            try Self.deleteFrontier(generationID: observationID, connection: connection)
            try Self.resolveReconciliationInvalidations(generation: generation, at: observedAt, connection: connection)
            if metadata.coverage == .complete,
               try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM reconciliation_invalidations WHERE state = 'open')") == 0 {
                try Self.resolveCoverageGaps(rootPath: "*", reason: "event-drop", endedAt: observedAt, connection: connection)
            }
        }

        return try boundedCommitResult(
            observationID: observationID,
            events: inlineEvents,
            persistedEventCount: persistedEventCount,
            connection: connection
        )
    }

    // The two public ingestion paths have different coverage proofs, but share
    // one identity/path reconciliation contract. Table names are a closed enum,
    // never supplied by callers; a legacy snapshot cannot forge directory passes.
    private enum ReconciliationInput {
        case generation(MetadataScanGeneration)
        case legacySnapshot

        var table: String {
            switch self {
            case .generation: return "scan_generation_entries"
            case .legacySnapshot: return "legacy_observation_entries"
            }
        }
    }

    private static func reconciliationAbsenceDate(
        path: String, input: ReconciliationInput, metadata: MetadataSnapshot, connection: SQLiteConnection
    ) throws -> Date {
        switch input {
        case .generation(let generation):
            return try coveredAbsenceDate(path: path, generation: generation, connection: connection)
        case .legacySnapshot:
            // The legacy caller supplies a single coverage observation, not a
            // resumable directory proof. Missing rows still require complete
            // unchanged-scope coverage in the common reconciler.
            return metadata.observedAt
        }
    }

    private static func reconcileObjects(
        metadata: MetadataSnapshot,
        scope: EvidenceScopeVersion,
        previousScopeID: String?,
        input: ReconciliationInput,
        inlineEventLimit: Int?,
        checkpoint: ReconciliationCheckpoint,
        connection: SQLiteConnection
    ) throws -> (events: [EvidenceStoreEvent], count: Int) {
        let observationID = metadata.observationID
        let observedAt = metadata.observedAt
        let scopeChanged = previousScopeID.map { $0 != scope.scopeVersionID } ?? true
        let rootCoverage = Dictionary(uniqueKeysWithValues: metadata.rootCoverage.map { ($0.rootPath, $0) })
        let fallbackSampleDate: Date
        switch input {
        case .generation(let generation): fallbackSampleDate = generation.startedAt
        case .legacySnapshot: fallbackSampleDate = observedAt
        }
        var inlineEvents: [EvidenceStoreEvent] = []
        var persistedEventCount = 0
        // Read all comparisons from an immutable SQL snapshot, not rows
        // already changed by an earlier object. Rebuilding current state
        // inside this transaction also permits path swaps without violating
        // its unique-path constraint. No file-count-sized Swift collection.
        try connection.execute("DROP TABLE IF EXISTS temp.reconcile_prior_current")
        try connection.execute("CREATE TEMP TABLE reconcile_prior_current AS SELECT * FROM current_file_state")
        try connection.execute("CREATE UNIQUE INDEX reconcile_prior_current_object ON reconcile_prior_current(object_id)")
        try connection.execute("CREATE UNIQUE INDEX reconcile_prior_current_path ON reconcile_prior_current(path)")
        try connection.execute("DROP TABLE IF EXISTS temp.reconcile_prior_paths")
        try connection.execute("CREATE TEMP TABLE reconcile_prior_paths AS SELECT DISTINCT object_id, path FROM path_bindings WHERE valid_through IS NULL")
        try connection.execute("CREATE INDEX reconcile_prior_paths_path ON reconcile_prior_paths(path, object_id)")
        try connection.execute("CREATE INDEX reconcile_prior_paths_object ON reconcile_prior_paths(object_id, path)")
        try connection.execute("DELETE FROM current_file_state")
        try connection.execute("DROP TABLE IF EXISTS temp.reconcile_missing_objects")
        try connection.execute(
            "CREATE TEMP TABLE reconcile_missing_objects (object_id TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID"
        )
        try connection.withStatement(
            "INSERT INTO reconcile_missing_objects (object_id) SELECT current.object_id FROM reconcile_prior_current AS current WHERE NOT EXISTS (SELECT 1 FROM \(input.table) AS staged WHERE staged.generation_id = ? AND staged.object_id = current.object_id)"
        ) { statement in
            try connection.bind(observationID, at: 1, in: statement)
            try connection.stepDone(statement)
        }

        try connection.withStatement(
            "SELECT object_id FROM \(input.table) WHERE generation_id = ? GROUP BY object_id ORDER BY object_id"
        ) { objectStatement in
            try connection.bind(observationID, at: 1, in: objectStatement)
            while sqlite3_step(objectStatement) == SQLITE_ROW {
                guard let objectID = Self.columnString(objectStatement, column: 0) else {
                    throw connection.lastError(SQLITE_CORRUPT)
                }
                let oldObject = try Self.readCurrentFile(objectID: objectID, fromPriorSnapshot: true, connection: connection)
                let (file, observedPathCount, observedLinkCount) = try Self.readCanonicalStagedFile(input: input,
                    generationID: observationID,
                    objectID: objectID,
                    preferredPath: oldObject?.path,
                    connection: connection
                )
                let sampledAt = file.observedAt ?? fallbackSampleDate
                guard sampledAt <= observedAt else {
                    throw EvidenceStoreError.invalidObservation("file sample is later than observation publication")
                }
                if let oldObject, sampledAt < oldObject.observedAt {
                    throw EvidenceStoreError.invalidObservation("file sample predates the committed object observation")
                }
                let oldPathObject = try Self.readPriorFileAtPath(file.path, connection: connection)
                let previousPathCount = try Self.openPathCount(objectID: objectID, connection: connection)
                let isMultiLink = max(observedPathCount, observedLinkCount) > 1
                // A scoped-out object's current row may have yielded its old
                // path to another object. Its durable identity still records
                // that the next sighting is scope entry, not creation/growth.
                let historicalScopeExit = try connection.withStatement(
                    "SELECT lifecycle_state FROM file_objects WHERE object_id = ?"
                ) { statement in
                    try connection.bind(objectID, at: 1, in: statement)
                    guard sqlite3_step(statement) == SQLITE_ROW else { return false }
                    return Self.columnString(statement, column: 0) == "out-of-scope"
                }
                try Self.upsertFileObject(file, observedAt: file.observedAt ?? fallbackSampleDate, state: .present, connection: connection)

                let operation: EvidenceStoreEvent.Operation?
                var before: CurrentFileStateRecord?
                if oldObject?.presence == .outOfScope || historicalScopeExit {
                    // Re-entering the watched set starts a fresh comparison
                    // baseline. Changes while scoped out are not monitored
                    // growth, rename or replacement evidence.
                    operation = .scopeEnter
                } else if let oldObject {
                    before = oldObject
                    let metadataChanged = oldObject.logicalBytes != file.logicalBytes
                        || oldObject.allocatedBytes != file.allocatedBytes || oldObject.modifiedAt != file.modifiedAt
                    if oldObject.path != file.path {
                        let oldPathCovered = Self.coverage(for: oldObject.path, scope: scope, rootCoverage: rootCoverage) == .complete
                        if !scopeChanged && oldPathCovered && previousPathCount == 1 && !isMultiLink {
                            operation = .rename
                        } else {
                            operation = metadataChanged ? (file.logicalBytes < oldObject.logicalBytes ? .truncate : .modify) : nil
                        }
                    } else if metadataChanged {
                        operation = file.logicalBytes < oldObject.logicalBytes ? .truncate : .modify
                    } else {
                        operation = nil
                    }
                } else if let replaced = oldPathObject, replaced.objectID != file.objectID {
                    before = replaced
                    operation = .replace
                    // Replacing one path is not proof that every other link
                    // of the old object disappeared. Its own reconciliation
                    // below decides present, unknown, or absent.
                } else {
                    operation = previousScopeID == nil ? .baseline : (scopeChanged ? .scopeEnter : .create)
                }

                try Self.forEachStagedFile(input: input, generationID: observationID, objectID: objectID, connection: connection) { observedFile in
                    let sampledAt = observedFile.observedAt ?? fallbackSampleDate
                    // Aliases may be sampled in different slices. Object
                    // first/last observations span those actual samples;
                    // the canonical metadata keeps its own sample time.
                    try Self.upsertFileObject(observedFile, observedAt: sampledAt, state: .present, connection: connection)
                    if try !Self.hasOpenPathBinding(objectID: objectID, path: observedFile.path, connection: connection) {
                        try Self.openPathBinding(
                            observedFile,
                            at: sampledAt,
                            reason: isMultiLink ? "hard-link-observed" : (operation?.rawValue ?? "observed"),
                            connection: connection
                        )
                    }
                }
                try Self.forEachOpenPath(objectID: objectID, connection: connection) { previousPath in
                    guard try !Self.stagedPathExists(input: input, generationID: observationID, path: previousPath, objectID: objectID, connection: connection) else { return }
                    if !Self.isIncluded(previousPath, in: scope) {
                        try Self.closePathBinding(objectID: objectID, path: previousPath, at: observedAt, reason: "scope-exit", connection: connection)
                    } else if let replacementAt = try Self.stagedReplacementDate(input: input, generationID: observationID, path: previousPath, objectID: objectID, connection: connection) {
                        try Self.closePathBinding(objectID: objectID, path: previousPath, at: replacementAt, reason: "replace", connection: connection)
                    } else if !scopeChanged, Self.coverage(for: previousPath, scope: scope, rootCoverage: rootCoverage) == .complete {
                        let absenceAt = try Self.reconciliationAbsenceDate(path: previousPath, input: input, metadata: metadata, connection: connection)
                        try Self.closePathBinding(
                            objectID: objectID,
                            path: previousPath,
                            at: absenceAt,
                            reason: previousPathCount > 1 || isMultiLink ? "hard-link-removed" : "rename",
                            connection: connection
                        )
                    }
                }

                let survivingPathCount = try Self.openPathCount(objectID: objectID, connection: connection)
                try Self.upsertCurrentFile(
                    file,
                    scope: scope,
                    observationID: observationID,
                    observedAt: file.observedAt ?? fallbackSampleDate,
                    actionable: !isMultiLink && survivingPathCount <= 1,
                    connection: connection
                )
                if let operation {
                    // Current state is authoritative in current_file_state. Historical
                    // state rows exist only at lifecycle changes, so an unchanged scan
                    // does not add file-count × scan-count history.
                    try Self.insertStateObservation(file, observationID: observationID, connection: connection)
                    var operations = [operation]
                    if operation == .rename, let before,
                       before.logicalBytes != file.logicalBytes || before.allocatedBytes != file.allocatedBytes || before.modifiedAt != file.modifiedAt {
                        operations.append(file.logicalBytes < before.logicalBytes ? .truncate : .modify)
                    }
                    for operation in operations {
                        // Replacement is not necessarily one old object to
                        // one new object. This event accounts only for the
                        // incoming object. Each retired object receives its
                        // own negative replacement event in the missing pass.
                        // Rename requires both the new positive observation
                        // and evidence that the old binding is gone. Size
                        // change remains tied to the actual metadata sample.
                        var eventObservedAt = file.observedAt ?? fallbackSampleDate
                        if operation == .rename, let before {
                            eventObservedAt = max(eventObservedAt, try Self.reconciliationAbsenceDate(path: before.path, input: input, metadata: metadata, connection: connection))
                        }
                        let event = Self.makeEvent(operation: operation, file: file, before: before, metadata: metadata,
                            replacementAddition: operation == .replace, observedAt: eventObservedAt)
                        try Self.insertEvent(event, connection: connection)
                        let timedEvent = try Self.insertChangeEvent(event, objectID: objectID, before: before, afterPath: file.path,
                            pathBefore: operation == .replace ? file.path : nil, metadata: metadata, connection: connection)
                        persistedEventCount += 1
                        if inlineEventLimit.map({ inlineEvents.count < $0 }) ?? true { inlineEvents.append(timedEvent) }
                    }
                }
            }
        }
        try checkpoint("after-present-objects")

        try connection.withStatement("SELECT object_id FROM reconcile_missing_objects ORDER BY object_id") { missingStatement in
            while sqlite3_step(missingStatement) == SQLITE_ROW {
                guard let objectID = Self.columnString(missingStatement, column: 0),
                      let old = try Self.readCurrentFile(objectID: objectID, fromPriorSnapshot: true, connection: connection)
                else { continue }
                if old.presence == .outOfScope {
                    // A previously closed scope binding is historical, not
                    // a live object to debit on re-entry (now or next scan).
                    // If its path has a new occupant, retain that history in
                    // file_objects/path_bindings without a conflicting row.
                    let occupied = try Self.stagedReplacementDate(input: input, generationID: observationID,
                        path: old.path, objectID: objectID, connection: connection) != nil
                    if !occupied {
                        try Self.restorePriorCurrent(old, path: old.path, rootPath: old.rootPath,
                            presence: .outOfScope, scope: scope, connection: connection)
                    }
                    continue
                }
                var hasIncludedPath = false
                var uncertainPath: String?
                var hasReplacement = false
                var knownPathCount = 0
                var absenceAt: Date?
                try Self.forEachOpenPath(objectID: objectID, connection: connection) { path in
                    knownPathCount += 1
                    guard Self.isIncluded(path, in: scope) else {
                        try Self.closePathBinding(objectID: objectID, path: path, at: observedAt, reason: "scope-exit", connection: connection)
                        return
                    }
                    hasIncludedPath = true
                    if let replacementAt = try Self.stagedReplacementDate(input: input, generationID: observationID, path: path, objectID: objectID, connection: connection) {
                        hasReplacement = true
                        absenceAt = max(absenceAt ?? replacementAt, replacementAt)
                        try Self.closePathBinding(objectID: objectID, path: path, at: replacementAt, reason: "replace", connection: connection)
                    } else if !scopeChanged, Self.coverage(for: path, scope: scope, rootCoverage: rootCoverage) == .complete {
                        let pathAbsentAt = try Self.reconciliationAbsenceDate(path: path, input: input, metadata: metadata, connection: connection)
                        absenceAt = max(absenceAt ?? pathAbsentAt, pathAbsentAt)
                        try Self.closePathBinding(objectID: objectID, path: path, at: pathAbsentAt, reason: "delete", connection: connection)
                    } else if uncertainPath == nil {
                        uncertainPath = path
                    }
                }
                // Old out-of-scope rows have no open binding. Re-entering
                // scope alone must not make that historical path present.
                if knownPathCount == 0, Self.isIncluded(old.path, in: scope) {
                    hasIncludedPath = true
                    if let replacementAt = try Self.stagedReplacementDate(input: input, generationID: observationID, path: old.path, objectID: objectID, connection: connection) {
                        hasReplacement = true
                        absenceAt = replacementAt
                    } else if scopeChanged || Self.coverage(for: old.path, scope: scope, rootCoverage: rootCoverage) != .complete {
                        uncertainPath = old.path
                    } else {
                        absenceAt = try Self.reconciliationAbsenceDate(path: old.path, input: input, metadata: metadata, connection: connection)
                    }
                }
                if let uncertainPath {
                    let root = scope.rootPaths.filter { uncertainPath.hasPrefix($0 == "/" ? "/" : $0 + "/") }.max { $0.count < $1.count } ?? old.rootPath
                    try Self.restorePriorCurrent(old, path: uncertainPath, rootPath: root, presence: .unknown, scope: scope, connection: connection)
                    continue
                }
                let operation: EvidenceStoreEvent.Operation = hasIncludedPath ? (hasReplacement ? .replace : .delete) : .scopeExit
                if operation == .scopeExit {
                    try Self.restorePriorCurrent(old, path: old.path, rootPath: old.rootPath, presence: .outOfScope, scope: scope, connection: connection)
                    if old.presence == .outOfScope { continue }
                }
                let file = FileMetadata(
                    objectID: old.objectID,
                    identityMethod: old.identityMethod,
                    rootPath: old.rootPath,
                    path: old.path,
                    logicalBytes: operation == .scopeExit ? old.logicalBytes : 0,
                    allocatedBytes: operation == .scopeExit ? old.allocatedBytes : 0,
                    modifiedAt: operation == .scopeExit ? old.modifiedAt : nil
                )
                let eventObservedAt = absenceAt ?? observedAt
                let event = Self.makeEvent(operation: operation, file: file, before: old, metadata: metadata, observedAt: eventObservedAt)
                try Self.insertEvent(event, connection: connection)
                let timedEvent = try Self.insertChangeEvent(event, objectID: objectID, before: old, afterPath: nil, metadata: metadata, connection: connection)
                if operation == .scopeExit {
                    try Self.updateFileObjectState(objectID, state: "out-of-scope", observedAt: observedAt, connection: connection)
                } else {
                    try Self.updateFileObjectState(objectID, state: "deleted", observedAt: eventObservedAt, connection: connection)
                }
                persistedEventCount += 1
                if inlineEventLimit.map({ inlineEvents.count < $0 }) ?? true { inlineEvents.append(timedEvent) }
            }
        }
        try checkpoint("after-missing-objects")

        try connection.execute("DROP TABLE temp.reconcile_missing_objects")
        try connection.execute("DROP TABLE temp.reconcile_prior_current")
        try connection.execute("DROP TABLE temp.reconcile_prior_paths")
        return (inlineEvents, persistedEventCount)
    }

    public func scanCoverageStatus() throws -> EvidenceScanCoverageStatus? {
        let connection = try requireConnection()
        guard let latest = try Self.readScanGeneration(status: nil, connection: connection) else { return nil }
        let active = try Self.readScanGeneration(status: .active, connection: connection)
        let lastCompleteAt = try connection.withStatement(
            "SELECT MAX(g.completed_at) FROM scan_generations g JOIN observation_runs o ON o.observation_id = g.generation_id WHERE g.status = 'completed' AND o.coverage = 'complete'"
        ) { statement -> Date? in
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
        let detailCoverage: String
        if active != nil { detailCoverage = "partial" }
        else if latest.status == .completed {
            if !latest.roots.isEmpty && latest.completedRootCount == 0 { detailCoverage = "unavailable" }
            else { detailCoverage = latest.completedRootCount == latest.rootPaths.count ? "complete" : "partial" }
        }
        else { detailCoverage = "stale" }
        return EvidenceScanCoverageStatus(
            configuredRoots: latest.rootPaths,
            excludedPaths: latest.excludedPaths,
            detailCoverage: detailCoverage,
            activeGeneration: active,
            latestGeneration: latest,
            lastCompleteGenerationAt: lastCompleteAt
        )
    }

    public func scanGenerations(limit: Int = 64) throws -> [MetadataScanGeneration] {
        let connection = try requireConnection()
        return try connection.withStatement(
            "SELECT progress FROM scan_generations ORDER BY updated_at DESC, generation_id DESC LIMIT ?"
        ) { statement in
            try connection.bind(Int64(min(max(limit, 1), 64)), at: 1, in: statement)
            var generations: [MetadataScanGeneration] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw connection.lastError(SQLITE_CORRUPT) }
                let count = Int(sqlite3_column_bytes(statement, 0))
                generations.append(try JSONDecoder().decode(MetadataScanGeneration.self, from: Data(bytes: bytes, count: count)))
            }
            return generations
        }
    }

    public func recordObservation(
        snapshot: StorageSnapshot,
        metadata: MetadataSnapshot,
        scope: EvidenceScopeVersion,
        trigger: EvidenceObservationTrigger,
        eventGap: Bool = false
    ) throws -> ObservationCommitResult {
        let connection = try requireConnection()
        guard metadata.scopeVersionID == scope.scopeVersionID else {
            throw EvidenceStoreError.invalidObservation("metadata and scope version identifiers differ")
        }
        guard Set(metadata.rootCoverage.map(\.rootPath)).count == metadata.rootCoverage.count else {
            throw EvidenceStoreError.invalidObservation("metadata contains duplicate root coverage")
        }

        if try observationExists(metadata.observationID, connection: connection) {
            return ObservationCommitResult(
                observationID: metadata.observationID,
                events: [],
                currentFiles: try readCurrentFiles(connection: connection, includeNonActionable: true),
                coverageGaps: try readCoverageGaps(connection: connection, observationID: metadata.observationID)
            )
        }

        let previousScopeID = try latestScopeVersionID(connection: connection)
        let priorCurrentCount = try connection.scalarInt("SELECT COUNT(*) FROM current_file_state")
        try admit(.publication(stagedRows: Int64(metadata.entries.count), priorCurrentRows: priorCurrentCount))
        let previousObservedAt = try Self.latestCurrentObservationDate(connection: connection)
        let checkpoint = reconciliationCheckpoint
        let observedAt = metadata.observedAt
        let startedAt = metadata.entries.values.reduce(observedAt) { min($0, $1.observedAt ?? observedAt) }
        let hasDurableInvalidation = try hasPendingReconciliation()
        let effectiveEventGap = eventGap || hasDurableInvalidation
        let snapshotPayload = try JSONEncoder().encode(snapshot)
        let rootsJSON = String(data: try JSONEncoder().encode(scope.rootPaths), encoding: .utf8) ?? "[]"
        let exclusionsJSON = String(data: try JSONEncoder().encode(scope.excludedPaths), encoding: .utf8) ?? "[]"
        var events: [EvidenceStoreEvent] = []
        var gaps: [EvidenceCoverageGap] = []

        try connection.transaction {
            try connection.withStatement(
                "INSERT OR IGNORE INTO scope_versions (scope_version_id, effective_at, roots_json, exclusions_json, maximum_entries, maximum_depth) VALUES (?, ?, ?, ?, ?, ?)"
            ) { statement in
                try connection.bind(scope.scopeVersionID, at: 1, in: statement)
                try connection.bind(scope.effectiveAt.timeIntervalSince1970, at: 2, in: statement)
                try connection.bind(rootsJSON, at: 3, in: statement)
                try connection.bind(exclusionsJSON, at: 4, in: statement)
                try connection.bind(Int64(scope.maximumEntries), at: 5, in: statement)
                try connection.bind(Int64(scope.maximumDepth), at: 6, in: statement)
                try connection.stepDone(statement)
            }
            try connection.withStatement(
                "INSERT INTO observation_runs (observation_id, scope_version_id, trigger, started_at, completed_at, coverage, event_gap) VALUES (?, ?, ?, ?, ?, ?, ?)"
            ) { statement in
                try connection.bind(metadata.observationID, at: 1, in: statement)
                try connection.bind(scope.scopeVersionID, at: 2, in: statement)
                try connection.bind(trigger.rawValue, at: 3, in: statement)
                try connection.bind(startedAt.timeIntervalSince1970, at: 4, in: statement)
                try connection.bind(observedAt.timeIntervalSince1970, at: 5, in: statement)
                try connection.bind(metadata.coverage.rawValue, at: 6, in: statement)
                try connection.bind(Int64(effectiveEventGap ? 1 : 0), at: 7, in: statement)
                try connection.stepDone(statement)
            }
            try connection.withStatement(
                "INSERT OR IGNORE INTO snapshots (snapshot_id, observed_at, payload) VALUES (?, ?, ?)"
            ) { statement in
                try connection.bind(snapshot.snapshotID, at: 1, in: statement)
                try connection.bind(observedAt.timeIntervalSince1970, at: 2, in: statement)
                try connection.bind(snapshotPayload, at: 3, in: statement)
                try connection.stepDone(statement)
            }

            for root in metadata.rootCoverage {
                try connection.withStatement(
                    "INSERT INTO observation_roots (observation_id, root_path, coverage, limitations_json) VALUES (?, ?, ?, ?)"
                ) { statement in
                    let limitations = String(data: try JSONEncoder().encode(root.limitations), encoding: .utf8) ?? "[]"
                    try connection.bind(metadata.observationID, at: 1, in: statement)
                    try connection.bind(root.rootPath, at: 2, in: statement)
                    try connection.bind(root.coverage.rawValue, at: 3, in: statement)
                    try connection.bind(limitations, at: 4, in: statement)
                    try connection.stepDone(statement)
                }
                if root.coverage != .complete {
                    let reason = Self.coverageReason(root.limitations, fallback: root.coverage.rawValue)
                    let gap = EvidenceCoverageGap(
                        gapID: "gap-\(metadata.observationID)-\(Self.stableIdentifier(root.rootPath))",
                        observationID: metadata.observationID,
                        rootPath: root.rootPath,
                        reason: reason,
                        startedAt: observedAt,
                        endedAt: nil
                    )
                    gaps.append(gap)
                    try Self.insertCoverageGap(gap, connection: connection)
                } else {
                    try Self.resolveCoverageGaps(rootPath: root.rootPath, endedAt: observedAt, connection: connection)
                }
            }
            if effectiveEventGap {
                let gap = EvidenceCoverageGap(
                    gapID: "gap-\(metadata.observationID)-event-stream",
                    observationID: metadata.observationID,
                    rootPath: "*",
                    reason: "event-drop",
                    startedAt: try Self.earliestOpenInvalidationDate(connection: connection) ?? observedAt,
                    endedAt: nil
                )
                gaps.append(gap)
                try Self.insertCoverageGap(gap, connection: connection)
            } else if metadata.coverage == .complete {
                try Self.resolveCoverageGaps(rootPath: "*", reason: "event-drop", endedAt: observedAt, connection: connection)
            }
            if trigger == .startup, let lastObserved = previousObservedAt, lastObserved < observedAt {
                let gap = EvidenceCoverageGap(
                    gapID: "gap-\(metadata.observationID)-app-offline",
                    observationID: metadata.observationID,
                    rootPath: "*",
                    reason: "app-offline",
                    startedAt: lastObserved,
                    endedAt: observedAt
                )
                gaps.append(gap)
                try Self.insertCoverageGap(gap, connection: connection)
            }

            try checkpoint("after-observation")
            try Self.stageLegacyObservations(metadata, connection: connection)
            events = try Self.reconcileObjects(
                metadata: metadata, scope: scope, previousScopeID: previousScopeID,
                input: .legacySnapshot, inlineEventLimit: nil, checkpoint: checkpoint,
                connection: connection
            ).events
            try checkpoint("before-finalize")
            try connection.execute("DROP TABLE temp.legacy_observation_entries")
        }

        return ObservationCommitResult(
            observationID: metadata.observationID,
            events: events,
            currentFiles: try readCurrentFiles(connection: connection, includeNonActionable: true),
            coverageGaps: gaps
        )
    }

    /// Adapt the legacy, already-materialized snapshot into the indexed input
    /// contract. Do not create scan generations or alter an active scan's rows.
    private static func stageLegacyObservations(_ metadata: MetadataSnapshot, connection: SQLiteConnection) throws {
        try connection.execute("""
            CREATE TEMP TABLE legacy_observation_entries (
                generation_id TEXT NOT NULL, object_id TEXT NOT NULL, identity_method TEXT NOT NULL,
                root_path TEXT NOT NULL, path TEXT PRIMARY KEY NOT NULL, logical_bytes INTEGER NOT NULL,
                allocated_bytes INTEGER NOT NULL, modified_at REAL, link_count INTEGER NOT NULL,
                payload BLOB NOT NULL, observed_at REAL NOT NULL
            ) WITHOUT ROWID
            """)
        try connection.execute("CREATE INDEX legacy_observation_objects ON legacy_observation_entries(generation_id, object_id, path)")
        for entry in metadata.entries.values {
            let file = FileMetadata(
                objectID: entry.objectID, identityMethod: entry.identityMethod, rootPath: entry.rootPath,
                path: entry.path, logicalBytes: entry.logicalBytes, allocatedBytes: entry.allocatedBytes,
                modifiedAt: entry.modifiedAt, linkCount: entry.linkCount,
                observedAt: entry.observedAt ?? metadata.observedAt
            )
            try connection.withStatement("""
                INSERT INTO legacy_observation_entries
                (generation_id, object_id, identity_method, root_path, path, logical_bytes,
                 allocated_bytes, modified_at, link_count, payload, observed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """) { statement in
                try connection.bind(metadata.observationID, at: 1, in: statement)
                try connection.bind(file.objectID, at: 2, in: statement)
                try connection.bind(file.identityMethod.rawValue, at: 3, in: statement)
                try connection.bind(file.rootPath, at: 4, in: statement)
                try connection.bind(file.path, at: 5, in: statement)
                try connection.bind(file.logicalBytes, at: 6, in: statement)
                try connection.bind(file.allocatedBytes, at: 7, in: statement)
                try connection.bind(file.modifiedAt?.timeIntervalSince1970, at: 8, in: statement)
                try connection.bind(Int64(file.linkCount), at: 9, in: statement)
                try connection.bind(JSONEncoder().encode(file), at: 10, in: statement)
                try connection.bind(file.observedAt?.timeIntervalSince1970, at: 11, in: statement)
                try connection.stepDone(statement)
            }
        }
    }

    public func currentFiles(includeNonActionable: Bool = false) throws -> [CurrentFileStateRecord] {
        try readCurrentFiles(connection: requireConnection(), includeNonActionable: includeNonActionable)
    }

    public func coverageGaps(observationID: String? = nil) throws -> [EvidenceCoverageGap] {
        try readCoverageGaps(connection: requireConnection(), observationID: observationID)
    }

    public func recordFSEvents(_ batch: TargetedChangeBatch, observationID: String) throws {
        let connection = try requireConnection()
        try admit(.generic(bytes: Int64(batch.hints.count * 512 + 512)))
        guard try observationExists(observationID, connection: connection) else {
            throw EvidenceStoreError.invalidObservation("FSEvents hints require an existing observation run")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let limitations = try encoder.encode(batch.limitations)
        let gapObservedAt = batch.hints.map(\.observedAt).min() ?? dateSource()
        try connection.transaction {
            // Hints identify replayable receipts. A hint-free loss signal has
            // no receipt identity and must conservatively remain a new signal.
            var hasNewGapEvidence = batch.hints.isEmpty
            for hint in batch.hints {
                let hintID = "fsevent:\(observationID):\(hint.eventID):\(Self.stableIdentifier(hint.path))"
                let signals = try encoder.encode(hint.signals)
                var gapRecorded = false
                let existing = try connection.withStatement(
                    "SELECT event_id, observed_at, path, kind, raw_flags, requires_rescan, signals_json, limitations_json, gap_recorded FROM fsevent_hints WHERE hint_id = ?"
                ) { statement -> PersistedFSEventHint? in
                    try connection.bind(hintID, at: 1, in: statement)
                    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                    guard let path = Self.columnString(statement, column: 2),
                          let kindText = Self.columnString(statement, column: 3),
                          let kind = TargetedChangeHint.Kind(rawValue: kindText)
                    else { throw connection.lastError(SQLITE_CORRUPT) }
                    gapRecorded = sqlite3_column_int64(statement, 8) != 0
                    return .init(
                        hintID: hintID,
                        observationID: observationID,
                        hint: .init(
                            path: path,
                            eventID: UInt64(bitPattern: sqlite3_column_int64(statement, 0)),
                            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                            kind: kind,
                            requiresRescan: sqlite3_column_int64(statement, 5) != 0,
                            rawFlags: UInt32(truncatingIfNeeded: sqlite3_column_int64(statement, 4)),
                            signals: try Self.decodeStringArray(statement, column: 6, connection: connection)
                        ),
                        limitations: try Self.decodeStringArray(statement, column: 7, connection: connection)
                    )
                }
                let candidate = PersistedFSEventHint(
                    hintID: hintID,
                    observationID: observationID,
                    hint: hint,
                    limitations: batch.limitations
                )
                if let existing {
                    guard existing == candidate else {
                        throw EvidenceStoreError.invalidObservation("FSEvents hint identifier was reused with different evidence")
                    }
                    if batch.eventGap && !gapRecorded {
                        hasNewGapEvidence = true
                        try connection.withStatement("UPDATE fsevent_hints SET gap_recorded = 1 WHERE hint_id = ?") { statement in
                            try connection.bind(hintID, at: 1, in: statement)
                            try connection.stepDone(statement)
                        }
                    }
                    continue
                }
                try connection.withStatement(
                    "INSERT OR IGNORE INTO fsevent_hints (hint_id, observation_id, event_id, observed_at, path, kind, raw_flags, requires_rescan, signals_json, limitations_json, gap_recorded) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                ) { statement in
                    try connection.bind(hintID, at: 1, in: statement)
                    try connection.bind(observationID, at: 2, in: statement)
                    try connection.bind(Int64(bitPattern: hint.eventID), at: 3, in: statement)
                    try connection.bind(hint.observedAt.timeIntervalSince1970, at: 4, in: statement)
                    try connection.bind(hint.path, at: 5, in: statement)
                    try connection.bind(hint.kind.rawValue, at: 6, in: statement)
                    try connection.bind(Int64(hint.rawFlags), at: 7, in: statement)
                    try connection.bind(Int64(hint.requiresRescan ? 1 : 0), at: 8, in: statement)
                    try connection.bind(signals, at: 9, in: statement)
                    try connection.bind(limitations, at: 10, in: statement)
                    try connection.bind(Int64(batch.eventGap ? 1 : 0), at: 11, in: statement)
                    try connection.stepDone(statement)
                }
                if batch.eventGap { hasNewGapEvidence = true }
            }
            if batch.eventGap && hasNewGapEvidence {
                try Self.upsertReconciliationInvalidation(
                    rootPath: "*",
                    reason: "event-drop",
                    at: gapObservedAt,
                    connection: connection
                )
            }
        }
    }

    public func fseventHints(observationID: String) throws -> [PersistedFSEventHint] {
        let connection = try requireConnection()
        return try connection.withStatement(
            "SELECT hint_id, event_id, observed_at, path, kind, raw_flags, requires_rescan, signals_json, limitations_json FROM fsevent_hints WHERE observation_id = ? ORDER BY event_id, hint_id"
        ) { statement in
            try connection.bind(observationID, at: 1, in: statement)
            var values: [PersistedFSEventHint] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let hintID = sqlite3_column_text(statement, 0),
                      let path = sqlite3_column_text(statement, 3),
                      let kindText = sqlite3_column_text(statement, 4),
                      let kind = TargetedChangeHint.Kind(rawValue: String(cString: kindText))
                else { throw connection.lastError(SQLITE_CORRUPT) }
                let signals = try Self.decodeStringArray(statement, column: 7, connection: connection)
                let limitations = try Self.decodeStringArray(statement, column: 8, connection: connection)
                values.append(.init(
                    hintID: String(cString: hintID),
                    observationID: observationID,
                    hint: .init(
                        path: String(cString: path),
                        eventID: UInt64(bitPattern: sqlite3_column_int64(statement, 1)),
                        observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                        kind: kind,
                        requiresRescan: sqlite3_column_int64(statement, 6) != 0,
                        rawFlags: UInt32(truncatingIfNeeded: sqlite3_column_int64(statement, 5)),
                        signals: signals
                    ),
                    limitations: limitations
                ))
            }
            return values
        }
    }

    public func recordEndpointObservation(
        _ event: NormalizedPrivilegedEvent,
        observationID: String? = nil,
        evidenceEventID: String? = nil
    ) throws {
        let connection = try requireConnection()
        try admit(.generic(bytes: 2_048))
        if let observationID, !(try observationExists(observationID, connection: connection)) {
            throw EvidenceStoreError.invalidObservation("Endpoint evidence references an unknown observation run")
        }
        if let evidenceEventID, !(try containsEvent(id: evidenceEventID)) {
            throw EvidenceStoreError.invalidEvent("Endpoint evidence references an unknown event")
        }
        let payload = try JSONEncoder().encode(event)
        let existing = try connection.withStatement(
            "SELECT observation_id, evidence_event_id, payload FROM endpoint_observations WHERE endpoint_id = ?"
        ) { statement -> PersistedEndpointObservation? in
            try connection.bind(event.raw.eventID, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return .init(
                observationID: Self.columnString(statement, column: 0),
                evidenceEventID: Self.columnString(statement, column: 1),
                event: try JSONDecoder().decode(
                    NormalizedPrivilegedEvent.self,
                    from: Self.columnData(statement, column: 2, connection: connection)
                )
            )
        }
        if let existing {
            guard existing == .init(observationID: observationID, evidenceEventID: evidenceEventID, event: event) else {
                throw EvidenceStoreError.invalidEvent("Endpoint event identifier was reused with different evidence")
            }
            return
        }
        try connection.withStatement(
            "INSERT OR IGNORE INTO endpoint_observations (endpoint_id, observation_id, evidence_event_id, observed_at, payload) VALUES (?, ?, ?, ?, ?)"
        ) { statement in
            try connection.bind(event.raw.eventID, at: 1, in: statement)
            try connection.bind(observationID, at: 2, in: statement)
            try connection.bind(evidenceEventID, at: 3, in: statement)
            try connection.bind(event.raw.observedAt.timeIntervalSince1970, at: 4, in: statement)
            try connection.bind(payload, at: 5, in: statement)
            try connection.stepDone(statement)
        }
    }

    public func endpointObservations(evidenceEventID: String? = nil) throws -> [PersistedEndpointObservation] {
        let connection = try requireConnection()
        let sql = evidenceEventID == nil
            ? "SELECT observation_id, evidence_event_id, payload FROM endpoint_observations ORDER BY observed_at, endpoint_id"
            : "SELECT observation_id, evidence_event_id, payload FROM endpoint_observations WHERE evidence_event_id = ? ORDER BY observed_at, endpoint_id"
        return try connection.withStatement(sql) { statement in
            if let evidenceEventID { try connection.bind(evidenceEventID, at: 1, in: statement) }
            var values: [PersistedEndpointObservation] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let payload = try Self.columnData(statement, column: 2, connection: connection)
                values.append(.init(
                    observationID: Self.columnString(statement, column: 0),
                    evidenceEventID: Self.columnString(statement, column: 1),
                    event: try JSONDecoder().decode(NormalizedPrivilegedEvent.self, from: payload)
                ))
            }
            return values
        }
    }

    public func persistProvenanceClaim(_ claim: ProvenanceClaim) throws {
        let connection = try requireConnection()
        try admit(.generic(bytes: 4_096))
        guard try containsEvent(id: claim.event.eventID) else {
            throw EvidenceStoreError.invalidEvent("Provenance claim references an unknown event")
        }
        guard claim.hasValidChronology else {
            throw EvidenceStoreError.invalidEvent("Provenance chronology is invalid")
        }
        let claimEncoder = JSONEncoder()
        claimEncoder.outputFormatting = [.sortedKeys]
        let payload = try claimEncoder.encode(claim)
        let existingPayload = try connection.withStatement(
            "SELECT payload FROM provenance_claims WHERE claim_id = ?"
        ) { statement -> Data? in
            try connection.bind(claim.claimID, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try Self.columnData(statement, column: 0, connection: connection)
        }
        if let existingPayload {
            guard existingPayload == payload else {
                throw EvidenceStoreError.invalidEvent("Provenance claim identifier was reused with different evidence")
            }
            return
        }
        try connection.transaction {
            if let priorID = claim.supersedesClaimID {
                guard priorID != claim.claimID else {
                    throw EvidenceStoreError.invalidEvent("A provenance claim cannot supersede itself")
                }
                let prior = try connection.withStatement(
                    "SELECT event_id, superseded_by_claim_id FROM provenance_claims WHERE claim_id = ?"
                ) { statement -> (eventID: String, supersededBy: String?)? in
                    try connection.bind(priorID, at: 1, in: statement)
                    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                    guard let eventID = Self.columnString(statement, column: 0) else {
                        throw connection.lastError(SQLITE_CORRUPT)
                    }
                    return (eventID, Self.columnString(statement, column: 1))
                }
                guard prior?.eventID == claim.event.eventID else {
                    throw EvidenceStoreError.invalidEvent("Superseded provenance must describe the same evidence event")
                }
                guard prior?.supersededBy == nil || prior?.supersededBy == claim.claimID else {
                    throw EvidenceStoreError.invalidEvent("A provenance claim cannot have multiple superseding successors")
                }
            }
            try connection.withStatement(
                "INSERT OR IGNORE INTO provenance_claims (claim_id, event_id, method, confidence, detected_at, occurred_start, occurred_end, session_registration_id, supersedes_claim_id, superseded_by_claim_id, payload, timing_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)"
            ) { statement in
                try connection.bind(claim.claimID, at: 1, in: statement)
                try connection.bind(claim.event.eventID, at: 2, in: statement)
                try connection.bind(claim.method, at: 3, in: statement)
                try connection.bind(claim.confidence.rawValue, at: 4, in: statement)
                try connection.bind(claim.detectedAt.timeIntervalSince1970, at: 5, in: statement)
                try connection.bind(claim.occurredStart?.timeIntervalSince1970, at: 6, in: statement)
                try connection.bind(claim.occurredEnd.timeIntervalSince1970, at: 7, in: statement)
                try connection.bind(claim.session?.registrationID.uuidString.lowercased(), at: 8, in: statement)
                try connection.bind(claim.supersedesClaimID, at: 9, in: statement)
                try connection.bind(payload, at: 10, in: statement)
                try connection.bind(Int64(claim.timingBasis == "legacy-unverified" ? 0 : 1), at: 11, in: statement)
                try connection.stepDone(statement)
            }
            if let priorID = claim.supersedesClaimID {
                try connection.withStatement(
                    "UPDATE provenance_claims SET superseded_by_claim_id = ? WHERE claim_id = ? AND (superseded_by_claim_id IS NULL OR superseded_by_claim_id = ?)"
                ) { statement in
                    try connection.bind(claim.claimID, at: 1, in: statement)
                    try connection.bind(priorID, at: 2, in: statement)
                    try connection.bind(claim.claimID, at: 3, in: statement)
                    try connection.stepDone(statement)
                }
            }
        }
    }

    public func provenanceClaims(eventID: String? = nil, includeSuperseded: Bool = true) throws -> [ProvenanceClaim] {
        let connection = try requireConnection()
        var predicates: [String] = []
        if eventID != nil { predicates.append("event_id = ?") }
        if !includeSuperseded { predicates.append("superseded_by_claim_id IS NULL") }
        let suffix = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        return try connection.withStatement(
            "SELECT payload, superseded_by_claim_id FROM provenance_claims\(suffix) ORDER BY detected_at, claim_id"
        ) { statement in
            if let eventID { try connection.bind(eventID, at: 1, in: statement) }
            var values: [ProvenanceClaim] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let stored = try JSONDecoder().decode(
                    ProvenanceClaim.self,
                    from: Self.columnData(statement, column: 0, connection: connection)
                )
                values.append(Self.copy(stored, supersededByClaimID: Self.columnString(statement, column: 1)))
            }
            return values
        }
    }

    public func persistAgentSession(_ registration: AgentSessionRegistration) throws {
        let connection = try requireConnection()
        try admit(.generic(bytes: 2_048))
        guard registration.registeredAt <= registration.lastHeartbeatAt,
              registration.lastHeartbeatAt <= registration.expiresAt,
              registration.endedAt.map({ $0 >= registration.lastHeartbeatAt && $0 <= registration.expiresAt }) ?? true
        else { throw EvidenceStoreError.invalidObservation("Agent session timestamps are inconsistent") }
        let id = registration.registrationID.uuidString.lowercased()
        if let prior = try agentSession(id: registration.registrationID) {
            guard prior.client == registration.client,
                  prior.sessionID == registration.sessionID,
                  prior.process == registration.process,
                  prior.workspaceRoots == registration.workspaceRoots,
                  prior.registeredAt == registration.registeredAt,
                  prior.authentication == registration.authentication,
                  prior.taskContext == registration.taskContext
            else { throw EvidenceStoreError.invalidObservation("Agent session identity is immutable") }
            if prior.lifecycle != .active {
                guard registration == prior else {
                    throw EvidenceStoreError.invalidObservation("A terminal agent session is immutable")
                }
            }
            guard registration.lastHeartbeatAt >= prior.lastHeartbeatAt else {
                throw EvidenceStoreError.invalidObservation("Agent session heartbeat cannot move backward")
            }
            guard registration.expiresAt >= prior.expiresAt else {
                throw EvidenceStoreError.invalidObservation("Agent session expiry cannot move backward")
            }
        }
        guard (registration.lifecycle == .active) == (registration.endedAt == nil) else {
            throw EvidenceStoreError.invalidObservation("Only active agent sessions may omit ended_at")
        }
        let payload = try JSONEncoder().encode(registration)
        try connection.withStatement(
            "INSERT INTO agent_sessions (registration_id, session_id, client, registered_at, heartbeat_at, expires_at, ended_at, lifecycle, task_context, payload) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(registration_id) DO UPDATE SET heartbeat_at = excluded.heartbeat_at, expires_at = excluded.expires_at, ended_at = excluded.ended_at, lifecycle = excluded.lifecycle, task_context = excluded.task_context, payload = excluded.payload"
        ) { statement in
            try connection.bind(id, at: 1, in: statement)
            try connection.bind(registration.sessionID, at: 2, in: statement)
            try connection.bind(registration.client.rawValue, at: 3, in: statement)
            try connection.bind(registration.registeredAt.timeIntervalSince1970, at: 4, in: statement)
            try connection.bind(registration.lastHeartbeatAt.timeIntervalSince1970, at: 5, in: statement)
            try connection.bind(registration.expiresAt.timeIntervalSince1970, at: 6, in: statement)
            try connection.bind(registration.endedAt?.timeIntervalSince1970, at: 7, in: statement)
            try connection.bind(registration.lifecycle.rawValue, at: 8, in: statement)
            try connection.bind(registration.taskContext, at: 9, in: statement)
            try connection.bind(payload, at: 10, in: statement)
            try connection.stepDone(statement)
        }
    }

    public func agentSessions(sessionID: String? = nil) throws -> [AgentSessionRegistration] {
        let connection = try requireConnection()
        let sql = sessionID == nil
            ? "SELECT payload FROM agent_sessions ORDER BY registered_at, registration_id"
            : "SELECT payload FROM agent_sessions WHERE session_id = ? ORDER BY registered_at, registration_id"
        return try connection.withStatement(sql) { statement in
            if let sessionID { try connection.bind(sessionID, at: 1, in: statement) }
            var values: [AgentSessionRegistration] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(try JSONDecoder().decode(
                    AgentSessionRegistration.self,
                    from: Self.columnData(statement, column: 0, connection: connection)
                ))
            }
            return values
        }
    }

    public func agentSession(id: UUID) throws -> AgentSessionRegistration? {
        let connection = try requireConnection()
        return try connection.withStatement("SELECT payload FROM agent_sessions WHERE registration_id = ?") { statement in
            try connection.bind(id.uuidString.lowercased(), at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try JSONDecoder().decode(
                AgentSessionRegistration.self,
                from: Self.columnData(statement, column: 0, connection: connection)
            )
        }
    }

    public func recordSnapshot(_ snapshot: StorageSnapshot, observedAt: Date) throws {
        let connection = try requireConnection()
        let payload = try JSONEncoder().encode(snapshot)
        try admit(.generic(bytes: Int64(payload.count + 512)))
        try connection.withStatement(
            "INSERT INTO snapshots (snapshot_id, observed_at, payload) VALUES (?, ?, ?)"
        ) { statement in
            try connection.bind(snapshot.snapshotID, at: 1, in: statement)
            try connection.bind(observedAt.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(payload, at: 3, in: statement)
            try connection.stepDone(statement)
        }
    }

    public func eventCount() throws -> Int {
        Int(try requireConnection().scalarInt("SELECT COUNT(*) FROM events"))
    }

    public func containsEvent(id: String) throws -> Bool {
        let connection = try requireConnection()
        return try connection.withStatement("SELECT 1 FROM events WHERE event_id = ? LIMIT 1") { statement in
            try connection.bind(id, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    public func summaries(hourly: Bool) throws -> [EvidenceSummary] {
        let connection = try requireConnection()
        let table = hourly ? "hourly_summaries" : "daily_summaries"
        return try connection.withStatement(
            "SELECT bucket_start, path, operation, event_count, logical_delta, allocated_delta FROM \(table) ORDER BY bucket_start, path, operation"
        ) { statement in
            var results: [EvidenceSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pathText = sqlite3_column_text(statement, 1),
                      let operationText = sqlite3_column_text(statement, 2),
                      let operation = EvidenceStoreEvent.Operation(rawValue: String(cString: operationText))
                else { throw connection.lastError(SQLITE_CORRUPT) }
                results.append(
                    EvidenceSummary(
                        bucketStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                        path: String(cString: pathText),
                        operation: operation,
                        eventCount: Int(sqlite3_column_int64(statement, 3)),
                        logicalDelta: sqlite3_column_int64(statement, 4),
                        allocatedDelta: sqlite3_column_int64(statement, 5)
                    )
                )
            }
            return results
        }
    }

    /// `demandBytes` is the demand of a refusal the caller holds; retention
    /// targets the largest of it, any demand refused since the last run, the
    /// publication reserve and a fixed margin.
    public func applyRetention(
        _ policy: EvidenceStoreRetentionPolicy,
        trigger: RetentionTrigger = .scheduled,
        demandBytes: Int64 = 0
    ) throws -> RetentionReport {
        let connection = try requireConnection()
        storageCapBytes = policy.maxDatabaseBytes
        let startedAt = dateSource()
        let now = startedAt.timeIntervalSince1970
        let rawCutoff = now - Double(policy.rawEventDays * 86_400)
        let anomalyCutoff = now - Double(policy.anomalyDetailDays * 86_400)
        let hourlyCutoff = now - Double(policy.hourlySummaryDays * 86_400)
        let dailyCutoff = now - Double(policy.dailySummaryDays * 86_400)
        let runID = "retention-\(UUID().uuidString.lowercased())"
        let bytesBefore = storageBytes()
        var rawAggregated = 0
        var hourlyAggregated = 0
        var dailyDeleted = 0
        var snapshotsDeleted = 0
        var historicalRowsDeleted = 0
        var forcedEvictions = 0
        var limitations: [String] = []

        try insertRetentionRun(
            id: runID,
            trigger: trigger,
            policy: policy,
            startedAt: startedAt,
            storageBytesBefore: bytesBefore,
            connection: connection
        )

        do {
            try connection.transaction {
                let retentionBatchLimit = 10_000
                let rawPredicate = policy.preserveUnreviewedAnomalies
                    ? "observed_at < \(rawCutoff) AND (is_anomaly = 0 OR is_reviewed = 1 OR observed_at < \(anomalyCutoff))"
                    : "observed_at < \(rawCutoff)"
                try connection.execute("DROP TABLE IF EXISTS temp.retention_event_batch")
                try connection.execute("CREATE TEMP TABLE retention_event_batch (row_id INTEGER PRIMARY KEY) WITHOUT ROWID")
                try connection.execute(
                    "INSERT INTO retention_event_batch (row_id) SELECT rowid FROM events WHERE \(rawPredicate) ORDER BY observed_at, event_id LIMIT \(retentionBatchLimit)"
                )
                rawAggregated = Int(try connection.scalarInt("SELECT COUNT(*) FROM retention_event_batch"))
                try connection.execute(
                    """
                    INSERT INTO hourly_summaries (bucket_start, path, operation, event_count, logical_delta, allocated_delta)
                    SELECT CAST(observed_at / 3600 AS INTEGER) * 3600, path, operation, COUNT(*), SUM(logical_delta), SUM(allocated_delta)
                    FROM events WHERE rowid IN (SELECT row_id FROM retention_event_batch)
                    GROUP BY CAST(observed_at / 3600 AS INTEGER), path, operation
                    ON CONFLICT(bucket_start, path, operation) DO UPDATE SET
                        event_count = event_count + excluded.event_count,
                        logical_delta = logical_delta + excluded.logical_delta,
                        allocated_delta = allocated_delta + excluded.allocated_delta
                    """
                )
                try connection.execute("DELETE FROM events WHERE rowid IN (SELECT row_id FROM retention_event_batch)")
                try connection.execute("DROP TABLE retention_event_batch")
                if try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM events WHERE \(rawPredicate))") != 0 {
                    limitations.append("Raw-event retention stopped after a bounded 10,000-row batch; the next retention run will continue.")
                }

                try connection.execute("DROP TABLE IF EXISTS temp.retention_hourly_batch")
                try connection.execute("CREATE TEMP TABLE retention_hourly_batch (row_id INTEGER PRIMARY KEY) WITHOUT ROWID")
                try connection.execute(
                    "INSERT INTO retention_hourly_batch (row_id) SELECT rowid FROM hourly_summaries WHERE bucket_start < \(hourlyCutoff) ORDER BY bucket_start, path, operation LIMIT \(retentionBatchLimit)"
                )
                hourlyAggregated = Int(try connection.scalarInt("SELECT COUNT(*) FROM retention_hourly_batch"))
                try connection.execute(
                    """
                    INSERT INTO daily_summaries (bucket_start, path, operation, event_count, logical_delta, allocated_delta)
                    SELECT CAST(bucket_start / 86400 AS INTEGER) * 86400, path, operation, SUM(event_count), SUM(logical_delta), SUM(allocated_delta)
                    FROM hourly_summaries WHERE rowid IN (SELECT row_id FROM retention_hourly_batch)
                    GROUP BY CAST(bucket_start / 86400 AS INTEGER), path, operation
                    ON CONFLICT(bucket_start, path, operation) DO UPDATE SET
                        event_count = event_count + excluded.event_count,
                        logical_delta = logical_delta + excluded.logical_delta,
                        allocated_delta = allocated_delta + excluded.allocated_delta
                    """
                )
                try connection.execute("DELETE FROM hourly_summaries WHERE rowid IN (SELECT row_id FROM retention_hourly_batch)")
                try connection.execute("DROP TABLE retention_hourly_batch")
                if try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM hourly_summaries WHERE bucket_start < \(hourlyCutoff))") != 0 {
                    limitations.append("Hourly retention stopped after a bounded 10,000-row batch; the next retention run will continue.")
                }
                let dailyBefore = try connection.scalarInt("SELECT COUNT(*) FROM daily_summaries")
                try connection.execute(
                    "DELETE FROM daily_summaries WHERE rowid IN (SELECT rowid FROM daily_summaries WHERE bucket_start < \(dailyCutoff) ORDER BY bucket_start, path, operation LIMIT \(retentionBatchLimit))"
                )
                dailyDeleted = Int(dailyBefore - (try connection.scalarInt("SELECT COUNT(*) FROM daily_summaries")))
                if try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM daily_summaries WHERE bucket_start < \(dailyCutoff))") != 0 {
                    limitations.append("Daily retention stopped after a bounded 10,000-row batch; the next retention run will continue.")
                }
                snapshotsDeleted = try Self.downsampleSnapshots(
                    rawCutoff: rawCutoff,
                    hourlyCutoff: hourlyCutoff,
                    dailyCutoff: dailyCutoff,
                    connection: connection
                )
                historicalRowsDeleted = try Self.compactDetailedHistory(
                    rawCutoff: rawCutoff,
                    dailyCutoff: dailyCutoff,
                    connection: connection
                )
            }

            try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try retentionCheckpoint("after-tier-compaction")
            var recordedForcedLoss = false
            var evictionBatches = 0
            let capacityEvictionBatchLimit = 10_000
            let maximumEvictionBatches = 8
            // The target leaves room for the last refused write and for
            // publishing whatever is staged, not just a fixed margin.
            let staged = try storageAccounting(connection: connection, capBytes: policy.maxDatabaseBytes, probeCheckpoint: false)
            let demand = max(min(16 * 1_024 * 1_024, policy.maxDatabaseBytes / 10), max(0, demandBytes), pendingStorageDemandBytes,
                             staged.reservedPublicationBytes + staged.nextWorkReserveBytes)
            pendingStorageDemandBytes = 0
            let admissionTarget = policy.maxDatabaseBytes - demand
            // Judged on the same live-plus-log bytes that admission counts, so
            // a refused demand always makes this loop evict when history exists.
            while try reclaimableStorageBytes(connection: connection) > admissionTarget,
                  evictionBatches < maximumEvictionBatches
            {
                guard try hasEvictableHistory(connection: connection) else { break }
                if !recordedForcedLoss {
                    try insertRetentionGap(runID: runID, at: startedAt, connection: connection)
                    recordedForcedLoss = true
                }
                let removed = try evictOldestBatch(limit: capacityEvictionBatchLimit)
                forcedEvictions += removed
                evictionBatches += 1
                try updateRetentionGap(runID: runID, rowsRemoved: forcedEvictions, connection: connection)
                guard removed > 0 else { break }
                try retentionCheckpoint("after-eviction-batch")
                try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            }
            if evictionBatches == maximumEvictionBatches,
               try reclaimableStorageBytes(connection: connection) > admissionTarget
            {
                limitations.append("Capacity eviction stopped after 8 bounded batches; a later pressure retention run will continue the work.")
            }
            // Compact at most once per retention run. Repeated VACUUM operations can
            // transiently double disk use and were a second resource-amplification path.
            if forcedEvictions > 0 || rawAggregated > 0 || hourlyAggregated > 0 || dailyDeleted > 0 || snapshotsDeleted > 0 || historicalRowsDeleted > 0 {
                let requiredCapacity = storageBytes() * 2 + 1_024 * 1_024
                if let available = availableCapacitySource(databaseURL), available >= requiredCapacity {
                    try connection.execute("VACUUM")
                    try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                } else {
                    limitations.append("Physical compaction deferred: available temporary disk headroom is insufficient or unknown. Freed database pages remain reusable.")
                }
            }
            let bytes = storageBytes()
            if bytes > policy.maxDatabaseBytes {
                limitations.append("The database remains above its cap because no evictable history remains; live current-state truth was preserved.")
            }
            let completedAt = dateSource()
            try finishRetentionRun(
                id: runID,
                completedAt: completedAt,
                storageBytesAfter: bytes,
                rawAggregated: rawAggregated,
                hourlyAggregated: hourlyAggregated,
                dailyDeleted: dailyDeleted,
                snapshotsDeleted: snapshotsDeleted,
                historicalRowsDeleted: historicalRowsDeleted,
                forcedEvictions: forcedEvictions,
                result: .completed,
                limitations: limitations,
                connection: connection
            )
            return RetentionReport(
                runID: runID,
                trigger: trigger,
                startedAt: startedAt,
                completedAt: completedAt,
                storageBytesBefore: bytesBefore,
                aggregatedRawEvents: rawAggregated,
                aggregatedHourlySummaries: hourlyAggregated,
                deletedDailySummaries: dailyDeleted,
                deletedSnapshots: snapshotsDeleted,
                deletedHistoricalRows: historicalRowsDeleted,
                forcedEvictions: forcedEvictions,
                storageBytes: bytes,
                limitations: limitations
            )
        } catch {
            try? finishRetentionRun(
                id: runID,
                completedAt: dateSource(),
                storageBytesAfter: storageBytes(),
                rawAggregated: rawAggregated,
                hourlyAggregated: hourlyAggregated,
                dailyDeleted: dailyDeleted,
                snapshotsDeleted: snapshotsDeleted,
                historicalRowsDeleted: historicalRowsDeleted,
                forcedEvictions: forcedEvictions,
                result: .failed,
                limitations: [error.localizedDescription],
                connection: connection
            )
            throw error
        }
    }

    public func backup(to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try requireConnection().backup(to: destination)
    }

    public func integrityCheck() throws -> String {
        try requireConnection().scalarText("PRAGMA quick_check")
    }

    public func diagnostics() throws -> EvidenceStoreDiagnostics {
        let connection = try requireConnection()
        let databaseFileBytes = fileSize(atPath: databaseURL.path)
        let walBytes = fileSize(atPath: databaseURL.path + "-wal")
        let sharedMemoryBytes = fileSize(atPath: databaseURL.path + "-shm")
        return EvidenceStoreDiagnostics(
            schemaVersion: Int(try connection.scalarInt("PRAGMA user_version")),
            journalMode: try connection.scalarText("PRAGMA journal_mode"),
            integrity: try integrityCheck(),
            eventCount: try eventCount(),
            snapshotCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM snapshots")),
            hourlySummaryCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM hourly_summaries")),
            dailySummaryCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM daily_summaries")),
            storageBytes: databaseFileBytes + walBytes + sharedMemoryBytes,
            databaseFileBytes: databaseFileBytes,
            walBytes: walBytes,
            sharedMemoryBytes: sharedMemoryBytes,
            observationCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM observation_runs")),
            currentFileCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM current_file_state WHERE presence = 'present'")),
            fileStateObservationCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM file_state_observations")),
            coverageGapCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM coverage_gaps")),
            retentionRunCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM retention_runs")),
            exportRecordCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM export_records"))
        )
    }

    public func retentionRuns(limit: Int = 100) throws -> [RetentionRunRecord] {
        let connection = try requireConnection()
        return try connection.withStatement(
            "SELECT run_id, trigger, started_at, completed_at, storage_bytes_before, storage_bytes_after, aggregated_raw_events, aggregated_hourly_summaries, deleted_daily_summaries, deleted_snapshots, deleted_historical_rows, forced_evictions, result, limitations FROM retention_runs ORDER BY started_at DESC, run_id DESC LIMIT ?"
        ) { statement in
            try connection.bind(Int64(min(max(limit, 1), 1_000)), at: 1, in: statement)
            var values: [RetentionRunRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let runID = Self.columnString(statement, column: 0),
                      let triggerText = Self.columnString(statement, column: 1),
                      let trigger = RetentionTrigger(rawValue: triggerText),
                      let resultText = Self.columnString(statement, column: 12),
                      let result = RetentionRunResult(rawValue: resultText)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    runID: runID,
                    trigger: trigger,
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    completedAt: Self.columnDate(statement, column: 3),
                    storageBytesBefore: sqlite3_column_int64(statement, 4),
                    storageBytesAfter: Self.columnInt64(statement, column: 5),
                    aggregatedRawEvents: Int(sqlite3_column_int64(statement, 6)),
                    aggregatedHourlySummaries: Int(sqlite3_column_int64(statement, 7)),
                    deletedDailySummaries: Int(sqlite3_column_int64(statement, 8)),
                    deletedSnapshots: Int(sqlite3_column_int64(statement, 9)),
                    deletedHistoricalRows: Int(sqlite3_column_int64(statement, 10)),
                    forcedEvictions: Int(sqlite3_column_int64(statement, 11)),
                    result: result,
                    limitations: try Self.decodeStringArray(statement, column: 13, connection: connection)
                ))
            }
            return values
        }
    }

    public func retentionCoverageGaps() throws -> [RetentionCoverageGap] {
        let connection = try requireConnection()
        return try connection.withStatement(
            "SELECT gap_id, retention_run_id, reason, affected_precision, started_at, rows_removed FROM retention_coverage_gaps ORDER BY started_at DESC, gap_id DESC"
        ) { statement in
            var values: [RetentionCoverageGap] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let gapID = Self.columnString(statement, column: 0),
                      let runID = Self.columnString(statement, column: 1),
                      let reason = Self.columnString(statement, column: 2),
                      let precision = Self.columnString(statement, column: 3)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    gapID: gapID,
                    retentionRunID: runID,
                    reason: reason,
                    affectedPrecision: precision,
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    rowsRemoved: Int(sqlite3_column_int64(statement, 5))
                ))
            }
            return values
        }
    }

    public func persistExportRecord(_ record: EvidenceExportRecord) throws {
        let connection = try requireConnection()
        guard record.requestedFrom <= record.requestedThrough,
              record.actualFrom.map({ actual in record.actualThrough.map { actual <= $0 } ?? false }) ?? (record.actualThrough == nil),
              record.bytes >= 0,
              record.updatedAt >= record.createdAt
        else { throw EvidenceStoreError.invalidObservation("Export record values are inconsistent") }
        guard (record.kind == .manual && record.path != nil) || (record.kind == .temporary && record.path == nil) else {
            throw EvidenceStoreError.invalidObservation("Only manual exports retain a filesystem path")
        }
        let prior = try exportRecord(id: record.exportID, connection: connection)
        if let prior {
            guard prior.kind == record.kind,
                  Self.sameInstant(prior.requestedFrom, record.requestedFrom),
                  Self.sameInstant(prior.requestedThrough, record.requestedThrough),
                  prior.pathDetail == record.pathDetail,
                  prior.path == record.path,
                  Self.sameInstant(prior.createdAt, record.createdAt),
                  record.updatedAt.timeIntervalSince(prior.updatedAt) >= -0.000_001
            else { throw EvidenceStoreError.invalidObservation("Export identity is immutable") }
            let allowed: Set<EvidenceExportStatus>
            switch prior.status {
            case .creating: allowed = [.creating, .available, .served, .failed]
            case .available: allowed = [.available, .missing]
            case .missing: allowed = [.missing, .available]
            case .served: allowed = [.served, .destroyed]
            case .destroyed: allowed = [.destroyed]
            case .failed: allowed = [.failed]
            }
            guard allowed.contains(record.status) else {
                throw EvidenceStoreError.invalidObservation("Export lifecycle transition is invalid")
            }
        } else {
            guard record.status == .creating else {
                throw EvidenceStoreError.invalidObservation("A new export record must start in creating state")
            }
            // Make room by discarding the oldest completed inventory entry. Never
            // prune an in-flight export: doing so would sever its lifecycle chain.
            if try connection.scalarInt("SELECT COUNT(*) FROM export_records") >= 512 {
                try connection.execute("DELETE FROM export_records WHERE export_id = (SELECT export_id FROM export_records WHERE status != 'creating' ORDER BY updated_at ASC, export_id ASC LIMIT 1)")
            }
            guard try connection.scalarInt("SELECT COUNT(*) FROM export_records") < 512 else {
                throw EvidenceStoreError.invalidObservation("Too many exports are currently in progress")
            }
        }
        guard record.kind == .manual ? ![.served, .destroyed].contains(record.status) : ![.available, .missing].contains(record.status) else {
            throw EvidenceStoreError.invalidObservation("Export status does not match its ownership kind")
        }
        try connection.withStatement(
            "INSERT INTO export_records (export_id, kind, requested_from, requested_through, actual_from, actual_through, precision, path_detail, path, bytes, manifest_sha256, created_at, updated_at, status, failure) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(export_id) DO UPDATE SET actual_from = excluded.actual_from, actual_through = excluded.actual_through, precision = excluded.precision, bytes = excluded.bytes, manifest_sha256 = excluded.manifest_sha256, updated_at = excluded.updated_at, status = excluded.status, failure = excluded.failure"
        ) { statement in
            try connection.bind(record.exportID, at: 1, in: statement)
            try connection.bind(record.kind.rawValue, at: 2, in: statement)
            try connection.bind(record.requestedFrom.timeIntervalSince1970, at: 3, in: statement)
            try connection.bind(record.requestedThrough.timeIntervalSince1970, at: 4, in: statement)
            try connection.bind(record.actualFrom?.timeIntervalSince1970, at: 5, in: statement)
            try connection.bind(record.actualThrough?.timeIntervalSince1970, at: 6, in: statement)
            try connection.bind(record.precision, at: 7, in: statement)
            try connection.bind(record.pathDetail.rawValue, at: 8, in: statement)
            try connection.bind(record.path, at: 9, in: statement)
            try connection.bind(record.bytes, at: 10, in: statement)
            try connection.bind(record.manifestSHA256, at: 11, in: statement)
            try connection.bind(record.createdAt.timeIntervalSince1970, at: 12, in: statement)
            try connection.bind(record.updatedAt.timeIntervalSince1970, at: 13, in: statement)
            try connection.bind(record.status.rawValue, at: 14, in: statement)
            try connection.bind(record.failure, at: 15, in: statement)
            try connection.stepDone(statement)
        }
        try connection.execute("DELETE FROM export_records WHERE export_id IN (SELECT export_id FROM export_records WHERE status != 'creating' ORDER BY updated_at ASC, export_id ASC LIMIT MAX((SELECT COUNT(*) FROM export_records) - 512, 0))")
    }

    public func exportRecords(refreshManualInventory: Bool = false, limit: Int = 512) throws -> [EvidenceExportRecord] {
        let connection = try requireConnection()
        if refreshManualInventory {
            let available = try readExportRecords(connection: connection, limit: 512).filter { $0.kind == .manual && $0.status == .available }
            for record in available where !(record.path.map(FileManager.default.fileExists(atPath:)) ?? false) {
                try persistExportRecord(Self.copyExport(record, status: .missing, updatedAt: dateSource()))
            }
        }
        return try readExportRecords(connection: connection, limit: limit)
    }

    public func markTemporaryExportDestroyed(id: String, at date: Date = Date()) throws {
        let connection = try requireConnection()
        guard let record = try exportRecord(id: id, connection: connection) else {
            throw EvidenceStoreError.invalidObservation("Export record was not found")
        }
        guard record.kind == .temporary else {
            throw EvidenceStoreError.invalidObservation("Manual exports are user-owned and cannot be destroyed by retention")
        }
        try persistExportRecord(Self.copyExport(record, status: .destroyed, updatedAt: date))
    }

    public func lifecycleStatus(_ policy: EvidenceStoreRetentionPolicy, at date: Date = Date()) throws -> EvidenceLifecycleStatus {
        try readLifecycleStatus(policy, at: date, includePrivateProgress: true)
    }

    /// A coherent, bounded metadata read. In particular, this never selects
    /// scan_generations.progress, even for pre-projection databases.
    public func lifecycleSummary(_ policy: EvidenceStoreRetentionPolicy, at date: Date = Date()) throws -> EvidenceLifecycleSummary {
        try requireConnection().transaction(readOnly: true) {
            try readLifecycleSummary(policy, at: date)
        }
    }

    private func readLifecycleSummary(_ policy: EvidenceStoreRetentionPolicy, at date: Date) throws -> EvidenceLifecycleSummary {
        let connection = try requireConnection()
        try Self.validateLifecycleSummaryBudget(connection: connection)
        let latest = try Self.readScanGenerationSummary(status: nil, connection: connection)
        let active = latest?.status == "active" ? latest : try Self.readScanGenerationSummary(status: "active", connection: connection)
        let scan: EvidenceScanCoverageSummary?
        if let latest {
            let completeAt = try connection.withStatement("SELECT MAX(g.completed_at) FROM scan_generations g JOIN observation_runs o ON o.observation_id = g.generation_id WHERE g.status = 'completed' AND o.coverage = 'complete'") { statement -> Date? in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError() }
                return Self.columnDate(statement, column: 0)
            }
            let detail: String
            if active != nil { detail = "partial" }
            else if latest.status != "completed" { detail = "stale" }
            else if latest.publishedCoverage == "complete" { detail = "complete" }
            else if let total = latest.totalRootCount, total > 0, latest.completedRootCount == 0 { detail = "unavailable" }
            else { detail = latest.publishedCoverage == nil ? "unknown" : "partial" }
            scan = .init(activeGeneration: active, latestGeneration: latest, lastCompleteGenerationAt: completeAt, detailCoverage: detail)
        } else { scan = nil }
        let latestObservationCoverage = try connection.withStatement("SELECT coverage FROM observation_runs ORDER BY completed_at DESC, observation_id DESC LIMIT 1") { statement -> String? in
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw connection.lastError(step) }
            return Self.columnString(statement, column: 0)
        }
        return .init(status: try readLifecycleStatus(policy, at: date, includePrivateProgress: false),
                     scanCoverage: scan, detailCoverage: scan?.detailCoverage ?? latestObservationCoverage ?? "unknown")
    }

    private static func validateLifecycleSummaryBudget(connection: SQLiteConnection) throws {
        var remainingBytes: Int64 = 512 * 1_024
        // Refuse before copying strings/decoding arrays; never claim a prefix
        // of gaps is complete. This runs in the same snapshot as the reads.
        for (table, columns, limit, suffix) in [
            ("coverage_gaps", ["gap_id", "observation_id", "root_path", "reason"], 512, ""),
            ("retention_coverage_gaps", ["gap_id", "retention_run_id", "reason", "affected_precision"], 512, ""),
            ("export_records", ["export_id", "kind", "precision", "path_detail", "path", "manifest_sha256", "status", "failure"], 512, ""),
            ("retention_runs", ["run_id", "trigger", "result", "limitations"], 1, "ORDER BY started_at DESC, run_id DESC LIMIT 1"),
        ] {
            let bytes = columns.map { "COALESCE(length(CAST(\($0) AS BLOB)), 0)" }.joined(separator: " + ")
            try connection.withStatement("SELECT COUNT(*), COALESCE(SUM(n), 0) FROM (SELECT 256 + \(bytes) AS n FROM \(table) \(suffix))") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError() }
                let count = sqlite3_column_int64(statement, 0)
                let size = sqlite3_column_int64(statement, 1)
                guard count <= limit, size >= 0, size <= remainingBytes else { throw EvidenceLifecycleSummaryError.budgetExceeded }
                remainingBytes -= size
            }
        }
    }

    private static func readScanGenerationSummary(status: String?, connection: SQLiteConnection) throws -> EvidenceScanGenerationSummary? {
        let predicate = status == nil ? "" : "WHERE g.status = ?"
        return try connection.withStatement("""
            SELECT g.generation_id, g.status, g.started_at, g.updated_at, g.completed_at,
                   g.processed_entry_count, g.staged_file_count, s.completed_root_count,
                   s.pending_directory_count, s.total_root_count, v.roots_json, v.exclusions_json, o.coverage
            FROM scan_generations g
            LEFT JOIN scan_generation_summaries s ON s.generation_id = g.generation_id
            JOIN scope_versions v ON v.scope_version_id = g.scope_version_id
            LEFT JOIN observation_runs o ON o.observation_id = g.generation_id
            \(predicate)
            ORDER BY g.updated_at DESC, CASE g.status WHEN 'active' THEN 0 WHEN 'completed' THEN 1 ELSE 2 END, g.generation_id DESC LIMIT 1
            """) { statement in
            if let status { try connection.bind(status, at: 1, in: statement) }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw connection.lastError(step) }
            let bytes = [0, 1, 10, 11, 12].reduce(0) { $0 + Int(sqlite3_column_bytes(statement, Int32($1))) }
            guard bytes <= 128 * 1_024 else { throw EvidenceLifecycleSummaryError.budgetExceeded }
            guard let id = columnString(statement, column: 0), let status = columnString(statement, column: 1) else { throw connection.lastError(SQLITE_CORRUPT) }
            let roots = try decodeStringArray(statement, column: 10, connection: connection)
            let exclusions = try decodeStringArray(statement, column: 11, connection: connection)
            guard roots.count <= 1_024, exclusions.count <= 1_024 else { throw EvidenceLifecycleSummaryError.budgetExceeded }
            return .init(generationID: id, status: status,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), completedAt: columnDate(statement, column: 4),
                processedEntryCount: sqlite3_column_int64(statement, 5), stagedFileCount: sqlite3_column_int64(statement, 6),
                completedRootCount: columnInt64(statement, column: 7), pendingDirectoryCount: columnInt64(statement, column: 8),
                totalRootCount: columnInt64(statement, column: 9), configuredRoots: roots, excludedPaths: exclusions,
                publishedCoverage: columnString(statement, column: 12))
        }
    }

    private func readLifecycleStatus(_ policy: EvidenceStoreRetentionPolicy, at date: Date, includePrivateProgress: Bool) throws -> EvidenceLifecycleStatus {
        let connection = try requireConnection()
        let rawFrom = date.addingTimeInterval(-Double(policy.rawEventDays * 86_400))
        let anomalyFrom = date.addingTimeInterval(-Double(policy.anomalyDetailDays * 86_400))
        let hourlyFrom = date.addingTimeInterval(-Double(policy.hourlySummaryDays * 86_400))
        let dailyFrom = date.addingTimeInterval(-Double(policy.dailySummaryDays * 86_400))
        let tiers = try [
            tierStatus(name: "raw-detail", table: "events", timeColumn: "observed_at", predicate: "is_anomaly = 0 OR is_reviewed = 1", requestedFrom: rawFrom, precision: "event", connection: connection),
            tierStatus(name: "anomaly-detail", table: "events", timeColumn: "observed_at", predicate: "is_anomaly = 1 AND is_reviewed = 0", requestedFrom: anomalyFrom, precision: "event", connection: connection),
            tierStatus(name: "hourly", table: "hourly_summaries", timeColumn: "bucket_start", predicate: nil, requestedFrom: hourlyFrom, precision: "hour", connection: connection),
            tierStatus(name: "daily", table: "daily_summaries", timeColumn: "bucket_start", predicate: nil, requestedFrom: dailyFrom, precision: "day", connection: connection),
            tierStatus(name: "snapshots", table: "snapshots", timeColumn: "observed_at", predicate: nil, requestedFrom: dailyFrom, precision: "raw-then-hourly-then-daily", connection: connection),
        ]
        let runs = try retentionRuns(limit: 1)
        let scanCoverage = includePrivateProgress ? try scanCoverageStatus() : nil
        var observationGaps = try readCoverageGaps(connection: connection, observationID: nil)
        if let active = scanCoverage?.activeGeneration {
            observationGaps.append(contentsOf: active.roots
                .filter { $0.status != .completed }
                .map { root in
                    EvidenceCoverageGap(
                        gapID: "active-\(active.generationID)-\(Self.stableIdentifier(root.rootPath))",
                        observationID: active.generationID,
                        rootPath: root.rootPath,
                        reason: "scan-generation-incomplete",
                        startedAt: active.startedAt,
                        endedAt: nil
                    )
                })
        }
        return EvidenceLifecycleStatus(
            observedAt: date,
            tiers: tiers,
            databaseBytes: storageBytes(),
            databaseCapBytes: policy.maxDatabaseBytes,
            lastCompaction: runs.first,
            totalForcedEvictions: Int(try connection.scalarInt("SELECT COALESCE(SUM(forced_evictions), 0) FROM retention_runs")),
            currentStateCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM current_file_state")),
            currentStateAllocatedBytes: try connection.scalarInt("SELECT COALESCE(SUM(allocated_bytes), 0) FROM current_file_state"),
            exportInventory: try exportRecords(refreshManualInventory: includePrivateProgress),
            observationGaps: observationGaps,
            retentionGaps: try retentionCoverageGaps(),
            scanCoverage: scanCoverage,
            storage: try storageAccounting(connection: connection, capBytes: policy.maxDatabaseBytes, probeCheckpoint: includePrivateProgress)
        )
    }

    public func queryCurrentConsumers(
        rootPath: String? = nil,
        category: String? = nil,
        minimumAllocatedBytes: Int64 = 0,
        modifiedBefore: Date? = nil,
        cursor: String? = nil,
        limit: Int = 100,
        scope: EvidenceQueryScope? = nil
    ) throws -> EvidenceQueryPage<CurrentConsumerRecord> {
        let connection = try requireConnection()
        let boundedLimit = min(max(limit, 1), 500)
        let revision = try Self.currentQueryRevision(connection: connection)
        let scopePredicate = scope?.predicate(column: "c.path")
        let decodedCursor: CurrentQueryCursor? = try cursor.map { try Self.decodeCursor($0) }
        if let decodedCursor, decodedCursor.revision != revision { throw EvidenceStoreError.cursorExpired }
        // Current-state truth outlives raw event history. Prefer the most recent retained
        // classification, then deterministically recover it from the canonical path so
        // compaction never silently turns a known consumer into an unrelated category.
        let categoryExpression = """
        COALESCE(
            (SELECT e.consumer_category
             FROM change_events ce
             JOIN events e ON e.event_id = ce.event_id
             WHERE ce.object_id = c.object_id
             ORDER BY ce.detected_at DESC, ce.event_id DESC
             LIMIT 1),
            CASE
                WHEN instr(lower(c.path), '/documents/codex/') > 0 OR instr(lower(c.path), '/.claude/') > 0 THEN 'agent-artifact'
                WHEN instr(lower(c.path), '/downloads/') > 0 THEN 'downloads'
                WHEN instr(lower(c.path), '/deriveddata/') > 0 OR instr(lower(c.path), '/.build/') > 0 OR instr(lower(c.path), '/node_modules/') > 0 OR instr(lower(c.path), '/caches/') > 0 THEN 'developer-cache'
                ELSE 'watched-root'
            END
        )
        """
        var basePredicates = ["c.presence = 'present'", "c.actionable = 1", "c.allocated_bytes >= ?"]
        if rootPath != nil { basePredicates.append("c.root_path = ?") }
        if category != nil { basePredicates.append("\(categoryExpression) = ?") }
        if modifiedBefore != nil { basePredicates.append("c.modified_at IS NOT NULL AND c.modified_at <= ?") }
        let unscopedWhere = basePredicates.joined(separator: " AND ")
        if let scopePredicate { basePredicates.append(scopePredicate.sql) }
        let baseWhere = basePredicates.joined(separator: " AND ")

        func bindBase(_ statement: OpaquePointer, includeScope: Bool = true) throws -> Int32 {
            var index: Int32 = 1
            try connection.bind(max(0, minimumAllocatedBytes), at: index, in: statement); index += 1
            if let rootPath { try connection.bind(rootPath, at: index, in: statement); index += 1 }
            if let category { try connection.bind(category, at: index, in: statement); index += 1 }
            if let modifiedBefore { try connection.bind(modifiedBefore.timeIntervalSince1970, at: index, in: statement); index += 1 }
            if includeScope, let scopePredicate {
                for value in scopePredicate.bindings { try connection.bind(value, at: index, in: statement); index += 1 }
            }
            return index
        }

        func count(where predicate: String, includeScope: Bool) throws -> Int {
            try connection.withStatement("SELECT COUNT(*) FROM current_file_state c WHERE \(predicate)") { statement in
                _ = try bindBase(statement, includeScope: includeScope)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
                return Int(sqlite3_column_int64(statement, 0))
            }
        }
        let matchedCount = try count(where: baseWhere, includeScope: true)
        // Hidden rows are retained evidence outside the current policy, never
        // an observed removal; report how many the scope withholds.
        let scopeHiddenCount: Int? = scopePredicate == nil ? nil
            : max(0, try count(where: unscopedWhere, includeScope: false) - matchedCount)
        var pagePredicate = baseWhere
        if decodedCursor != nil {
            pagePredicate += " AND (c.allocated_bytes < ? OR (c.allocated_bytes = ? AND (c.path > ? OR (c.path = ? AND c.object_id > ?))))"
        }
        let rows = try connection.withStatement(
            "SELECT c.object_id, c.identity_method, c.path, c.root_path, c.scope_version_id, c.logical_bytes, c.allocated_bytes, c.modified_at, c.presence, c.state_as_of_observation_id, c.observed_at, c.actionable, \(categoryExpression) FROM current_file_state c WHERE \(pagePredicate) ORDER BY c.allocated_bytes DESC, c.path ASC, c.object_id ASC LIMIT ?"
        ) { statement in
            var index = try bindBase(statement)
            if let decodedCursor {
                try connection.bind(decodedCursor.allocatedBytes, at: index, in: statement); index += 1
                try connection.bind(decodedCursor.allocatedBytes, at: index, in: statement); index += 1
                try connection.bind(decodedCursor.path, at: index, in: statement); index += 1
                try connection.bind(decodedCursor.path, at: index, in: statement); index += 1
                try connection.bind(decodedCursor.objectID, at: index, in: statement); index += 1
            }
            try connection.bind(Int64(boundedLimit + 1), at: index, in: statement)
            var values: [CurrentConsumerRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let objectID = Self.columnString(statement, column: 0),
                      let identityText = Self.columnString(statement, column: 1),
                      let identity = FileIdentityMethod(rawValue: identityText),
                      let path = Self.columnString(statement, column: 2),
                      let root = Self.columnString(statement, column: 3),
                      let scope = Self.columnString(statement, column: 4),
                      let presenceText = Self.columnString(statement, column: 8),
                      let presence = CurrentFilePresence(rawValue: presenceText),
                      let observationID = Self.columnString(statement, column: 9),
                      let consumerCategory = Self.columnString(statement, column: 12)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    state: .init(
                        objectID: objectID,
                        identityMethod: identity,
                        path: path,
                        rootPath: root,
                        scopeVersionID: scope,
                        logicalBytes: sqlite3_column_int64(statement, 5),
                        allocatedBytes: sqlite3_column_int64(statement, 6),
                        modifiedAt: Self.columnDate(statement, column: 7),
                        presence: presence,
                        stateAsOfObservationID: observationID,
                        observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                        actionable: sqlite3_column_int64(statement, 11) != 0
                    ),
                    consumerCategory: consumerCategory
                ))
            }
            return values
        }
        let items = Array(rows.prefix(boundedLimit))
        let next = rows.count > boundedLimit ? items.last.map {
            Self.encodeCursor(CurrentQueryCursor(revision: revision, allocatedBytes: $0.state.allocatedBytes, path: $0.state.path, objectID: $0.state.objectID))
        } : nil
        return .init(matchedCount: matchedCount, items: items, nextCursor: next, scopeHiddenCount: scopeHiddenCount)
    }

    public func queryEvents(
        from: Date,
        through: Date,
        cursor: String? = nil,
        limit: Int = 100
    ) throws -> EvidenceQueryPage<EvidenceStoreEvent> {
        guard from <= through else { throw EvidenceStoreError.invalidEvent("Evidence event query range is invalid") }
        let connection = try requireConnection()
        let boundedLimit = min(max(limit, 1), 500)
        let revision = try Self.historyQueryRevision(connection: connection)
        let decodedCursor: EventQueryCursor? = try cursor.map { try Self.decodeCursor($0) }
        if let decodedCursor, decodedCursor.revision != revision { throw EvidenceStoreError.cursorExpired }
        let matchedCount = Int(try connection.scalarInt(
            "SELECT COUNT(*) FROM events WHERE observed_at >= \(from.timeIntervalSince1970) AND observed_at <= \(through.timeIntervalSince1970)"
        ))
        var predicate = "observed_at >= ? AND observed_at <= ?"
        if decodedCursor != nil { predicate += " AND (observed_at < ? OR (observed_at = ? AND event_id < ?))" }
        let rows = try connection.withStatement(
            "SELECT event_id, observed_at, operation, path, logical_delta, allocated_delta, consumer_category, confidence, is_anomaly, is_reviewed, occurred_start, occurred_end, detected_at FROM event_evidence WHERE \(predicate) ORDER BY observed_at DESC, event_id DESC LIMIT ?"
        ) { statement in
            var index: Int32 = 1
            try connection.bind(from.timeIntervalSince1970, at: index, in: statement); index += 1
            try connection.bind(through.timeIntervalSince1970, at: index, in: statement); index += 1
            if let decodedCursor {
                try connection.bind(decodedCursor.observedAt.timeIntervalSince1970, at: index, in: statement); index += 1
                try connection.bind(decodedCursor.observedAt.timeIntervalSince1970, at: index, in: statement); index += 1
                try connection.bind(decodedCursor.eventID, at: index, in: statement); index += 1
            }
            try connection.bind(Int64(boundedLimit + 1), at: index, in: statement)
            return try Self.readEvents(statement: statement, connection: connection)
        }
        let items = Array(rows.prefix(boundedLimit))
        let next = rows.count > boundedLimit ? items.last.map {
            Self.encodeCursor(EventQueryCursor(revision: revision, observedAt: $0.observedAt, eventID: $0.eventID))
        } : nil
        return .init(matchedCount: matchedCount, items: items, nextCursor: next)
    }

    public func growthAggregate(from: Date, through: Date, scope: EvidenceQueryScope? = nil) throws -> EvidenceGrowthAggregate {
        guard from <= through else { throw EvidenceStoreError.invalidEvent("Evidence event query range is invalid") }
        let connection = try requireConnection()
        let stateScope = scope?.predicate(column: "c.path")
        let joinedScope = scope?.predicate(column: "ee.path")
        let eventScope = scope?.predicate(column: "events.path")
        func clause(_ predicate: (sql: String, bindings: [String])?) -> String { predicate.map { " AND " + $0.sql } ?? "" }
        let surviving = """
            FROM current_file_state c
                WHERE c.presence = 'present' AND c.actionable = 1\(clause(stateScope))
                AND c.object_id IN (SELECT DISTINCT ce.object_id FROM change_events ce JOIN events ee ON ee.event_id = ce.event_id WHERE ee.observed_at >= ? AND ee.observed_at <= ?\(clause(joinedScope)))
            """
        return try connection.withStatement(
            """
            SELECT
              COUNT(*),
              COALESCE(SUM(CASE WHEN allocated_delta > 0 THEN allocated_delta ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN allocated_delta < 0 THEN -allocated_delta ELSE 0 END), 0),
              COALESCE(SUM(ABS(allocated_delta)), 0),
              COALESCE(SUM(allocated_delta), 0),
              (SELECT COUNT(DISTINCT c.object_id) \(surviving)),
              (SELECT COALESCE(SUM(c.allocated_bytes), 0) \(surviving))
            FROM events WHERE observed_at >= ? AND observed_at <= ?\(clause(eventScope))
            """
        ) { statement in
            var index: Int32 = 1
            func bind(_ values: [String]) throws { for value in values { try connection.bind(value, at: index, in: statement); index += 1 } }
            func bindRange() throws {
                try connection.bind(from.timeIntervalSince1970, at: index, in: statement); index += 1
                try connection.bind(through.timeIntervalSince1970, at: index, in: statement); index += 1
            }
            for _ in 0..<2 {
                try bind(stateScope?.bindings ?? [])
                try bindRange()
                try bind(joinedScope?.bindings ?? [])
            }
            try bindRange()
            try bind(eventScope?.bindings ?? [])
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return .init(
                matchedCount: Int(sqlite3_column_int64(statement, 0)),
                growthBytes: sqlite3_column_int64(statement, 1),
                shrinkBytes: sqlite3_column_int64(statement, 2),
                churnBytes: sqlite3_column_int64(statement, 3),
                netAllocatedDelta: sqlite3_column_int64(statement, 4),
                survivingObjectCount: Int(sqlite3_column_int64(statement, 5)),
                survivingAllocatedBytes: sqlite3_column_int64(statement, 6)
            )
        }
    }

    public func queryGrowth(
        from: Date,
        through: Date,
        cursor: String? = nil,
        limit: Int = 100,
        scope: EvidenceQueryScope? = nil
    ) throws -> EvidenceGrowthReadModel {
        guard from <= through else { throw EvidenceStoreError.invalidEvent("Evidence growth query range is invalid") }
        let connection = try requireConnection()
        let boundedLimit = min(max(limit, 1), 500)
        let revision = try Self.historyQueryRevision(connection: connection)
        let decodedCursor: EventQueryCursor? = try cursor.map { try Self.decodeCursor($0) }
        if let decodedCursor, decodedCursor.revision != revision { throw EvidenceStoreError.cursorExpired }
        let scopePredicate = scope?.predicate(column: "path")
        let scopeClause = scopePredicate.map { " AND " + $0.sql } ?? ""
        func bindScope(_ statement: OpaquePointer, _ index: inout Int32) throws {
            for value in scopePredicate?.bindings ?? [] { try connection.bind(value, at: index, in: statement); index += 1 }
        }
        let union = """
        SELECT event_id AS row_id, observed_at, 'raw' AS precision, operation, path, 1 AS event_count, logical_delta, allocated_delta, consumer_category, confidence FROM events
        UNION ALL
        SELECT 'hourly:' || printf('%.6f', bucket_start) || ':' || path || ':' || operation, bucket_start, 'hourly', operation, path, event_count, logical_delta, allocated_delta, 'summarized', 'unknown' FROM hourly_summaries
        UNION ALL
        SELECT 'daily:' || printf('%.6f', bucket_start) || ':' || path || ':' || operation, bucket_start, 'daily', operation, path, event_count, logical_delta, allocated_delta, 'summarized', 'unknown' FROM daily_summaries
        """
        let surviving = try growthAggregate(from: from, through: through, scope: scope)
        let aggregate = try connection.withStatement(
            "WITH evidence AS (\(union)) SELECT COUNT(*), COALESCE(SUM(CASE WHEN allocated_delta > 0 THEN allocated_delta ELSE 0 END), 0), COALESCE(SUM(CASE WHEN allocated_delta < 0 THEN -allocated_delta ELSE 0 END), 0), COALESCE(SUM(ABS(allocated_delta)), 0), COALESCE(SUM(allocated_delta), 0) FROM evidence WHERE observed_at >= ? AND observed_at <= ?\(scopeClause)"
        ) { statement in
            var index: Int32 = 1
            try connection.bind(from.timeIntervalSince1970, at: index, in: statement); index += 1
            try connection.bind(through.timeIntervalSince1970, at: index, in: statement); index += 1
            try bindScope(statement, &index)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return EvidenceGrowthAggregate(
                matchedCount: Int(sqlite3_column_int64(statement, 0)),
                growthBytes: sqlite3_column_int64(statement, 1),
                shrinkBytes: sqlite3_column_int64(statement, 2),
                churnBytes: sqlite3_column_int64(statement, 3),
                netAllocatedDelta: sqlite3_column_int64(statement, 4),
                survivingObjectCount: surviving.survivingObjectCount,
                survivingAllocatedBytes: surviving.survivingAllocatedBytes
            )
        }
        var cursorPredicate = ""
        if decodedCursor != nil { cursorPredicate = " AND (observed_at < ? OR (observed_at = ? AND row_id < ?))" }
        let rows = try connection.withStatement(
            "WITH evidence AS (\(union)) SELECT row_id, observed_at, precision, operation, path, event_count, logical_delta, allocated_delta, consumer_category, confidence FROM evidence WHERE observed_at >= ? AND observed_at <= ?\(scopeClause)\(cursorPredicate) ORDER BY observed_at DESC, row_id DESC LIMIT ?"
        ) { statement in
            var index: Int32 = 1
            try connection.bind(from.timeIntervalSince1970, at: index, in: statement); index += 1
            try connection.bind(through.timeIntervalSince1970, at: index, in: statement); index += 1
            try bindScope(statement, &index)
            if let decodedCursor {
                try connection.bind(decodedCursor.observedAt.timeIntervalSince1970, at: index, in: statement); index += 1
                try connection.bind(decodedCursor.observedAt.timeIntervalSince1970, at: index, in: statement); index += 1
                try connection.bind(decodedCursor.eventID, at: index, in: statement); index += 1
            }
            try connection.bind(Int64(boundedLimit + 1), at: index, in: statement)
            var values: [EvidenceGrowthItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rowID = Self.columnString(statement, column: 0),
                      let precision = Self.columnString(statement, column: 2),
                      let operationText = Self.columnString(statement, column: 3),
                      let operation = EvidenceStoreEvent.Operation(rawValue: operationText),
                      let path = Self.columnString(statement, column: 4),
                      let category = Self.columnString(statement, column: 8),
                      let confidenceText = Self.columnString(statement, column: 9),
                      let confidence = EvidenceStoreEvent.Confidence(rawValue: confidenceText)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    rowID: rowID,
                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    precision: precision,
                    operation: operation,
                    path: path,
                    eventCount: Int(sqlite3_column_int64(statement, 5)),
                    logicalDelta: sqlite3_column_int64(statement, 6),
                    allocatedDelta: sqlite3_column_int64(statement, 7),
                    consumerCategory: category,
                    confidence: confidence
                ))
            }
            return values
        }
        let items = Array(rows.prefix(boundedLimit))
        let next = rows.count > boundedLimit ? items.last.map {
            Self.encodeCursor(EventQueryCursor(revision: revision, observedAt: $0.observedAt, eventID: $0.rowID))
        } : nil
        return .init(aggregate: aggregate, page: .init(matchedCount: aggregate.matchedCount, items: items, nextCursor: next))
    }

    /// The scope (roots and exclusions) that produced the latest observation
    /// run, so callers can tell whether the current policy differs from what
    /// the retained detail was scanned under.
    public func latestObservationScope() throws -> EvidenceScopeVersion? {
        let connection = try requireConnection()
        return try connection.withStatement(
            "SELECT s.scope_version_id, s.effective_at, s.roots_json, s.exclusions_json, s.maximum_entries, s.maximum_depth FROM observation_runs o JOIN scope_versions s ON s.scope_version_id = o.scope_version_id ORDER BY o.completed_at DESC, o.observation_id DESC LIMIT 1"
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let identifier = Self.columnString(statement, column: 0),
                  let rootsJSON = Self.columnString(statement, column: 2),
                  let exclusionsJSON = Self.columnString(statement, column: 3)
            else { return nil }
            let decoder = JSONDecoder()
            return EvidenceScopeVersion(
                scopeVersionID: identifier,
                effectiveAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                rootPaths: try decoder.decode([String].self, from: Data(rootsJSON.utf8)),
                excludedPaths: try decoder.decode([String].self, from: Data(exclusionsJSON.utf8)),
                maximumEntries: Int(sqlite3_column_int64(statement, 4)),
                maximumDepth: Int(sqlite3_column_int64(statement, 5))
            )
        }
    }

    public func latestObservationAt() throws -> Date? {
        let connection = try requireConnection()
        return try connection.withStatement("SELECT MAX(completed_at) FROM observation_runs") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return Self.columnDate(statement, column: 0)
        }
    }

    public func provenanceChain(pathQuery: String, cursor: String? = nil, limit: Int = 100, scope: EvidenceQueryScope? = nil) throws -> EvidenceProvenanceChain {
        try requireConnection().transaction(readOnly: true) {
            try readProvenanceChain(pathQuery: pathQuery, cursor: cursor, limit: limit, scope: scope)
        }
    }

    /// Bounded number of distinct file identities one provenance query resolves.
    public static let provenanceIdentityLimit = 100

    private func readProvenanceChain(pathQuery: String, cursor: String?, limit: Int, scope: EvidenceQueryScope?) throws -> EvidenceProvenanceChain {
        let connection = try requireConnection()
        let revision = try Self.fullQueryRevision(connection: connection)
        let bindingScope = scope?.predicate(column: "pb.path")
        let eventScope = scope?.predicate(column: "e.path")
        let plainScope = scope?.predicate(column: "path")
        func scopeClause(_ predicate: (sql: String, bindings: [String])?) -> String { predicate.map { " AND " + $0.sql } ?? "" }
        func bindScope(_ predicate: (sql: String, bindings: [String])?, _ statement: OpaquePointer, _ index: inout Int32) throws {
            for value in predicate?.bindings ?? [] { try connection.bind(value, at: index, in: statement); index += 1 }
        }
        // Validate a common envelope before choosing the current query branch:
        // new/removed path bindings may switch a continuation between raw
        // history and object-linked history while invalidating its revision.
        let decodedCursor: ProvenanceQueryCursor? = try cursor.map { try Self.decodeCursor($0) }
        if let decodedCursor, decodedCursor.revision != revision { throw EvidenceStoreError.cursorExpired }
        let eventCursor = decodedCursor?.event
        let basename = URL(fileURLWithPath: pathQuery).lastPathComponent
        let identityLimit = Self.provenanceIdentityLimit
        let matchedIdentities = try connection.withStatement(
            "SELECT DISTINCT pb.object_id FROM path_bindings pb WHERE (pb.path = ? OR pb.path LIKE ?)\(scopeClause(bindingScope)) ORDER BY CASE WHEN pb.path = ? THEN 0 ELSE 1 END, pb.path, pb.object_id LIMIT ?"
        ) { statement in
            var index: Int32 = 1
            try connection.bind(pathQuery, at: index, in: statement); index += 1
            try connection.bind("%/\(basename)", at: index, in: statement); index += 1
            try bindScope(bindingScope, statement, &index)
            try connection.bind(pathQuery, at: index, in: statement); index += 1
            try connection.bind(Int64(identityLimit + 1), at: index, in: statement)
            var values: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = Self.columnString(statement, column: 0) { values.append(value) }
            }
            return values
        }
        let identityLimitReached = matchedIdentities.count > identityLimit
        let objectIDs = Array(matchedIdentities.prefix(identityLimit))
        if objectIDs.isEmpty {
            let pattern = "%\(pathQuery)%"
            let matchedCount = try connection.withStatement("SELECT COUNT(*) FROM events WHERE path LIKE ?\(scopeClause(plainScope))") { statement in
                var index: Int32 = 1
                try connection.bind(pattern, at: index, in: statement); index += 1
                try bindScope(plainScope, statement, &index)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
                return Int(sqlite3_column_int64(statement, 0))
            }
            var cursorPredicate = ""
            if eventCursor != nil { cursorPredicate = " AND (observed_at > ? OR (observed_at = ? AND event_id > ?))" }
            let boundedLimit = min(max(limit, 1), 500)
            let rows = try connection.withStatement(
                "SELECT event_id, observed_at, operation, path, logical_delta, allocated_delta, consumer_category, confidence, is_anomaly, is_reviewed, occurred_start, occurred_end, detected_at FROM event_evidence WHERE path LIKE ?\(scopeClause(plainScope))\(cursorPredicate) ORDER BY observed_at ASC, event_id ASC LIMIT ?"
            ) { statement in
                var index: Int32 = 1
                try connection.bind(pattern, at: index, in: statement); index += 1
                try bindScope(plainScope, statement, &index)
                if let eventCursor {
                    try connection.bind(eventCursor.observedAt.timeIntervalSince1970, at: index, in: statement); index += 1
                    try connection.bind(eventCursor.observedAt.timeIntervalSince1970, at: index, in: statement); index += 1
                    try connection.bind(eventCursor.eventID, at: index, in: statement); index += 1
                }
                try connection.bind(Int64(boundedLimit + 1), at: index, in: statement)
                return try Self.readEvents(statement: statement, connection: connection)
            }
            let events = Array(rows.prefix(boundedLimit))
            let claims = try readProvenanceClaims(eventIDs: Set(events.map(\.eventID)), connection: connection)
            let registrationIDs = Set(claims.compactMap { $0.session?.registrationID.uuidString.lowercased() })
            let sessions = try readAgentSessions(registrationIDs: registrationIDs, connection: connection)
            let gaps = try readCoverageGaps(connection: connection, observationID: nil, limit: 1_000)
            let next = rows.count > boundedLimit ? events.last.map {
                Self.encodeCursor(ProvenanceQueryCursor(revision: revision, currentStateOffset: 0,
                    event: EventQueryCursor(revision: revision, observedAt: $0.observedAt, eventID: $0.eventID)))
            } : nil
            return .init(
                objectIDs: [], currentStates: [], events: events, claims: claims, sessions: sessions,
                observationGaps: gaps, matchedCount: matchedCount, nextCursor: next,
                identityLimitReached: identityLimitReached
            )
        }
        let placeholders = Array(repeating: "?", count: objectIDs.count).joined(separator: ",")
        let boundedLimit = min(max(limit, 1), 500)
        let currentIDs = try connection.withStatement("SELECT object_id FROM current_file_state WHERE object_id IN (\(placeholders))\(scopeClause(plainScope)) ORDER BY object_id") { statement in
            for (offset, objectID) in objectIDs.enumerated() { try connection.bind(objectID, at: Int32(offset + 1), in: statement) }
            var index = Int32(objectIDs.count + 1)
            try bindScope(plainScope, statement, &index)
            var ids: [String] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return ids }
                guard step == SQLITE_ROW, let id = Self.columnString(statement, column: 0) else { throw connection.lastError(step) }
                ids.append(id)
            }
        }
        let stateOffset = decodedCursor?.currentStateOffset ?? 0
        guard stateOffset >= 0, stateOffset <= currentIDs.count else { throw EvidenceStoreError.cursorExpired }
        let currentStateAsOf = try connection.withStatement("SELECT MAX(observed_at) FROM current_file_state WHERE object_id IN (\(placeholders))\(scopeClause(plainScope))") { statement -> Date? in
            for (offset, objectID) in objectIDs.enumerated() { try connection.bind(objectID, at: Int32(offset + 1), in: statement) }
            var index = Int32(objectIDs.count + 1)
            try bindScope(plainScope, statement, &index)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError() }
            return Self.columnDate(statement, column: 0)
        }
        var currentStates: [CurrentFileStateRecord] = []
        for id in currentIDs.dropFirst(stateOffset).prefix(boundedLimit) {
            if let state = try Self.readCurrentFile(objectID: id, connection: connection) { currentStates.append(state) }
        }
        let nextStateOffset = stateOffset + currentStates.count
        let eventLimit = boundedLimit - currentStates.count
        let matchedCount = try connection.withStatement(
            "SELECT COUNT(*) FROM change_events ce JOIN event_evidence e ON e.event_id = ce.event_id WHERE ce.object_id IN (\(placeholders))\(scopeClause(eventScope))"
        ) { statement in
            for (offset, objectID) in objectIDs.enumerated() { try connection.bind(objectID, at: Int32(offset + 1), in: statement) }
            var index = Int32(objectIDs.count + 1)
            try bindScope(eventScope, statement, &index)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return Int(sqlite3_column_int64(statement, 0))
        }
        var cursorPredicate = ""
        if eventCursor != nil { cursorPredicate = " AND (e.observed_at > ? OR (e.observed_at = ? AND e.event_id > ?))" }
        let rows = try connection.withStatement(
            "SELECT e.event_id, e.observed_at, e.operation, e.path, e.logical_delta, e.allocated_delta, e.consumer_category, e.confidence, e.is_anomaly, e.is_reviewed, e.occurred_start, e.occurred_end, e.detected_at FROM change_events ce JOIN event_evidence e ON e.event_id = ce.event_id WHERE ce.object_id IN (\(placeholders))\(scopeClause(eventScope))\(cursorPredicate) ORDER BY e.observed_at ASC, e.event_id ASC LIMIT ?"
        ) { statement in
            var index: Int32 = 1
            for objectID in objectIDs { try connection.bind(objectID, at: index, in: statement); index += 1 }
            try bindScope(eventScope, statement, &index)
            if let eventCursor {
                try connection.bind(eventCursor.observedAt.timeIntervalSince1970, at: index, in: statement); index += 1
                try connection.bind(eventCursor.observedAt.timeIntervalSince1970, at: index, in: statement); index += 1
                try connection.bind(eventCursor.eventID, at: index, in: statement); index += 1
            }
            try connection.bind(Int64(eventLimit + 1), at: index, in: statement)
            return try Self.readEvents(statement: statement, connection: connection)
        }
        let events = Array(rows.prefix(eventLimit))
        let eventIDs = Set(events.map(\.eventID))
        let claims = try readProvenanceClaims(eventIDs: eventIDs, connection: connection)
        let registrationIDs = Set(claims.compactMap { $0.session?.registrationID.uuidString.lowercased() })
        let sessions = try readAgentSessions(registrationIDs: registrationIDs, connection: connection)
        let gaps = try readCoverageGaps(connection: connection, observationID: nil, limit: 1_000)
        let nextEvent = events.last.map { EventQueryCursor(revision: revision, observedAt: $0.observedAt, eventID: $0.eventID) } ?? eventCursor
        let next = nextStateOffset < currentIDs.count || rows.count > eventLimit
            ? Self.encodeCursor(ProvenanceQueryCursor(revision: revision, currentStateOffset: nextStateOffset, event: nextEvent)) : nil
        return .init(
            objectIDs: objectIDs,
            currentStates: currentStates,
            events: events,
            claims: claims,
            sessions: sessions,
            observationGaps: gaps,
            matchedCount: matchedCount,
            nextCursor: next,
            matchedCurrentStateCount: currentIDs.count,
            currentStateAsOf: currentStateAsOf,
            identityLimitReached: identityLimitReached
        )
    }

    public func survivingImpact(eventIDs: [String]) throws -> SurvivingTaskImpact {
        guard !eventIDs.isEmpty else { return .init(objectCount: 0, logicalBytes: 0, allocatedBytes: 0) }
        let connection = try requireConnection()
        let unique = Array(Set(eventIDs)).sorted()
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        return try connection.withStatement(
            "SELECT COUNT(DISTINCT c.object_id), COALESCE(SUM(c.logical_bytes), 0), COALESCE(SUM(c.allocated_bytes), 0) FROM current_file_state c WHERE c.presence = 'present' AND c.actionable = 1 AND c.object_id IN (SELECT DISTINCT object_id FROM change_events WHERE event_id IN (\(placeholders)))"
        ) { statement in
            for (offset, eventID) in unique.enumerated() { try connection.bind(eventID, at: Int32(offset + 1), in: statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return .init(
                objectCount: Int(sqlite3_column_int64(statement, 0)),
                logicalBytes: sqlite3_column_int64(statement, 1),
                allocatedBytes: sqlite3_column_int64(statement, 2)
            )
        }
    }

    public func provenanceAttributions(
        registrationIDs: [UUID],
        from: Date,
        through: Date
    ) throws -> [PersistedTaskAttribution] {
        guard !registrationIDs.isEmpty else { return [] }
        let connection = try requireConnection()
        let identifiers = registrationIDs.map { $0.uuidString.lowercased() }.sorted()
        let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
        return try connection.withStatement(
            "SELECT event_id, confidence FROM provenance_claims WHERE session_registration_id IN (\(placeholders)) AND occurred_end >= ? AND (occurred_start IS NULL OR occurred_start <= ?) AND timing_version = 1 AND superseded_by_claim_id IS NULL ORDER BY occurred_end, event_id LIMIT 100000"
        ) { statement in
            var index: Int32 = 1
            for identifier in identifiers { try connection.bind(identifier, at: index, in: statement); index += 1 }
            try connection.bind(from.timeIntervalSince1970, at: index, in: statement); index += 1
            try connection.bind(through.timeIntervalSince1970, at: index, in: statement)
            var values: [PersistedTaskAttribution] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let eventID = Self.columnString(statement, column: 0),
                      let confidenceText = Self.columnString(statement, column: 1),
                      let confidence = EvidenceStoreEvent.Confidence(rawValue: confidenceText)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(eventID: eventID, confidence: confidence))
            }
            return values
        }
    }

    private func observationExists(_ id: String, connection: SQLiteConnection) throws -> Bool {
        try connection.withStatement("SELECT 1 FROM observation_runs WHERE observation_id = ? LIMIT 1") { statement in
            try connection.bind(id, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private func latestScopeVersionID(connection: SQLiteConnection) throws -> String? {
        try connection.withStatement("SELECT scope_version_id FROM observation_runs ORDER BY completed_at DESC LIMIT 1") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    private func readCurrentFiles(
        connection: SQLiteConnection,
        includeNonActionable: Bool,
        limit: Int? = nil
    ) throws -> [CurrentFileStateRecord] {
        let predicate = includeNonActionable ? "" : " WHERE presence = 'present' AND actionable = 1"
        let limitClause = limit.map { " LIMIT \(max(1, $0))" } ?? ""
        return try connection.withStatement(
            "SELECT object_id, identity_method, path, root_path, scope_version_id, logical_bytes, allocated_bytes, modified_at, presence, state_as_of_observation_id, observed_at, actionable FROM current_file_state\(predicate) ORDER BY allocated_bytes DESC, path\(limitClause)"
        ) { statement in
            var result: [CurrentFileStateRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let objectText = sqlite3_column_text(statement, 0),
                      let identityText = sqlite3_column_text(statement, 1),
                      let identity = FileIdentityMethod(rawValue: String(cString: identityText)),
                      let pathText = sqlite3_column_text(statement, 2),
                      let rootText = sqlite3_column_text(statement, 3),
                      let scopeText = sqlite3_column_text(statement, 4),
                      let presenceText = sqlite3_column_text(statement, 8),
                      let presence = CurrentFilePresence(rawValue: String(cString: presenceText)),
                      let stateText = sqlite3_column_text(statement, 9)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                let modifiedAt = sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
                result.append(CurrentFileStateRecord(
                    objectID: String(cString: objectText),
                    identityMethod: identity,
                    path: String(cString: pathText),
                    rootPath: String(cString: rootText),
                    scopeVersionID: String(cString: scopeText),
                    logicalBytes: sqlite3_column_int64(statement, 5),
                    allocatedBytes: sqlite3_column_int64(statement, 6),
                    modifiedAt: modifiedAt,
                    presence: presence,
                    stateAsOfObservationID: String(cString: stateText),
                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                    actionable: sqlite3_column_int64(statement, 11) == 1
                ))
            }
            return result
        }
    }

    private func readOpenPathBindingsByObject(connection: SQLiteConnection) throws -> [String: Set<String>] {
        try connection.withStatement(
            "SELECT object_id, path FROM path_bindings WHERE valid_through IS NULL ORDER BY object_id, path"
        ) { statement in
            var result: [String: Set<String>] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let objectID = Self.columnString(statement, column: 0),
                      let path = Self.columnString(statement, column: 1)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                result[objectID, default: []].insert(path)
            }
            return result
        }
    }

    private func readCoverageGaps(
        connection: SQLiteConnection,
        observationID: String?,
        limit: Int? = nil
    ) throws -> [EvidenceCoverageGap] {
        let limitClause = limit == nil ? "" : " LIMIT ?"
        let sql = observationID == nil
            ? "SELECT gap_id, observation_id, root_path, reason, started_at, ended_at FROM coverage_gaps ORDER BY started_at DESC\(limitClause)"
            : "SELECT gap_id, observation_id, root_path, reason, started_at, ended_at FROM coverage_gaps WHERE observation_id = ? ORDER BY started_at DESC\(limitClause)"
        return try connection.withStatement(sql) { statement in
            var index: Int32 = 1
            if let observationID { try connection.bind(observationID, at: index, in: statement); index += 1 }
            if let limit { try connection.bind(Int64(min(max(limit, 1), 10_000)), at: index, in: statement) }
            var result: [EvidenceCoverageGap] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let gapText = sqlite3_column_text(statement, 0),
                      let observationText = sqlite3_column_text(statement, 1),
                      let rootText = sqlite3_column_text(statement, 2),
                      let reasonText = sqlite3_column_text(statement, 3)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                result.append(EvidenceCoverageGap(
                    gapID: String(cString: gapText),
                    observationID: String(cString: observationText),
                    rootPath: String(cString: rootText),
                    reason: String(cString: reasonText),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    endedAt: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                ))
            }
            return result
        }
    }

    private static func upsertFileObject(
        _ file: FileMetadata,
        observedAt: Date,
        state: CurrentFilePresence,
        connection: SQLiteConnection
    ) throws {
        try connection.withStatement(
            "INSERT INTO file_objects (object_id, identity_method, first_observed_at, last_observed_at, lifecycle_state) VALUES (?, ?, ?, ?, ?) ON CONFLICT(object_id) DO UPDATE SET identity_method = excluded.identity_method, first_observed_at = MIN(file_objects.first_observed_at, excluded.first_observed_at), last_observed_at = MAX(file_objects.last_observed_at, excluded.last_observed_at), lifecycle_state = excluded.lifecycle_state"
        ) { statement in
            try connection.bind(file.objectID, at: 1, in: statement)
            try connection.bind(file.identityMethod.rawValue, at: 2, in: statement)
            try connection.bind(observedAt.timeIntervalSince1970, at: 3, in: statement)
            try connection.bind(observedAt.timeIntervalSince1970, at: 4, in: statement)
            try connection.bind(state.rawValue, at: 5, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func updateFileObjectState(
        _ objectID: String,
        state: String,
        observedAt: Date,
        connection: SQLiteConnection
    ) throws {
        try connection.withStatement("UPDATE file_objects SET lifecycle_state = ?, last_observed_at = ? WHERE object_id = ?") { statement in
            try connection.bind(state, at: 1, in: statement)
            try connection.bind(observedAt.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(objectID, at: 3, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func insertStateObservation(
        _ file: FileMetadata,
        observationID: String,
        connection: SQLiteConnection
    ) throws {
        try connection.withStatement(
            "INSERT INTO file_state_observations (observation_id, object_id, path, root_path, logical_bytes, allocated_bytes, modified_at, existence, confidence, observed_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'present', 'inferred', ?)"
        ) { statement in
            try connection.bind(observationID, at: 1, in: statement)
            try connection.bind(file.objectID, at: 2, in: statement)
            try connection.bind(file.path, at: 3, in: statement)
            try connection.bind(file.rootPath, at: 4, in: statement)
            try connection.bind(file.logicalBytes, at: 5, in: statement)
            try connection.bind(file.allocatedBytes, at: 6, in: statement)
            try connection.bind(file.modifiedAt?.timeIntervalSince1970, at: 7, in: statement)
            try connection.bind(file.observedAt?.timeIntervalSince1970, at: 8, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func upsertCurrentFile(
        _ file: FileMetadata,
        scope: EvidenceScopeVersion,
        observationID: String,
        observedAt: Date,
        actionable: Bool,
        connection: SQLiteConnection
    ) throws {
        try connection.withStatement(
            "INSERT INTO current_file_state (object_id, identity_method, path, root_path, scope_version_id, logical_bytes, allocated_bytes, modified_at, presence, state_as_of_observation_id, observed_at, actionable, timing_verified) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'present', ?, ?, ?, 1) ON CONFLICT(object_id) DO UPDATE SET identity_method = excluded.identity_method, path = excluded.path, root_path = excluded.root_path, scope_version_id = excluded.scope_version_id, logical_bytes = excluded.logical_bytes, allocated_bytes = excluded.allocated_bytes, modified_at = excluded.modified_at, presence = 'present', state_as_of_observation_id = excluded.state_as_of_observation_id, observed_at = excluded.observed_at, actionable = excluded.actionable, timing_verified = 1"
        ) { statement in
            try connection.bind(file.objectID, at: 1, in: statement)
            try connection.bind(file.identityMethod.rawValue, at: 2, in: statement)
            try connection.bind(file.path, at: 3, in: statement)
            try connection.bind(file.rootPath, at: 4, in: statement)
            try connection.bind(scope.scopeVersionID, at: 5, in: statement)
            try connection.bind(file.logicalBytes, at: 6, in: statement)
            try connection.bind(file.allocatedBytes, at: 7, in: statement)
            try connection.bind(file.modifiedAt?.timeIntervalSince1970, at: 8, in: statement)
            try connection.bind(observationID, at: 9, in: statement)
            try connection.bind(observedAt.timeIntervalSince1970, at: 10, in: statement)
            try connection.bind(Int64(actionable ? 1 : 0), at: 11, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func updateCurrentPresence(
        _ objectID: String,
        presence: CurrentFilePresence,
        actionable: Bool,
        scopeVersionID: String,
        connection: SQLiteConnection
    ) throws {
        try connection.withStatement(
            "UPDATE current_file_state SET presence = ?, actionable = ?, scope_version_id = ? WHERE object_id = ?"
        ) { statement in
            try connection.bind(presence.rawValue, at: 1, in: statement)
            try connection.bind(Int64(actionable ? 1 : 0), at: 2, in: statement)
            try connection.bind(scopeVersionID, at: 3, in: statement)
            try connection.bind(objectID, at: 4, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func openPathBinding(
        _ file: FileMetadata,
        at date: Date,
        reason: String,
        connection: SQLiteConnection
    ) throws {
        let bindingID = "binding-\(stableIdentifier("\(file.objectID)|\(file.path)|\(date.timeIntervalSince1970)"))"
        try connection.withStatement(
            "INSERT OR IGNORE INTO path_bindings (binding_id, object_id, path, valid_from, valid_through, opening_reason, closing_reason, confidence, timing_verified) VALUES (?, ?, ?, ?, NULL, ?, NULL, 'inferred', 1)"
        ) { statement in
            try connection.bind(bindingID, at: 1, in: statement)
            try connection.bind(file.objectID, at: 2, in: statement)
            try connection.bind(file.path, at: 3, in: statement)
            try connection.bind(date.timeIntervalSince1970, at: 4, in: statement)
            try connection.bind(reason, at: 5, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func closePathBinding(
        objectID: String,
        path: String,
        at date: Date,
        reason: String,
        connection: SQLiteConnection
    ) throws {
        try connection.withStatement(
            "UPDATE path_bindings SET valid_through = ?, closing_reason = ? WHERE object_id = ? AND path = ? AND valid_through IS NULL"
        ) { statement in
            try connection.bind(date.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(reason, at: 2, in: statement)
            try connection.bind(objectID, at: 3, in: statement)
            try connection.bind(path, at: 4, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func makeEvent(
        operation: EvidenceStoreEvent.Operation,
        file: FileMetadata,
        before: CurrentFileStateRecord?,
        metadata: MetadataSnapshot,
        replacementAddition: Bool = false,
        observedAt: Date? = nil
    ) -> EvidenceStoreEvent {
        let logicalDelta: Int64
        let allocatedDelta: Int64
        switch operation {
        case .baseline, .rename, .scopeEnter, .scopeExit:
            logicalDelta = 0
            allocatedDelta = 0
        default:
            logicalDelta = file.logicalBytes - (replacementAddition ? 0 : (before?.logicalBytes ?? 0))
            allocatedDelta = file.allocatedBytes - (replacementAddition ? 0 : (before?.allocatedBytes ?? 0))
        }
        return EvidenceStoreEvent(
            eventID: "change-\(metadata.observationID)-\(stableIdentifier("\(file.objectID)|\(operation.rawValue)"))",
            observedAt: observedAt ?? file.observedAt ?? metadata.observedAt,
            operation: operation,
            path: file.path,
            logicalDelta: logicalDelta,
            allocatedDelta: allocatedDelta,
            consumerCategory: category(for: file.path),
            confidence: .inferred,
            isAnomaly: abs(allocatedDelta) > 1_073_741_824
        )
    }

    private static func insertEvent(_ event: EvidenceStoreEvent, connection: SQLiteConnection) throws {
        try validate(event)
        try connection.withStatement(
            "INSERT INTO events (event_id, observed_at, operation, path, logical_delta, allocated_delta, consumer_category, confidence, is_anomaly, is_reviewed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        ) { statement in
            try connection.bind(event.eventID, at: 1, in: statement)
            try connection.bind(event.observedAt.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(event.operation.rawValue, at: 3, in: statement)
            try connection.bind(event.path, at: 4, in: statement)
            try connection.bind(event.logicalDelta, at: 5, in: statement)
            try connection.bind(event.allocatedDelta, at: 6, in: statement)
            try connection.bind(event.consumerCategory, at: 7, in: statement)
            try connection.bind(event.confidence.rawValue, at: 8, in: statement)
            try connection.bind(Int64(event.isAnomaly ? 1 : 0), at: 9, in: statement)
            try connection.bind(Int64(event.isReviewed ? 1 : 0), at: 10, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func insertChangeEvent(
        _ event: EvidenceStoreEvent,
        objectID: String,
        before: CurrentFileStateRecord?,
        afterPath: String?,
        pathBefore: String? = nil,
        metadata: MetadataSnapshot,
        connection: SQLiteConnection
    ) throws -> EvidenceStoreEvent {
        // No previous observation means no supported occurrence lower bound.
        // In particular a first sighting is not an exact creation timestamp.
        // Legacy current-state rows retain publication/discovery dates. Only
        // a fresh positive sample establishes a measured prior lower bound.
        var occurredStart: Date?
        if let before {
            occurredStart = try connection.withStatement(
                "SELECT observed_at FROM reconcile_prior_current WHERE object_id = ? AND timing_verified = 1"
            ) { statement in
                try connection.bind(before.objectID, at: 1, in: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return columnDate(statement, column: 0)
            }
        }
        if let before, let pathBefore, pathBefore != before.path {
            // A replacement of a noncanonical alias is constrained by that
            // binding, not by a later sample of another surviving hard link.
            // We retain first-observed binding evidence; no last-path sample
            // is available, so deliberately use this wider supported bound.
            occurredStart = try connection.withStatement(
                "SELECT MAX(valid_from) FROM path_bindings WHERE object_id = ? AND path = ? AND timing_verified = 1"
            ) { statement in
                try connection.bind(before.objectID, at: 1, in: statement)
                try connection.bind(pathBefore, at: 2, in: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
                return columnDate(statement, column: 0)
            }
        }
        if let occurredStart, occurredStart > event.observedAt {
            // Out-of-order inputs or a backwards clock are not evidence of an
            // ordered change. Roll back publication rather than swap endpoints.
            throw EvidenceStoreError.invalidObservation("change evidence has contradictory observation times")
        }
        guard event.observedAt <= metadata.observedAt else {
            throw EvidenceStoreError.invalidObservation("change evidence is later than observation publication")
        }
        try connection.withStatement(
            "INSERT INTO change_events (event_id, operation, object_id, before_observation_id, after_observation_id, path_before, path_after, logical_delta, allocated_delta, detected_at, occurred_start, occurred_end, coverage, timing_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)"
        ) { statement in
            try connection.bind(event.eventID, at: 1, in: statement)
            try connection.bind(event.operation.rawValue, at: 2, in: statement)
            try connection.bind(objectID, at: 3, in: statement)
            try connection.bind(before?.stateAsOfObservationID, at: 4, in: statement)
            try connection.bind(metadata.observationID, at: 5, in: statement)
            try connection.bind(pathBefore ?? before?.path, at: 6, in: statement)
            try connection.bind(afterPath, at: 7, in: statement)
            try connection.bind(event.logicalDelta, at: 8, in: statement)
            try connection.bind(event.allocatedDelta, at: 9, in: statement)
            try connection.bind(metadata.observedAt.timeIntervalSince1970, at: 10, in: statement)
            try connection.bind(occurredStart?.timeIntervalSince1970, at: 11, in: statement)
            try connection.bind(event.observedAt.timeIntervalSince1970, at: 12, in: statement)
            try connection.bind(metadata.coverage.rawValue, at: 13, in: statement)
            try connection.stepDone(statement)
        }
        return event.withTiming(.init(occurredStart: occurredStart, occurredEnd: event.observedAt, detectedAt: metadata.observedAt))
    }

    private static func insertCoverageGap(_ gap: EvidenceCoverageGap, connection: SQLiteConnection) throws {
        try connection.withStatement(
            "INSERT OR IGNORE INTO coverage_gaps (gap_id, observation_id, root_path, reason, started_at, ended_at, state) VALUES (?, ?, ?, ?, ?, ?, ?)"
        ) { statement in
            try connection.bind(gap.gapID, at: 1, in: statement)
            try connection.bind(gap.observationID, at: 2, in: statement)
            try connection.bind(gap.rootPath, at: 3, in: statement)
            try connection.bind(gap.reason, at: 4, in: statement)
            try connection.bind(gap.startedAt.timeIntervalSince1970, at: 5, in: statement)
            try connection.bind(gap.endedAt?.timeIntervalSince1970, at: 6, in: statement)
            try connection.bind(gap.endedAt == nil ? "open" : "resolved", at: 7, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func resolveCoverageGaps(
        rootPath: String,
        reason: String? = nil,
        endedAt: Date,
        connection: SQLiteConnection
    ) throws {
        let sql = reason == nil
            ? "UPDATE coverage_gaps SET ended_at = ?, state = 'resolved' WHERE root_path = ? AND ended_at IS NULL"
            : "UPDATE coverage_gaps SET ended_at = ?, state = 'resolved' WHERE root_path = ? AND reason = ? AND ended_at IS NULL"
        try connection.withStatement(sql) { statement in
            try connection.bind(endedAt.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(rootPath, at: 2, in: statement)
            if let reason { try connection.bind(reason, at: 3, in: statement) }
            try connection.stepDone(statement)
        }
    }

    private static func coverageReason(_ limitations: [String], fallback: String) -> String {
        let text = limitations.joined(separator: " ").lowercased()
        if text.contains("permission") { return "permission-denied" }
        if text.contains("entry") && text.contains("limit") { return "entry-cap" }
        if text.contains("depth") { return "depth-cap" }
        if text.contains("unavailable") || text.contains("enumerate") { return "root-unavailable" }
        return fallback
    }

    private static func isIncluded(_ path: String, in scope: EvidenceScopeVersion) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let inRoot = scope.rootPaths.contains { root in
            let value = URL(fileURLWithPath: root).standardizedFileURL.path
            return normalized == value || normalized.hasPrefix(value == "/" ? "/" : value + "/")
        }
        let excluded = scope.excludedPaths.contains { root in
            let value = URL(fileURLWithPath: root).standardizedFileURL.path
            return normalized == value || normalized.hasPrefix(value == "/" ? "/" : value + "/")
        }
        return inRoot && !excluded
    }

    private static func coverage(
        for path: String,
        scope: EvidenceScopeVersion,
        rootCoverage: [String: RootObservationCoverage]
    ) -> ObservationCoverage? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let containingRoot = scope.rootPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { root in
                normalized == root || normalized.hasPrefix(root == "/" ? "/" : root + "/")
            }
            .max { $0.count < $1.count }
        return containingRoot.flatMap { rootCoverage[$0]?.coverage }
    }

    private static func category(for path: String) -> String {
        let lower = path.lowercased()
        if lower.contains("/documents/codex/") || lower.contains("/.claude/") { return "agent-artifact" }
        if lower.contains("/downloads/") { return "downloads" }
        if lower.contains("/deriveddata/") || lower.contains("/.build/") || lower.contains("/node_modules/") || lower.contains("/caches/") { return "developer-cache" }
        return "watched-root"
    }

    private static func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Data(value.utf8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func sqlLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func downsampleSnapshots(
        rawCutoff: TimeInterval,
        hourlyCutoff: TimeInterval,
        dailyCutoff: TimeInterval,
        connection: SQLiteConnection
    ) throws -> Int {
        let maximumDeletes = 10_000
        let newestRowID = try connection.scalarInt(
            "SELECT COALESCE((SELECT rowid FROM snapshots ORDER BY observed_at DESC, snapshot_id DESC LIMIT 1), -1)"
        )
        var remaining = maximumDeletes
        var deleted = 0

        func deleteBatch(predicate: String) throws {
            guard remaining > 0 else { return }
            let before = try connection.scalarInt("SELECT COUNT(*) FROM snapshots")
            try connection.execute(
                "DELETE FROM snapshots WHERE rowid IN (SELECT rowid FROM snapshots AS candidate WHERE \(predicate) ORDER BY candidate.observed_at, candidate.snapshot_id LIMIT \(remaining))"
            )
            let removed = Int(before - (try connection.scalarInt("SELECT COUNT(*) FROM snapshots")))
            deleted += removed
            remaining -= removed
        }

        try deleteBatch(predicate: "candidate.observed_at < \(dailyCutoff) AND candidate.rowid != \(newestRowID)")
        try deleteBatch(predicate: "candidate.observed_at >= \(dailyCutoff) AND candidate.observed_at < \(hourlyCutoff) AND candidate.rowid != \(newestRowID) AND EXISTS (SELECT 1 FROM snapshots AS earlier WHERE CAST(earlier.observed_at / 86400 AS INTEGER) = CAST(candidate.observed_at / 86400 AS INTEGER) AND (earlier.observed_at < candidate.observed_at OR (earlier.observed_at = candidate.observed_at AND earlier.snapshot_id < candidate.snapshot_id)))")
        try deleteBatch(predicate: "candidate.observed_at >= \(hourlyCutoff) AND candidate.observed_at < \(rawCutoff) AND candidate.rowid != \(newestRowID) AND EXISTS (SELECT 1 FROM snapshots AS earlier WHERE CAST(earlier.observed_at / 3600 AS INTEGER) = CAST(candidate.observed_at / 3600 AS INTEGER) AND (earlier.observed_at < candidate.observed_at OR (earlier.observed_at = candidate.observed_at AND earlier.snapshot_id < candidate.snapshot_id)))")
        return deleted
    }

    private static func compactDetailedHistory(
        rawCutoff: TimeInterval,
        dailyCutoff: TimeInterval,
        connection: SQLiteConnection
    ) throws -> Int {
        let tables = [
            "fsevent_hints", "endpoint_observations", "file_state_observations",
            "path_bindings", "file_objects", "observation_runs", "scope_versions",
            "agent_sessions", "coverage_gaps",
        ]
        let before = try tables.reduce(0) { partial, table in
            partial + Int(try connection.scalarInt("SELECT COUNT(*) FROM \(table)"))
        }
        try connection.execute("DELETE FROM fsevent_hints WHERE observed_at < \(rawCutoff)")
        try connection.execute("DELETE FROM endpoint_observations WHERE observed_at < \(rawCutoff)")
        try connection.execute("DELETE FROM coverage_gaps WHERE ended_at IS NOT NULL AND ended_at < \(dailyCutoff)")
        try connection.execute("DELETE FROM current_file_state WHERE presence != 'present' AND observed_at < \(rawCutoff)")
        try connection.execute(
            "DELETE FROM file_state_observations WHERE observation_id IN (SELECT observation_id FROM observation_runs WHERE completed_at < \(rawCutoff)) AND observation_id NOT IN (SELECT state_as_of_observation_id FROM current_file_state)"
        )
        let unreferencedObjects = "object_id NOT IN (SELECT object_id FROM current_file_state) AND object_id NOT IN (SELECT object_id FROM change_events) AND object_id NOT IN (SELECT object_id FROM file_state_observations) AND last_observed_at < \(rawCutoff)"
        try connection.execute("DELETE FROM path_bindings WHERE object_id IN (SELECT object_id FROM file_objects WHERE \(unreferencedObjects))")
        try connection.execute("DELETE FROM file_objects WHERE \(unreferencedObjects)")
        try connection.execute(
            "DELETE FROM observation_runs WHERE completed_at < \(rawCutoff) AND observation_id NOT IN (SELECT observation_id FROM file_state_observations) AND observation_id NOT IN (SELECT state_as_of_observation_id FROM current_file_state) AND observation_id NOT IN (SELECT after_observation_id FROM change_events) AND observation_id NOT IN (SELECT observation_id FROM coverage_gaps)"
        )
        try connection.execute(
            "DELETE FROM scope_versions WHERE scope_version_id NOT IN (SELECT scope_version_id FROM observation_runs) AND scope_version_id NOT IN (SELECT scope_version_id FROM current_file_state) AND scope_version_id NOT IN (SELECT scope_version_id FROM scan_generations)"
        )
        try connection.execute(
            "DELETE FROM agent_sessions WHERE lifecycle != 'active' AND COALESCE(ended_at, expires_at) < \(dailyCutoff)"
        )
        let after = try tables.reduce(0) { partial, table in
            partial + Int(try connection.scalarInt("SELECT COUNT(*) FROM \(table)"))
        }
        return before - after
    }

    private func insertRetentionRun(
        id: String,
        trigger: RetentionTrigger,
        policy: EvidenceStoreRetentionPolicy,
        startedAt: Date,
        storageBytesBefore: Int64,
        connection: SQLiteConnection
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try connection.withStatement(
            "INSERT INTO retention_runs (run_id, trigger, policy, started_at, storage_bytes_before, result, limitations) VALUES (?, ?, ?, ?, ?, 'started', ?)"
        ) { statement in
            try connection.bind(id, at: 1, in: statement)
            try connection.bind(trigger.rawValue, at: 2, in: statement)
            try connection.bind(try encoder.encode(policy), at: 3, in: statement)
            try connection.bind(startedAt.timeIntervalSince1970, at: 4, in: statement)
            try connection.bind(storageBytesBefore, at: 5, in: statement)
            try connection.bind(try encoder.encode([String]()), at: 6, in: statement)
            try connection.stepDone(statement)
        }
    }

    private func finishRetentionRun(
        id: String,
        completedAt: Date,
        storageBytesAfter: Int64,
        rawAggregated: Int,
        hourlyAggregated: Int,
        dailyDeleted: Int,
        snapshotsDeleted: Int,
        historicalRowsDeleted: Int,
        forcedEvictions: Int,
        result: RetentionRunResult,
        limitations: [String],
        connection: SQLiteConnection
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try connection.withStatement(
            "UPDATE retention_runs SET completed_at = ?, storage_bytes_after = ?, aggregated_raw_events = ?, aggregated_hourly_summaries = ?, deleted_daily_summaries = ?, deleted_snapshots = ?, deleted_historical_rows = ?, forced_evictions = ?, result = ?, limitations = ? WHERE run_id = ?"
        ) { statement in
            try connection.bind(completedAt.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(storageBytesAfter, at: 2, in: statement)
            try connection.bind(Int64(rawAggregated), at: 3, in: statement)
            try connection.bind(Int64(hourlyAggregated), at: 4, in: statement)
            try connection.bind(Int64(dailyDeleted), at: 5, in: statement)
            try connection.bind(Int64(snapshotsDeleted), at: 6, in: statement)
            try connection.bind(Int64(historicalRowsDeleted), at: 7, in: statement)
            try connection.bind(Int64(forcedEvictions), at: 8, in: statement)
            try connection.bind(result.rawValue, at: 9, in: statement)
            try connection.bind(try encoder.encode(limitations), at: 10, in: statement)
            try connection.bind(id, at: 11, in: statement)
            try connection.stepDone(statement)
        }
        try connection.execute("DELETE FROM retention_runs WHERE run_id IN (SELECT run_id FROM retention_runs ORDER BY started_at DESC, run_id DESC LIMIT -1 OFFSET 1500)")
    }

    private func insertRetentionGap(runID: String, at date: Date, connection: SQLiteConnection) throws {
        try connection.withStatement(
            "INSERT INTO retention_coverage_gaps (gap_id, retention_run_id, reason, affected_precision, started_at, rows_removed) VALUES (?, ?, 'database-cap-forced-eviction', 'oldest-retained-history', ?, -1)"
        ) { statement in
            try connection.bind("gap-\(runID)", at: 1, in: statement)
            try connection.bind(runID, at: 2, in: statement)
            try connection.bind(date.timeIntervalSince1970, at: 3, in: statement)
            try connection.stepDone(statement)
        }
    }

    private func updateRetentionGap(runID: String, rowsRemoved: Int, connection: SQLiteConnection) throws {
        try connection.withStatement("UPDATE retention_coverage_gaps SET rows_removed = ? WHERE retention_run_id = ?") { statement in
            try connection.bind(Int64(rowsRemoved), at: 1, in: statement)
            try connection.bind(runID, at: 2, in: statement)
            try connection.stepDone(statement)
        }
    }

    private func tierStatus(
        name: String,
        table: String,
        timeColumn: String,
        predicate: String?,
        requestedFrom: Date,
        precision: String,
        connection: SQLiteConnection
    ) throws -> EvidenceTierStatus {
        let suffix = predicate.map { " WHERE \($0)" } ?? ""
        return try connection.withStatement("SELECT MIN(\(timeColumn)), MAX(\(timeColumn)), COUNT(*) FROM \(table)\(suffix)") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return .init(
                tier: name,
                requestedFrom: requestedFrom,
                actualOldest: Self.columnDate(statement, column: 0),
                actualNewest: Self.columnDate(statement, column: 1),
                count: Int(sqlite3_column_int64(statement, 2)),
                precision: precision
            )
        }
    }

    private func readExportRecords(connection: SQLiteConnection, limit: Int) throws -> [EvidenceExportRecord] {
        try connection.withStatement(
            "SELECT export_id, kind, requested_from, requested_through, actual_from, actual_through, precision, path_detail, path, bytes, manifest_sha256, created_at, updated_at, status, failure FROM export_records ORDER BY updated_at DESC, export_id DESC LIMIT ?"
        ) { statement in
            try connection.bind(Int64(min(max(limit, 1), 512)), at: 1, in: statement)
            var values: [EvidenceExportRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let exportID = Self.columnString(statement, column: 0),
                      let kindText = Self.columnString(statement, column: 1),
                      let kind = EvidenceExportKind(rawValue: kindText),
                      let precision = Self.columnString(statement, column: 6),
                      let detailText = Self.columnString(statement, column: 7),
                      let detail = EvidencePathDetail(rawValue: detailText),
                      let statusText = Self.columnString(statement, column: 13),
                      let status = EvidenceExportStatus(rawValue: statusText)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    exportID: exportID,
                    kind: kind,
                    requestedFrom: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    requestedThrough: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    actualFrom: Self.columnDate(statement, column: 4),
                    actualThrough: Self.columnDate(statement, column: 5),
                    precision: precision,
                    pathDetail: detail,
                    path: Self.columnString(statement, column: 8),
                    bytes: sqlite3_column_int64(statement, 9),
                    manifestSHA256: Self.columnString(statement, column: 10),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
                    status: status,
                    failure: Self.columnString(statement, column: 14)
                ))
            }
            return values
        }
    }

    private func exportRecord(id: String, connection: SQLiteConnection) throws -> EvidenceExportRecord? {
        try connection.withStatement(
            "SELECT export_id, kind, requested_from, requested_through, actual_from, actual_through, precision, path_detail, path, bytes, manifest_sha256, created_at, updated_at, status, failure FROM export_records WHERE export_id = ? LIMIT 1"
        ) { statement in
            try connection.bind(id, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let exportID = Self.columnString(statement, column: 0),
                  let kindText = Self.columnString(statement, column: 1),
                  let kind = EvidenceExportKind(rawValue: kindText),
                  let precision = Self.columnString(statement, column: 6),
                  let detailText = Self.columnString(statement, column: 7),
                  let detail = EvidencePathDetail(rawValue: detailText),
                  let statusText = Self.columnString(statement, column: 13),
                  let status = EvidenceExportStatus(rawValue: statusText)
            else { throw connection.lastError(SQLITE_CORRUPT) }
            return .init(
                exportID: exportID,
                kind: kind,
                requestedFrom: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                requestedThrough: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                actualFrom: Self.columnDate(statement, column: 4),
                actualThrough: Self.columnDate(statement, column: 5),
                precision: precision,
                pathDetail: detail,
                path: Self.columnString(statement, column: 8),
                bytes: sqlite3_column_int64(statement, 9),
                manifestSHA256: Self.columnString(statement, column: 10),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
                status: status,
                failure: Self.columnString(statement, column: 14)
            )
        }
    }

    private static func copyExport(
        _ record: EvidenceExportRecord,
        status: EvidenceExportStatus,
        updatedAt: Date,
        actualFrom: Date? = nil,
        actualThrough: Date? = nil,
        precision: String? = nil,
        bytes: Int64? = nil,
        manifestSHA256: String? = nil,
        failure: String? = nil
    ) -> EvidenceExportRecord {
        .init(
            exportID: record.exportID,
            kind: record.kind,
            requestedFrom: record.requestedFrom,
            requestedThrough: record.requestedThrough,
            actualFrom: actualFrom ?? record.actualFrom,
            actualThrough: actualThrough ?? record.actualThrough,
            precision: precision ?? record.precision,
            pathDetail: record.pathDetail,
            path: record.path,
            bytes: bytes ?? record.bytes,
            manifestSHA256: manifestSHA256 ?? record.manifestSHA256,
            createdAt: record.createdAt,
            updatedAt: updatedAt,
            status: status,
            failure: failure ?? record.failure
        )
    }

    private static func sameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= 0.000_001
    }

    private func evictOldestBatch(limit: Int) throws -> Int {
        let connection = try requireConnection()
        var candidates: [(table: String, timeColumn: String, timestamp: Double, observationID: String?)] = try [
            (table: "events", time: "observed_at"),
            (table: "hourly_summaries", time: "bucket_start"),
            (table: "daily_summaries", time: "bucket_start"),
            (table: "snapshots", time: "observed_at"),
        ].compactMap { candidate -> (table: String, timeColumn: String, timestamp: Double, observationID: String?)? in
            try connection.withStatement("SELECT MIN(\(candidate.time)) FROM \(candidate.table)") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW,
                      sqlite3_column_type(statement, 0) != SQLITE_NULL
                else { return nil }
                return (candidate.table, candidate.time, sqlite3_column_double(statement, 0), nil)
            }
        }
        if let detailed = try oldestEvictableDetailedObservation(connection: connection) {
            candidates.append(("file_state_observations", "completed_at", detailed.completedAt, detailed.observationID))
        }
        guard let oldest = candidates.min(by: { $0.timestamp < $1.timestamp }) else { return 0 }

        if oldest.table == "file_state_observations", let observationID = oldest.observationID {
            try connection.withStatement(
                """
                DELETE FROM file_state_observations
                WHERE rowid IN (
                    SELECT history.rowid
                    FROM file_state_observations AS history
                    WHERE history.observation_id = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM current_file_state AS current
                          WHERE current.object_id = history.object_id
                            AND current.state_as_of_observation_id = history.observation_id
                      )
                    ORDER BY history.object_id
                    LIMIT ?
                )
                """
            ) { statement in
                try connection.bind(observationID, at: 1, in: statement)
                try connection.bind(Int64(limit), at: 2, in: statement)
                try connection.stepDone(statement)
            }
            return Int(try connection.scalarInt("SELECT changes()"))
        }

        let table = oldest.table
        let timeColumn = oldest.timeColumn
        try connection.execute(
            "DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) ORDER BY \(timeColumn), rowid LIMIT \(limit))"
        )
        return Int(try connection.scalarInt("SELECT changes()"))
    }

    private func hasEvictableHistory(connection: SQLiteConnection) throws -> Bool {
        if try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM events) OR EXISTS(SELECT 1 FROM hourly_summaries) OR EXISTS(SELECT 1 FROM daily_summaries) OR EXISTS(SELECT 1 FROM snapshots)") != 0 {
            return true
        }
        return try oldestEvictableDetailedObservation(connection: connection) != nil
    }

    private func oldestEvictableDetailedObservation(
        connection: SQLiteConnection
    ) throws -> (observationID: String, completedAt: Double)? {
        try connection.withStatement(
            """
            SELECT run.observation_id, run.completed_at
            FROM observation_runs AS run
            WHERE EXISTS (
                SELECT 1
                FROM file_state_observations AS history
                WHERE history.observation_id = run.observation_id
                  AND NOT EXISTS (
                      SELECT 1 FROM current_file_state AS current
                      WHERE current.object_id = history.object_id
                        AND current.state_as_of_observation_id = history.observation_id
                  )
            )
            ORDER BY run.completed_at, run.observation_id
            LIMIT 1
            """
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let identifier = sqlite3_column_text(statement, 0)
            else { return nil }
            return (String(cString: identifier), sqlite3_column_double(statement, 1))
        }
    }

    private func storageBytes() -> Int64 {
        fileSize(atPath: databaseURL.path)
            + fileSize(atPath: databaseURL.path + "-wal")
            + fileSize(atPath: databaseURL.path + "-shm")
    }

    /// Per-row storage costs measured on the one-million-file product run
    /// (docs/reliability/evidence/TASK-531/scale-runs/wide-1m): a 3.3 GB final
    /// database and a 2.98 GB peak write-ahead log for 1,000,000 new files.
    /// Republishing a row that current state already holds costs far less.
    /// Deliberately rounded up; the accounting reports what was reserved.
    enum StorageCostModel {
        static let stagedRowBytes: Int64 = 1_024
        static let newPublishedRowBytes: Int64 = 2_304
        static let republishedRowBytes: Int64 = 768
        static let newRowLogBytes: Int64 = 3_072
        static let republishedRowLogBytes: Int64 = 1_024
        static let publicationFixedBytes: Int64 = 64 * 1_024
        static let diskReserveBytes: Int64 = 64 * 1_024 * 1_024
        /// One nominal safety slice of file detail, staged and later published,
        /// with the fixed publication cost and an allowance for directory passes.
        /// A first slice's admission demand never exceeds it; slices that close
        /// hundreds of small directories at once may, and are still judged exactly.
        static let nextSliceBytes: Int64 = 512 * (stagedRowBytes + newPublishedRowBytes) + 2 * publicationFixedBytes

        /// Durable growth and transient log for publishing `stagedRows` when
        /// `currentRows` are already published: rows beyond the current set
        /// are treated as new, the rest as republished.
        static func publication(stagedRows: Int64, currentRows: Int64) -> (reserve: Int64, log: Int64) {
            guard stagedRows > 0 else { return (0, 0) }
            let newRows = max(0, stagedRows - currentRows)
            let republished = stagedRows - newRows
            return (newRows * newPublishedRowBytes + republished * republishedRowBytes + publicationFixedBytes,
                    newRows * newRowLogBytes + republished * republishedRowLogBytes + publicationFixedBytes)
        }
    }

    /// Work whose storage cost is estimated before any of it is written.
    enum StorageWork {
        case generic(bytes: Int64)
        case staging(rows: Int, passes: Int)
        case publication(stagedRows: Int64, priorCurrentRows: Int64)
    }

    /// One accounting of live, reusable, log and shared-memory bytes plus the
    /// reserve the next publication of currently staged rows will need.
    public func storageAccounting() throws -> EvidenceStorageAccounting {
        try storageAccounting(connection: requireConnection(), capBytes: storageCapBytes, probeCheckpoint: true, demandHint: 0)
    }

    /// The persisted retention setting is the single source of truth for the
    /// cap; the owning process syncs it before sampling so a raised cap admits
    /// work without waiting for a retention run.
    public func updateStorageCap(_ bytes: Int64) {
        storageCapBytes = max(1 * 1_024 * 1_024, bytes)
    }

    /// The active scan generation, if one is open.
    public func activeScanGeneration() throws -> MetadataScanGeneration? {
        try Self.readScanGeneration(status: .active, connection: requireConnection())
    }

    /// `demandHint` is the work about to be admitted; a write-ahead log that is
    /// only decisive together with that demand is probed rather than trusted.
    private func storageAccounting(
        connection: SQLiteConnection, capBytes: Int64, probeCheckpoint: Bool, demandHint: Int64 = 0
    ) throws -> EvidenceStorageAccounting {
        let pageCount = try connection.scalarInt("PRAGMA page_count")
        let freePages = try connection.scalarInt("PRAGMA freelist_count")
        let pageSize = try connection.scalarInt("PRAGMA page_size")
        let staged = try connection.scalarInt("SELECT COUNT(*) FROM scan_generation_entries")
        let current = try connection.scalarInt("SELECT COUNT(*) FROM current_file_state")
        let liveBytes = max(0, pageCount - freePages) * pageSize
        let reusable = freePages * pageSize
        let shm = fileSize(atPath: databaseURL.path + "-shm")
        let publication = StorageCostModel.publication(stagedRows: staged, currentRows: current)
        // While a generation is active the next slice is the next unit of work;
        // an accounting that ignored it would call a store "available" whose
        // very next slice is refused.
        // A scalar existence check: the public summary path must never decode
        // the private traversal checkpoint (scan_generations.progress).
        let generationActive = try connection.scalarInt("SELECT EXISTS(SELECT 1 FROM scan_generations WHERE status = 'active')") != 0
        let nextWork = generationActive ? StorageCostModel.nextSliceBytes : 0
        var walPinned = false
        var walBytes = fileSize(atPath: databaseURL.path + "-wal")
        // The log file keeps its size after SQLite's own checkpoints, so it is
        // trusted only while it cannot change the decision: past its bound, or
        // when counting it would push the demand over the cap, it is probed.
        // PASSIVE never blocks; frames it cannot move belong to an open
        // reader's snapshot. Once every frame is moved, TRUNCATE resets the
        // file without waiting on anyone.
        let decisive = walBytes > 0
            && (walBytes > walJournalSizeLimit || liveBytes + shm + walBytes + publication.reserve + nextWork + max(0, demandHint) > capBytes)
        if probeCheckpoint, decisive {
            let passive = try connection.walCheckpoint("PASSIVE")
            walPinned = passive.logFrames > 0 && passive.checkpointedFrames < passive.logFrames
            if !walPinned, passive.busy == 0 {
                let truncate = try connection.walCheckpoint("TRUNCATE")
                if truncate.busy == 0 { walBytes = fileSize(atPath: databaseURL.path + "-wal") }
            }
        }
        let disk = availableCapacitySource(databaseURL)
        let evictable = try hasEvictableHistory(connection: connection)
        let committed = liveBytes + walBytes + shm
        var limitations: [String] = []
        let admission: EvidenceStorageAccounting.Admission
        let reserved = publication.reserve + nextWork
        if walPinned, committed + reserved > capBytes {
            admission = .walPinned
            limitations.append("An open reader pins \(walBytes) bytes of write-ahead log; they are reclaimed when it closes, not by eviction.")
        } else if let disk, disk < publication.log + StorageCostModel.diskReserveBytes {
            admission = .diskSpaceLimited
            limitations.append("The volume has \(disk) bytes free; publishing \(staged) staged rows needs about \(publication.log + StorageCostModel.diskReserveBytes). Nothing was written.")
        } else if committed + reserved <= capBytes {
            admission = .available
        } else if evictable {
            admission = .retentionRequired
            limitations.append("Committed \(committed) bytes plus a \(reserved)-byte reserve for publication and the next slice exceed the \(capBytes)-byte cap; retention can evict history.")
        } else {
            admission = .capacityLimited
            limitations.append("Authoritative current state, staged work and the next slice need \(committed + reserved) bytes against a \(capBytes)-byte cap with no evictable history; raise the cap or narrow watched roots. Nothing was evicted.")
        }
        return EvidenceStorageAccounting(
            capBytes: capBytes, fileBytes: fileSize(atPath: databaseURL.path), liveBytes: liveBytes, reusableBytes: reusable,
            walBytes: walBytes, sharedMemoryBytes: shm, stagedRowCount: staged, reservedPublicationBytes: publication.reserve,
            nextWorkReserveBytes: nextWork, publicationLogEstimateBytes: publication.log, availableDiskBytes: disk, walPinnedByReader: walPinned,
            evictableHistory: evictable, admission: admission, limitations: limitations)
    }

    /// Admits work only when it and the next publication's reserve fit under
    /// the cap and the volume can hold the transient publication log. Refusal
    /// is explicit and typed; nothing is evicted here, and the refused demand
    /// becomes the target of the next retention run.
    private func admit(_ work: StorageWork) throws {
        let hint: Int64
        switch work {
        case .generic(let bytes): hint = max(0, bytes)
        case .staging(let rows, let passes): hint = Int64(rows) * (StorageCostModel.stagedRowBytes + StorageCostModel.newPublishedRowBytes) + Int64(passes) * 1_024
        case .publication(let stagedRows, let priorCurrentRows): hint = stagedRows * StorageCostModel.newPublishedRowBytes + priorCurrentRows * 512
        }
        let accounting = try storageAccounting(connection: requireConnection(), capBytes: storageCapBytes, probeCheckpoint: true, demandHint: hint)
        let estimate: Int64
        let reserveAfter: Int64
        let logAfter: Int64
        switch work {
        case .generic(let bytes):
            // Small writes must not consume the headroom held for the next slice.
            estimate = max(0, bytes)
            reserveAfter = accounting.reservedPublicationBytes + accounting.nextWorkReserveBytes
            logAfter = accounting.publicationLogEstimateBytes
        case .staging(let rows, let passes):
            // The slice is the next work itself: its bytes plus the publication
            // of everything staged afterwards is exactly what the accounting's
            // next-work reserve holds for it.
            estimate = Int64(rows) * StorageCostModel.stagedRowBytes + Int64(passes) * 1_024
            let current = try requireConnection().scalarInt("SELECT COUNT(*) FROM current_file_state")
            let after = StorageCostModel.publication(stagedRows: accounting.stagedRowCount + Int64(rows), currentRows: current)
            reserveAfter = after.reserve
            logAfter = after.log
        case .publication(let stagedRows, let priorCurrentRows):
            let cost = StorageCostModel.publication(stagedRows: stagedRows, currentRows: priorCurrentRows)
            estimate = cost.reserve + priorCurrentRows * 512
            reserveAfter = 0
            logAfter = cost.log
        }
        let demand = estimate + reserveAfter
        if accounting.walPinnedByReader, accounting.committedBytes + demand > storageCapBytes {
            pendingStorageDemandBytes = max(pendingStorageDemandBytes, demand)
            throw EvidenceStoreError.storageHeadroomUnavailable(reason: "wal-pinned", demandBytes: demand, accounting: accounting)
        }
        if let disk = accounting.availableDiskBytes, disk < logAfter + StorageCostModel.diskReserveBytes {
            throw EvidenceStoreError.storageHeadroomUnavailable(reason: "disk-space", demandBytes: demand, accounting: accounting)
        }
        guard accounting.committedBytes + demand <= storageCapBytes else {
            pendingStorageDemandBytes = max(pendingStorageDemandBytes, demand)
            if reserveAfter > 0, accounting.committedBytes + estimate <= storageCapBytes {
                throw EvidenceStoreError.storageHeadroomUnavailable(reason: "publication-reserve", demandBytes: demand, accounting: accounting)
            }
            throw EvidenceStoreError.storageCapacityExceeded(currentBytes: accounting.committedBytes, capBytes: storageCapBytes)
        }
        // Only work at least as large as the refused demand proves the refusal
        // obsolete (the cap was raised or space was freed).
        if demand >= pendingStorageDemandBytes { pendingStorageDemandBytes = 0 }
    }

    private func reclaimableStorageBytes(connection: SQLiteConnection) throws -> Int64 {
        let pageCount = try connection.scalarInt("PRAGMA page_count")
        let freePages = try connection.scalarInt("PRAGMA freelist_count")
        let pageSize = try connection.scalarInt("PRAGMA page_size")
        let liveDatabaseBytes = max(0, pageCount - freePages) * pageSize
        return liveDatabaseBytes
            + fileSize(atPath: databaseURL.path + "-wal")
            + fileSize(atPath: databaseURL.path + "-shm")
    }

    private func fileSize(atPath path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func requireConnection() throws -> SQLiteConnection {
        guard let connection else { throw EvidenceStoreError.closed }
        return connection
    }

    private static func validate(_ event: EvidenceStoreEvent) throws {
        guard event.timing == nil else {
            throw EvidenceStoreError.invalidEvent("Measured timing must be recorded through an observation, not a standalone event")
        }
        guard event.observedAt.timeIntervalSince1970.isFinite else {
            throw EvidenceStoreError.invalidEvent("observed_at is not finite")
        }
        guard !event.eventID.isEmpty else { throw EvidenceStoreError.invalidEvent("event_id is empty") }
        guard !event.path.isEmpty else { throw EvidenceStoreError.invalidEvent("path is empty") }
        guard !event.consumerCategory.isEmpty else {
            throw EvidenceStoreError.invalidEvent("consumer_category is empty")
        }
    }

    private static func configure(_ connection: SQLiteConnection, walJournalSizeLimit: Int64 = EvidenceStore.defaultWALJournalSizeLimit) throws {
        try connection.execute("PRAGMA busy_timeout=5000")
        try connection.execute("PRAGMA journal_mode=WAL")
        try connection.execute("PRAGMA synchronous=NORMAL")
        try connection.execute("PRAGMA foreign_keys=ON")
        // A fully checkpointed write-ahead log is truncated to this size when
        // the next writer restarts it, so the log file never stays at its
        // publication peak (2.98 GB at one million files) between samples.
        try connection.execute("PRAGMA journal_size_limit=\(walJournalSizeLimit)")
    }

    public static let defaultWALJournalSizeLimit: Int64 = 16 * 1_024 * 1_024

    public nonisolated static func availableCapacity(at databaseURL: URL) -> Int64? {
        let directory = databaseURL.deletingLastPathComponent()
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return important
        }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    private static func prepareDatabaseForOpen(
        at databaseURL: URL,
        checkpoint: MigrationCheckpoint,
        availableCapacitySource: AvailableCapacitySource
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let shadowURL = databaseURL.appendingPathExtension("migration")

        if !fileManager.fileExists(atPath: databaseURL.path) {
            if fileManager.fileExists(atPath: shadowURL.path) {
                let interruptedShadow = try SQLiteConnection(url: shadowURL)
                do {
                    try configure(interruptedShadow)
                    guard try interruptedShadow.scalarInt("PRAGMA user_version") == Self.currentSchemaVersion,
                          try interruptedShadow.scalarText("PRAGMA quick_check") == "ok"
                    else {
                        throw EvidenceStoreError.sqlite(
                            code: SQLITE_CORRUPT,
                            message: "Interrupted migration shadow is not a valid current database"
                        )
                    }
                    interruptedShadow.close()
                    try atomicRename(from: shadowURL, to: databaseURL)
                } catch {
                    interruptedShadow.close()
                    throw error
                }
            }
            removeSQLiteSidecars(for: shadowURL)
            return
        }

        removeDatabaseIfPresent(at: shadowURL)
        let source = try SQLiteConnection(url: databaseURL)
        defer { source.close() }
        try configure(source)
        let version = try source.scalarInt("PRAGMA user_version")
        guard version <= Self.currentSchemaVersion else {
            throw EvidenceStoreError.sqlite(
                code: SQLITE_MISMATCH,
                message: "Database schema is newer than this application"
            )
        }
        guard version > 0, version < Self.currentSchemaVersion else { return }

        let sourceBytes = sqliteStorageBytes(for: databaseURL)
        let requiredBytes = max(64 * 1_024 * 1_024, sourceBytes * 3 + 16 * 1_024 * 1_024)
        guard let availableBytes = availableCapacitySource(databaseURL) else {
            throw EvidenceStoreError.migrationCapacityUnavailable
        }
        guard availableBytes >= requiredBytes else {
            throw EvidenceStoreError.migrationInsufficientSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }

        try source.backup(to: shadowURL)
        try checkpoint("after-consistent-copy")

        let shadow = try SQLiteConnection(url: shadowURL)
        do {
            try configure(shadow)
            try migrate(shadow)
            guard try shadow.scalarInt("PRAGMA user_version") == Self.currentSchemaVersion,
                  try shadow.scalarText("PRAGMA quick_check") == "ok"
            else {
                throw EvidenceStoreError.sqlite(
                    code: SQLITE_CORRUPT,
                    message: "Migrated shadow database failed validation"
                )
            }
            try shadow.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            shadow.close()
        } catch {
            shadow.close()
            throw error
        }
        try checkpoint("after-shadow-validation")

        source.close()
        removeSQLiteSidecars(for: databaseURL)
        try checkpoint("before-atomic-switch")
        try atomicRename(from: shadowURL, to: databaseURL)
        removeSQLiteSidecars(for: shadowURL)
        try checkpoint("after-atomic-switch")
    }

    private static func atomicRename(from source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw EvidenceStoreError.migrationSwitchFailed(code: errno)
        }
        let directoryDescriptor = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = Darwin.fsync(directoryDescriptor)
            Darwin.close(directoryDescriptor)
        }
    }

    private static func removeDatabaseIfPresent(at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        removeSQLiteSidecars(for: url)
    }

    private static func removeSQLiteSidecars(for url: URL) {
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.removeItem(at: sidecar)
            }
        }
    }

    private static func sqliteStorageBytes(for url: URL) -> Int64 {
        ([url.path, url.path + "-wal", url.path + "-shm"] as [String]).reduce(0) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private static func migrate(_ connection: SQLiteConnection) throws {
        let version = try connection.scalarInt("PRAGMA user_version")
        guard version <= Self.currentSchemaVersion else {
            throw EvidenceStoreError.sqlite(code: SQLITE_MISMATCH, message: "Database schema is newer than this application")
        }
        if version == 0 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE snapshots (
                        snapshot_id TEXT PRIMARY KEY NOT NULL,
                        observed_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX snapshots_observed_at ON snapshots(observed_at);

                    CREATE TABLE events (
                        event_id TEXT PRIMARY KEY NOT NULL,
                        observed_at REAL NOT NULL,
                        operation TEXT NOT NULL,
                        path TEXT NOT NULL,
                        logical_delta INTEGER NOT NULL,
                        allocated_delta INTEGER NOT NULL,
                        consumer_category TEXT NOT NULL,
                        confidence TEXT NOT NULL,
                        is_anomaly INTEGER NOT NULL CHECK(is_anomaly IN (0, 1)),
                        is_reviewed INTEGER NOT NULL CHECK(is_reviewed IN (0, 1))
                    );
                    CREATE INDEX events_observed_at ON events(observed_at);
                    CREATE INDEX events_path_time ON events(path, observed_at);

                    CREATE TABLE hourly_summaries (
                        bucket_start REAL NOT NULL,
                        path TEXT NOT NULL,
                        operation TEXT NOT NULL,
                        event_count INTEGER NOT NULL,
                        logical_delta INTEGER NOT NULL,
                        allocated_delta INTEGER NOT NULL,
                        PRIMARY KEY(bucket_start, path, operation)
                    );

                    CREATE TABLE daily_summaries (
                        bucket_start REAL NOT NULL,
                        path TEXT NOT NULL,
                        operation TEXT NOT NULL,
                        event_count INTEGER NOT NULL,
                        logical_delta INTEGER NOT NULL,
                        allocated_delta INTEGER NOT NULL,
                        PRIMARY KEY(bucket_start, path, operation)
                    );

                    PRAGMA user_version=1;
                    """
                )
            }
        }
        if version < 2 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE scope_versions (
                        scope_version_id TEXT PRIMARY KEY NOT NULL,
                        effective_at REAL NOT NULL,
                        roots_json TEXT NOT NULL,
                        exclusions_json TEXT NOT NULL,
                        maximum_entries INTEGER NOT NULL,
                        maximum_depth INTEGER NOT NULL
                    );

                    CREATE TABLE observation_runs (
                        observation_id TEXT PRIMARY KEY NOT NULL,
                        scope_version_id TEXT NOT NULL REFERENCES scope_versions(scope_version_id),
                        trigger TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        completed_at REAL NOT NULL,
                        coverage TEXT NOT NULL,
                        event_gap INTEGER NOT NULL CHECK(event_gap IN (0, 1))
                    );
                    CREATE INDEX observation_runs_completed_at ON observation_runs(completed_at);

                    CREATE TABLE observation_roots (
                        observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id) ON DELETE CASCADE,
                        root_path TEXT NOT NULL,
                        coverage TEXT NOT NULL,
                        limitations_json TEXT NOT NULL,
                        PRIMARY KEY(observation_id, root_path)
                    );

                    CREATE TABLE file_objects (
                        object_id TEXT PRIMARY KEY NOT NULL,
                        identity_method TEXT NOT NULL,
                        first_observed_at REAL NOT NULL,
                        last_observed_at REAL NOT NULL,
                        lifecycle_state TEXT NOT NULL
                    );

                    CREATE TABLE path_bindings (
                        binding_id TEXT PRIMARY KEY NOT NULL,
                        object_id TEXT NOT NULL REFERENCES file_objects(object_id),
                        path TEXT NOT NULL,
                        valid_from REAL NOT NULL,
                        valid_through REAL,
                        opening_reason TEXT NOT NULL,
                        closing_reason TEXT,
                        confidence TEXT NOT NULL
                    );
                    CREATE INDEX path_bindings_path_time ON path_bindings(path, valid_from, valid_through);

                    CREATE TABLE file_state_observations (
                        observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id) ON DELETE CASCADE,
                        object_id TEXT NOT NULL REFERENCES file_objects(object_id),
                        path TEXT NOT NULL,
                        root_path TEXT NOT NULL,
                        logical_bytes INTEGER NOT NULL,
                        allocated_bytes INTEGER NOT NULL,
                        modified_at REAL,
                        existence TEXT NOT NULL,
                        confidence TEXT NOT NULL,
                        PRIMARY KEY(observation_id, object_id)
                    );

                    CREATE TABLE current_file_state (
                        object_id TEXT PRIMARY KEY NOT NULL REFERENCES file_objects(object_id),
                        identity_method TEXT NOT NULL,
                        path TEXT NOT NULL UNIQUE,
                        root_path TEXT NOT NULL,
                        scope_version_id TEXT NOT NULL REFERENCES scope_versions(scope_version_id),
                        logical_bytes INTEGER NOT NULL,
                        allocated_bytes INTEGER NOT NULL,
                        modified_at REAL,
                        presence TEXT NOT NULL,
                        state_as_of_observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id),
                        observed_at REAL NOT NULL,
                        actionable INTEGER NOT NULL CHECK(actionable IN (0, 1))
                    );
                    CREATE INDEX current_file_state_presence_bytes ON current_file_state(presence, actionable, allocated_bytes DESC);

                    CREATE TABLE change_events (
                        event_id TEXT PRIMARY KEY NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
                        operation TEXT NOT NULL,
                        object_id TEXT NOT NULL REFERENCES file_objects(object_id),
                        before_observation_id TEXT,
                        after_observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id),
                        path_before TEXT,
                        path_after TEXT,
                        logical_delta INTEGER NOT NULL,
                        allocated_delta INTEGER NOT NULL,
                        detected_at REAL NOT NULL,
                        occurred_start REAL NOT NULL,
                        occurred_end REAL NOT NULL,
                        coverage TEXT NOT NULL
                    );
                    CREATE INDEX change_events_object_time ON change_events(object_id, detected_at);

                    CREATE TABLE coverage_gaps (
                        gap_id TEXT PRIMARY KEY NOT NULL,
                        observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id),
                        root_path TEXT NOT NULL,
                        reason TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        ended_at REAL,
                        state TEXT NOT NULL
                    );
                    CREATE INDEX coverage_gaps_time ON coverage_gaps(started_at, ended_at);

                    PRAGMA user_version=2;
                    """
                )
            }
        }
        if version < 3 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE fsevent_hints (
                        hint_id TEXT PRIMARY KEY NOT NULL,
                        observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id) ON DELETE CASCADE,
                        event_id INTEGER NOT NULL,
                        observed_at REAL NOT NULL,
                        path TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        raw_flags INTEGER NOT NULL,
                        requires_rescan INTEGER NOT NULL CHECK(requires_rescan IN (0, 1)),
                        signals_json BLOB NOT NULL,
                        limitations_json BLOB NOT NULL
                    );
                    CREATE INDEX fsevent_hints_observation_event ON fsevent_hints(observation_id, event_id);

                    CREATE TABLE endpoint_observations (
                        endpoint_id TEXT PRIMARY KEY NOT NULL,
                        observation_id TEXT REFERENCES observation_runs(observation_id) ON DELETE SET NULL,
                        evidence_event_id TEXT REFERENCES events(event_id) ON DELETE SET NULL,
                        observed_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX endpoint_observations_event ON endpoint_observations(evidence_event_id, observed_at);

                    CREATE TABLE provenance_claims (
                        claim_id TEXT PRIMARY KEY NOT NULL,
                        event_id TEXT NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
                        method TEXT NOT NULL,
                        confidence TEXT NOT NULL,
                        detected_at REAL NOT NULL,
                        occurred_start REAL NOT NULL,
                        occurred_end REAL NOT NULL,
                        session_registration_id TEXT,
                        supersedes_claim_id TEXT REFERENCES provenance_claims(claim_id),
                        superseded_by_claim_id TEXT REFERENCES provenance_claims(claim_id),
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX provenance_claims_event_time ON provenance_claims(event_id, detected_at);
                    CREATE INDEX provenance_claims_session ON provenance_claims(session_registration_id, occurred_start, occurred_end);

                    CREATE TABLE agent_sessions (
                        registration_id TEXT PRIMARY KEY NOT NULL,
                        session_id TEXT NOT NULL,
                        client TEXT NOT NULL,
                        registered_at REAL NOT NULL,
                        heartbeat_at REAL NOT NULL,
                        expires_at REAL NOT NULL,
                        ended_at REAL,
                        lifecycle TEXT NOT NULL,
                        task_context TEXT,
                        payload BLOB NOT NULL
                    );
                    CREATE INDEX agent_sessions_session_time ON agent_sessions(session_id, registered_at, expires_at);
                    CREATE INDEX agent_sessions_lifecycle_expiry ON agent_sessions(lifecycle, expires_at);

                    PRAGMA user_version=3;
                    """
                )
            }
        }
        if version < 4 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE retention_runs (
                        run_id TEXT PRIMARY KEY NOT NULL,
                        trigger TEXT NOT NULL,
                        policy BLOB NOT NULL,
                        started_at REAL NOT NULL,
                        completed_at REAL,
                        storage_bytes_before INTEGER NOT NULL,
                        storage_bytes_after INTEGER,
                        aggregated_raw_events INTEGER NOT NULL DEFAULT 0,
                        aggregated_hourly_summaries INTEGER NOT NULL DEFAULT 0,
                        deleted_daily_summaries INTEGER NOT NULL DEFAULT 0,
                        deleted_snapshots INTEGER NOT NULL DEFAULT 0,
                        deleted_historical_rows INTEGER NOT NULL DEFAULT 0,
                        forced_evictions INTEGER NOT NULL DEFAULT 0,
                        result TEXT NOT NULL,
                        limitations BLOB NOT NULL
                    );
                    CREATE INDEX retention_runs_started_at ON retention_runs(started_at);

                    CREATE TABLE retention_coverage_gaps (
                        gap_id TEXT PRIMARY KEY NOT NULL,
                        retention_run_id TEXT NOT NULL REFERENCES retention_runs(run_id) ON DELETE CASCADE,
                        reason TEXT NOT NULL,
                        affected_precision TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        rows_removed INTEGER NOT NULL
                    );
                    CREATE INDEX retention_coverage_gaps_started_at ON retention_coverage_gaps(started_at);

                    CREATE TABLE export_records (
                        export_id TEXT PRIMARY KEY NOT NULL,
                        kind TEXT NOT NULL,
                        requested_from REAL NOT NULL,
                        requested_through REAL NOT NULL,
                        actual_from REAL,
                        actual_through REAL,
                        precision TEXT NOT NULL,
                        path_detail TEXT NOT NULL,
                        path TEXT,
                        bytes INTEGER NOT NULL,
                        manifest_sha256 TEXT,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        status TEXT NOT NULL,
                        failure TEXT
                    );
                    CREATE INDEX export_records_updated_at ON export_records(updated_at);

                    PRAGMA user_version=4;
                    """
                )
            }
        }
        if version < 5 {
            try connection.transaction {
                try connection.execute(
                    """
                    CREATE TABLE scan_generations (
                        generation_id TEXT PRIMARY KEY NOT NULL,
                        scope_version_id TEXT NOT NULL REFERENCES scope_versions(scope_version_id),
                        status TEXT NOT NULL,
                        started_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        completed_at REAL,
                        processed_entry_count INTEGER NOT NULL,
                        staged_file_count INTEGER NOT NULL,
                        progress BLOB NOT NULL
                    );
                    CREATE INDEX scan_generations_status_updated ON scan_generations(status, updated_at);

                    CREATE TABLE scan_generation_entries (
                        generation_id TEXT NOT NULL REFERENCES scan_generations(generation_id) ON DELETE CASCADE,
                        path TEXT NOT NULL,
                        payload BLOB NOT NULL,
                        PRIMARY KEY(generation_id, path)
                    );

                    PRAGMA user_version=5;
                    """
                )
            }
        }
        if version < 6 {
            let existingColumns = try tableColumns("scan_generation_entries", connection: connection)
            try connection.transaction {
                let additions = [
                    ("object_id", "TEXT"),
                    ("identity_method", "TEXT"),
                    ("root_path", "TEXT"),
                    ("logical_bytes", "INTEGER"),
                    ("allocated_bytes", "INTEGER"),
                    ("modified_at", "REAL"),
                    ("link_count", "INTEGER"),
                ]
                for (name, type) in additions where !existingColumns.contains(name) {
                    try connection.execute("ALTER TABLE scan_generation_entries ADD COLUMN \(name) \(type)")
                }
                try connection.execute(
                    "CREATE INDEX IF NOT EXISTS scan_generation_entries_object_path ON scan_generation_entries(generation_id, object_id, path)"
                )
                try connection.execute(
                    """
                    CREATE TABLE IF NOT EXISTS reconciliation_invalidations (
                        invalidation_id TEXT PRIMARY KEY NOT NULL,
                        root_path TEXT NOT NULL,
                        reason TEXT NOT NULL,
                        observed_at REAL NOT NULL,
                        resolved_at REAL,
                        state TEXT NOT NULL CHECK(state IN ('open', 'resolved'))
                    )
                    """
                )
                try connection.execute(
                    "CREATE INDEX IF NOT EXISTS reconciliation_invalidations_state_time ON reconciliation_invalidations(state, observed_at)"
                )
            }
            try backfillScanGenerationEntryColumns(connection)
            try connection.execute("PRAGMA user_version=6")
        } else {
            // Version 6 originally set user_version before its bounded backfill.
            // Re-running this idempotently repairs databases interrupted in that window.
            try backfillScanGenerationEntryColumns(connection)
        }
        if version < 7 {
            try connection.transaction {
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS scan_directory_passes (
                        generation_id TEXT NOT NULL REFERENCES scan_generations(generation_id) ON DELETE CASCADE,
                        directory_path TEXT NOT NULL,
                        root_path TEXT NOT NULL,
                        payload BLOB NOT NULL,
                        PRIMARY KEY(generation_id, directory_path)
                    );
                    CREATE INDEX IF NOT EXISTS scan_directory_passes_root ON scan_directory_passes(generation_id, root_path);
                    PRAGMA user_version=7;
                    """)
            }
        }
        if version < 8 {
            try connection.transaction {
                try connection.execute("""
                    ALTER TABLE scan_generation_entries RENAME TO legacy_scan_generation_entries;
                    DROP INDEX IF EXISTS scan_generation_entries_object_path;
                    CREATE TABLE scan_generation_entries (
                        generation_id TEXT NOT NULL REFERENCES scan_generations(generation_id) ON DELETE CASCADE,
                        path TEXT NOT NULL,
                        payload BLOB NOT NULL,
                        object_id TEXT,
                        identity_method TEXT,
                        root_path TEXT NOT NULL,
                        logical_bytes INTEGER,
                        allocated_bytes INTEGER,
                        modified_at REAL,
                        link_count INTEGER,
                        directory_path TEXT,
                        pass_id TEXT,
                        observed_at REAL,
                        PRIMARY KEY(generation_id, root_path, path)
                    );
                    INSERT INTO scan_generation_entries
                        (generation_id, path, payload, object_id, identity_method, root_path, logical_bytes, allocated_bytes, modified_at, link_count)
                        SELECT generation_id, path, payload, object_id, identity_method, COALESCE(root_path, ''), logical_bytes, allocated_bytes, modified_at, link_count
                        FROM legacy_scan_generation_entries;
                    DROP TABLE legacy_scan_generation_entries;
                    CREATE INDEX scan_generation_entries_object_path ON scan_generation_entries(generation_id, object_id, path);
                    CREATE INDEX scan_generation_entries_pass ON scan_generation_entries(generation_id, root_path, directory_path, pass_id);
                    DROP TABLE scan_directory_passes;
                    CREATE TABLE scan_directory_passes (
                        generation_id TEXT NOT NULL REFERENCES scan_generations(generation_id) ON DELETE CASCADE,
                        root_path TEXT NOT NULL,
                        directory_path TEXT NOT NULL,
                        pass_id TEXT NOT NULL,
                        payload BLOB NOT NULL,
                        PRIMARY KEY(generation_id, root_path, directory_path),
                        UNIQUE(generation_id, pass_id)
                    );
                    CREATE INDEX scan_directory_passes_validation ON scan_directory_passes(generation_id, directory_path, root_path);
                    PRAGMA user_version=8;
                    """)
            }
        }
        if version < 9 {
            try connection.transaction {
                // Historical observations did not retain their sample time.
                // NULL is deliberate: run completion is not a substitute.
                try connection.execute("ALTER TABLE file_state_observations ADD COLUMN observed_at REAL")
                // Receipt state shares each hint's retention lifecycle. Old
                // gap receipts are unknown and conservatively reset once.
                try connection.execute("ALTER TABLE fsevent_hints ADD COLUMN gap_recorded INTEGER NOT NULL DEFAULT 0 CHECK(gap_recorded IN (0, 1))")
                // A first sighting is not proof of an exact creation time.
                // Historical inverted ranges are not repaired by swapping
                // endpoints: preserve their measured upper/detection values
                // and explicitly withdraw the unsupported lower bound.
                try connection.execute("""
                    CREATE TABLE change_events_with_bounds (
                        event_id TEXT PRIMARY KEY NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
                        operation TEXT NOT NULL,
                        object_id TEXT NOT NULL REFERENCES file_objects(object_id),
                        before_observation_id TEXT,
                        after_observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id),
                        path_before TEXT,
                        path_after TEXT,
                        logical_delta INTEGER NOT NULL,
                        allocated_delta INTEGER NOT NULL,
                        detected_at REAL NOT NULL,
                        occurred_start REAL,
                        occurred_end REAL NOT NULL,
                        coverage TEXT NOT NULL,
                        CHECK(occurred_start IS NULL OR occurred_start <= occurred_end)
                    );
                    INSERT INTO change_events_with_bounds
                        SELECT event_id, operation, object_id, before_observation_id, after_observation_id,
                               path_before, path_after, logical_delta, allocated_delta, detected_at,
                               CASE WHEN before_observation_id IS NULL OR occurred_start > occurred_end
                                    THEN NULL ELSE occurred_start END,
                               occurred_end, coverage
                        FROM change_events;
                    DROP TABLE change_events;
                    ALTER TABLE change_events_with_bounds RENAME TO change_events;
                    CREATE INDEX change_events_object_time ON change_events(object_id, detected_at);
                    """)
                try connection.execute("PRAGMA user_version=9")
            }
        }
        if version < 10 {
            try connection.transaction {
                // Existing dates remain available as legacy evidence, but are
                // not asserted to have the measured semantics of new events.
                try connection.execute("""
                    ALTER TABLE change_events ADD COLUMN timing_version INTEGER NOT NULL DEFAULT 0 CHECK(timing_version IN (0, 1));
                    CREATE VIEW event_evidence AS
                        SELECT e.*, c.occurred_start, c.occurred_end, c.detected_at
                        FROM events e LEFT JOIN change_events c
                          ON c.event_id = e.event_id AND c.timing_version = 1;
                    PRAGMA user_version=10;
                    """)
            }
        }
        if version < 11 {
            try connection.transaction {
                try connection.execute("""
                    ALTER TABLE current_file_state ADD COLUMN timing_verified INTEGER NOT NULL DEFAULT 0 CHECK(timing_verified IN (0, 1));
                    ALTER TABLE path_bindings ADD COLUMN timing_verified INTEGER NOT NULL DEFAULT 0 CHECK(timing_verified IN (0, 1));
                    UPDATE change_events SET timing_version = 0;
                    PRAGMA user_version=11;
                    """)
                // Preview v10 could promote legacy lower bounds into new
                // events. Keep its original dates but withdraw that assertion.
            }
        }
        if version < 12 {
            try connection.transaction {
                // Keep historical bytes and dates intact, but do not let the
                // former non-null discovery-time default act as a known bound.
                try connection.execute("""
                    PRAGMA defer_foreign_keys=ON;
                    CREATE TABLE provenance_claims_with_bounds (
                        claim_id TEXT PRIMARY KEY NOT NULL,
                        event_id TEXT NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
                        method TEXT NOT NULL,
                        confidence TEXT NOT NULL,
                        detected_at REAL NOT NULL,
                        occurred_start REAL,
                        occurred_end REAL NOT NULL,
                        session_registration_id TEXT,
                        supersedes_claim_id TEXT REFERENCES provenance_claims_with_bounds(claim_id),
                        superseded_by_claim_id TEXT REFERENCES provenance_claims_with_bounds(claim_id),
                        payload BLOB NOT NULL,
                        legacy_occurred_start REAL,
                        timing_version INTEGER NOT NULL DEFAULT 0 CHECK(timing_version IN (0, 1)),
                        CHECK(occurred_start IS NULL OR occurred_start <= occurred_end)
                    );
                    INSERT INTO provenance_claims_with_bounds
                        SELECT claim_id, event_id, method, confidence, detected_at, NULL, occurred_end,
                               session_registration_id, supersedes_claim_id, superseded_by_claim_id,
                               payload, occurred_start, 0 FROM provenance_claims;
                    DROP TABLE provenance_claims;
                    ALTER TABLE provenance_claims_with_bounds RENAME TO provenance_claims;
                    CREATE INDEX provenance_claims_event_time ON provenance_claims(event_id, detected_at);
                    CREATE INDEX provenance_claims_session ON provenance_claims(session_registration_id, occurred_start, occurred_end);
                    CREATE INDEX provenance_claims_interval ON provenance_claims(occurred_end, occurred_start, detected_at, claim_id);
                    PRAGMA user_version=12;
                    """)
            }
        }
        if version < 13 {
            try connection.transaction {
                // Historical progress is deliberately not decoded/backfilled:
                // its optional counters remain unknown until the next write.
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS scan_generation_summaries (
                        generation_id TEXT PRIMARY KEY NOT NULL REFERENCES scan_generations(generation_id) ON DELETE CASCADE,
                        completed_root_count INTEGER NOT NULL CHECK(completed_root_count >= 0),
                        pending_directory_count INTEGER NOT NULL CHECK(pending_directory_count >= 0),
                        total_root_count INTEGER NOT NULL CHECK(total_root_count >= completed_root_count)
                    );
                    PRAGMA user_version=13;
                    """)
            }
        }
        if version < 14 {
            try connection.transaction {
                // Durable scan frontier beyond each root's bounded in-memory
                // window. Rows are moved into the window in discovery order and
                // removed with their generation; never a growing progress blob.
                try connection.execute("""
                    CREATE TABLE IF NOT EXISTS scan_frontier (
                        generation_id TEXT NOT NULL REFERENCES scan_generations(generation_id) ON DELETE CASCADE,
                        root_path TEXT NOT NULL,
                        directory_path TEXT NOT NULL,
                        depth INTEGER NOT NULL CHECK(depth >= 0),
                        sequence INTEGER NOT NULL,
                        PRIMARY KEY (generation_id, root_path, directory_path)
                    ) WITHOUT ROWID;
                    CREATE INDEX IF NOT EXISTS scan_frontier_order ON scan_frontier(generation_id, root_path, sequence);
                    -- Publication revalidates every object's open bindings by object.
                    -- Without an object-leading index each lookup scanned the
                    -- whole table, making reconciliation quadratic in file count.
                    CREATE INDEX IF NOT EXISTS path_bindings_object_path ON path_bindings(object_id, path, valid_through);
                    PRAGMA user_version=14;
                    """)
            }
        }
        guard try connection.scalarText("PRAGMA quick_check") == "ok" else {
            throw EvidenceStoreError.sqlite(code: SQLITE_CORRUPT, message: "Database integrity check failed")
        }
    }

    private static func tableColumns(
        _ table: String,
        connection: SQLiteConnection
    ) throws -> Set<String> {
        try connection.withStatement("PRAGMA table_info(\(table))") { statement in
            var columns: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = columnString(statement, column: 1) {
                    columns.insert(name)
                }
            }
            return columns
        }
    }

    private static func backfillScanGenerationEntryColumns(_ connection: SQLiteConnection) throws {
        let decoder = JSONDecoder()
        while true {
            let rows = try connection.withStatement(
                "SELECT generation_id, path, payload FROM scan_generation_entries WHERE object_id IS NULL ORDER BY generation_id, path LIMIT 512"
            ) { statement -> [(String, String, FileMetadata)] in
                var values: [(String, String, FileMetadata)] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let generationID = columnString(statement, column: 0),
                          let path = columnString(statement, column: 1),
                          let bytes = sqlite3_column_blob(statement, 2)
                    else { throw connection.lastError(SQLITE_CORRUPT) }
                    let count = Int(sqlite3_column_bytes(statement, 2))
                    values.append((
                        generationID,
                        path,
                        try decoder.decode(FileMetadata.self, from: Data(bytes: bytes, count: count))
                    ))
                }
                return values
            }
            guard !rows.isEmpty else { return }
            try connection.transaction {
                for (generationID, path, entry) in rows {
                    try connection.withStatement(
                        "UPDATE scan_generation_entries SET object_id = ?, identity_method = ?, root_path = ?, logical_bytes = ?, allocated_bytes = ?, modified_at = ?, link_count = ? WHERE generation_id = ? AND path = ?"
                    ) { statement in
                        try connection.bind(entry.objectID, at: 1, in: statement)
                        try connection.bind(entry.identityMethod.rawValue, at: 2, in: statement)
                        try connection.bind(entry.rootPath, at: 3, in: statement)
                        try connection.bind(entry.logicalBytes, at: 4, in: statement)
                        try connection.bind(entry.allocatedBytes, at: 5, in: statement)
                        try connection.bind(entry.modifiedAt?.timeIntervalSince1970, at: 6, in: statement)
                        try connection.bind(Int64(entry.linkCount), at: 7, in: statement)
                        try connection.bind(generationID, at: 8, in: statement)
                        try connection.bind(path, at: 9, in: statement)
                        try connection.stepDone(statement)
                    }
                }
            }
        }
    }

    private static func recoverInterruptedLifecycles(_ connection: SQLiteConnection, at date: Date) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let staleCutoff = date.addingTimeInterval(-6 * 60 * 60).timeIntervalSince1970
        let retentionLimitations = try encoder.encode(["The process stopped before this retention run completed; no completion result is inferred."])
        try connection.withStatement(
            "UPDATE retention_runs SET completed_at = ?, storage_bytes_after = storage_bytes_before, result = 'failed', limitations = ? WHERE result = 'started' AND started_at < ?"
        ) { statement in
            try connection.bind(date.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(retentionLimitations, at: 2, in: statement)
            try connection.bind(staleCutoff, at: 3, in: statement)
            try connection.stepDone(statement)
        }
        try connection.withStatement(
            "UPDATE export_records SET updated_at = ?, status = 'failed', failure = 'The process stopped before the export lifecycle completed.' WHERE status IN ('creating', 'served') AND updated_at < ?"
        ) { statement in
            try connection.bind(date.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(staleCutoff, at: 2, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func readScanGeneration(
        status: MetadataScanGenerationStatus?,
        connection: SQLiteConnection
    ) throws -> MetadataScanGeneration? {
        let sql = status == nil
            ? "SELECT progress FROM scan_generations ORDER BY updated_at DESC, CASE status WHEN 'active' THEN 0 WHEN 'completed' THEN 1 ELSE 2 END, generation_id DESC LIMIT 1"
            : "SELECT progress FROM scan_generations WHERE status = ? ORDER BY updated_at DESC, generation_id DESC LIMIT 1"
        return try connection.withStatement(sql) { statement in
            if let status { try connection.bind(status.rawValue, at: 1, in: statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0)
            else { return nil }
            let count = Int(sqlite3_column_bytes(statement, 0))
            return try JSONDecoder().decode(MetadataScanGeneration.self, from: Data(bytes: bytes, count: count))
        }
    }

    /// Keeps each root's in-memory frontier at the bounded window: newly
    /// discovered directories and any legacy oversized window spill into
    /// durable rows, durable rows refill a draining window in discovery order,
    /// and the remaining durable count is recorded so a root completes only
    /// when both are empty. Runs inside the caller's transaction.
    private static func synchronizeFrontier(
        _ generation: MetadataScanGeneration,
        discovered: [MetadataScanDiscoveredDirectory],
        connection: SQLiteConnection
    ) throws -> MetadataScanGeneration {
        let window = DirectoryMetadataScanner.frontierWindowSize
        var sequence = try connection.withStatement("SELECT COALESCE(MAX(sequence), 0) FROM scan_frontier WHERE generation_id = ?") { statement -> Int64 in
            try connection.bind(generation.generationID, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return sqlite3_column_int64(statement, 0)
        }
        func insert(rootPath: String, directoryPath: String, depth: Int) throws {
            sequence += 1
            try connection.withStatement(
                "INSERT OR IGNORE INTO scan_frontier (generation_id, root_path, directory_path, depth, sequence) VALUES (?, ?, ?, ?, ?)"
            ) { statement in
                try connection.bind(generation.generationID, at: 1, in: statement)
                try connection.bind(rootPath, at: 2, in: statement)
                try connection.bind(directoryPath, at: 3, in: statement)
                try connection.bind(Int64(depth), at: 4, in: statement)
                try connection.bind(sequence, at: 5, in: statement)
                try connection.stepDone(statement)
            }
        }
        let failedRoots = Set(generation.roots.filter { $0.status == .failed }.map(\.rootPath))
        for item in discovered where !failedRoots.contains(item.rootPath) {
            try insert(rootPath: item.rootPath, directoryPath: item.directoryPath, depth: item.depth)
        }
        var roots: [MetadataScanRootProgress] = []
        for root in generation.roots {
            var frontier = root.frontier
            if frontier.count > window {
                for cursor in frontier[window...] {
                    try insert(rootPath: root.rootPath, directoryPath: cursor.directoryPath, depth: cursor.depth)
                }
                frontier = Array(frontier.prefix(window))
            }
            if root.status == .pending || root.status == .active, frontier.count < window {
                let moved = try connection.withStatement(
                    "SELECT directory_path, depth FROM scan_frontier WHERE generation_id = ? AND root_path = ? ORDER BY sequence LIMIT ?"
                ) { statement -> [(String, Int)] in
                    try connection.bind(generation.generationID, at: 1, in: statement)
                    try connection.bind(root.rootPath, at: 2, in: statement)
                    try connection.bind(Int64(window - frontier.count), at: 3, in: statement)
                    var values: [(String, Int)] = []
                    while sqlite3_step(statement) == SQLITE_ROW {
                        guard let directory = columnString(statement, column: 0) else { throw connection.lastError(SQLITE_CORRUPT) }
                        values.append((directory, Int(sqlite3_column_int64(statement, 1))))
                    }
                    return values
                }
                for (directory, depth) in moved {
                    frontier.append(.init(directoryPath: directory, depth: depth))
                    try connection.withStatement("DELETE FROM scan_frontier WHERE generation_id = ? AND root_path = ? AND directory_path = ?") { statement in
                        try connection.bind(generation.generationID, at: 1, in: statement)
                        try connection.bind(root.rootPath, at: 2, in: statement)
                        try connection.bind(directory, at: 3, in: statement)
                        try connection.stepDone(statement)
                    }
                }
            }
            let pending = try connection.withStatement("SELECT COUNT(*) FROM scan_frontier WHERE generation_id = ? AND root_path = ?") { statement -> Int64 in
                try connection.bind(generation.generationID, at: 1, in: statement)
                try connection.bind(root.rootPath, at: 2, in: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
                return sqlite3_column_int64(statement, 0)
            }
            roots.append(.init(
                rootPath: root.rootPath, status: root.status, frontier: frontier,
                processedEntryCount: root.processedEntryCount, observedFileCount: root.observedFileCount,
                limitations: root.limitations, pendingDirectoryCount: Int(pending)
            ))
        }
        return copyScanGeneration(generation, roots: roots)
    }

    private static func deleteFrontier(generationID: String, rootPath: String? = nil, connection: SQLiteConnection) throws {
        try connection.withStatement("DELETE FROM scan_frontier WHERE generation_id = ? AND (? IS NULL OR root_path = ?)") { statement in
            try connection.bind(generationID, at: 1, in: statement)
            try connection.bind(rootPath, at: 2, in: statement)
            try connection.bind(rootPath, at: 3, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func persistScanGeneration(
        _ generation: MetadataScanGeneration,
        rowStatus: MetadataScanGenerationStatus,
        connection: SQLiteConnection
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let progress = try encoder.encode(generation)
        try connection.withStatement(
            "INSERT INTO scan_generations (generation_id, scope_version_id, status, started_at, updated_at, completed_at, processed_entry_count, staged_file_count, progress) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(generation_id) DO UPDATE SET status = excluded.status, updated_at = excluded.updated_at, completed_at = excluded.completed_at, processed_entry_count = excluded.processed_entry_count, staged_file_count = excluded.staged_file_count, progress = excluded.progress"
        ) { statement in
            try connection.bind(generation.generationID, at: 1, in: statement)
            try connection.bind(generation.scopeVersionID, at: 2, in: statement)
            try connection.bind(rowStatus.rawValue, at: 3, in: statement)
            try connection.bind(generation.startedAt.timeIntervalSince1970, at: 4, in: statement)
            try connection.bind(generation.updatedAt.timeIntervalSince1970, at: 5, in: statement)
            try connection.bind(generation.completedAt?.timeIntervalSince1970, at: 6, in: statement)
            try connection.bind(Int64(generation.processedEntryCount), at: 7, in: statement)
            try connection.bind(Int64(generation.stagedFileCount), at: 8, in: statement)
            try connection.bind(progress, at: 9, in: statement)
            try connection.stepDone(statement)
        }
        // Same transaction as the private progress write and publication. This
        // adds constant-sized metadata, independent of frontier width/depth.
        let pending = try generation.roots.reduce(Int64(0)) { total, root in
            let (value, overflow) = total.addingReportingOverflow(Int64(root.frontier.count + (root.pendingDirectoryCount ?? 0)))
            guard !overflow else { throw EvidenceStoreError.invalidObservation("Scan summary counter overflow") }
            return value
        }
        try connection.withStatement("INSERT INTO scan_generation_summaries VALUES (?, ?, ?, ?) ON CONFLICT(generation_id) DO UPDATE SET completed_root_count = excluded.completed_root_count, pending_directory_count = excluded.pending_directory_count, total_root_count = excluded.total_root_count") { statement in
            try connection.bind(generation.generationID, at: 1, in: statement)
            try connection.bind(Int64(generation.completedRootCount), at: 2, in: statement)
            try connection.bind(pending, at: 3, in: statement)
            try connection.bind(Int64(generation.roots.count), at: 4, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func readStagedScanEntries(
        generationID: String,
        connection: SQLiteConnection
    ) throws -> [FileMetadata] {
        try connection.withStatement(
            "SELECT payload FROM scan_generation_entries WHERE generation_id = ? ORDER BY path"
        ) { statement in
            try connection.bind(generationID, at: 1, in: statement)
            var entries: [FileMetadata] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw connection.lastError(SQLITE_CORRUPT) }
                let count = Int(sqlite3_column_bytes(statement, 0))
                entries.append(try JSONDecoder().decode(FileMetadata.self, from: Data(bytes: bytes, count: count)))
            }
            return entries
        }
    }

    private func boundedCommitResult(
        observationID: String,
        events: [EvidenceStoreEvent],
        persistedEventCount: Int,
        connection: SQLiteConnection
    ) throws -> ObservationCommitResult {
        let currentFileCount = Int(try connection.scalarInt("SELECT COUNT(*) FROM current_file_state"))
        let currentFiles = try readCurrentFiles(
            connection: connection,
            includeNonActionable: true,
            limit: Self.maximumInlineCommitRows
        )
        return ObservationCommitResult(
            observationID: observationID,
            events: events,
            currentFiles: currentFiles,
            coverageGaps: try readCoverageGaps(connection: connection, observationID: observationID),
            persistedEventCount: persistedEventCount,
            currentFileCount: currentFileCount,
            resultWindowTruncated: persistedEventCount > events.count || currentFileCount > currentFiles.count
        )
    }

    private static func latestCurrentObservationDate(connection: SQLiteConnection) throws -> Date? {
        try connection.withStatement("SELECT MAX(observed_at) FROM current_file_state") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    private static func earliestOpenInvalidationDate(connection: SQLiteConnection) throws -> Date? {
        try connection.withStatement(
            "SELECT MIN(observed_at) FROM reconciliation_invalidations WHERE state = 'open'"
        ) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    private static func upsertReconciliationInvalidation(
        rootPath: String,
        reason: String,
        at date: Date,
        connection: SQLiteConnection
    ) throws {
        let invalidationID = "invalidation-\(stableIdentifier("\(rootPath)|\(reason)"))"
        try connection.withStatement(
            """
            INSERT INTO reconciliation_invalidations (
                invalidation_id, root_path, reason, observed_at, resolved_at, state
            ) VALUES (?, ?, ?, ?, NULL, 'open')
            ON CONFLICT(invalidation_id) DO UPDATE SET
                observed_at = CASE
                    WHEN reconciliation_invalidations.state = 'open'
                        THEN MIN(reconciliation_invalidations.observed_at, excluded.observed_at)
                    ELSE excluded.observed_at
                END,
                resolved_at = NULL,
                state = 'open'
            """
        ) { statement in
            try connection.bind(invalidationID, at: 1, in: statement)
            try connection.bind(rootPath, at: 2, in: statement)
            try connection.bind(reason, at: 3, in: statement)
            try connection.bind(date.timeIntervalSince1970, at: 4, in: statement)
            try connection.stepDone(statement)
        }
        // This runs in the invalidation receipt transaction (including the
        // FSEvents route). Reset only intersecting roots; healthy independent
        // staging is retained. The token also fences work scanned off-actor.
        guard let generation = try readScanGeneration(status: .active, connection: connection) else { return }
        var affected = false
        let roots = try generation.roots.map { root -> MetadataScanRootProgress in
            guard rootPath == "*" || path(rootPath, isWithin: root.rootPath) || path(root.rootPath, isWithin: rootPath) else { return root }
            affected = true
            try invalidateDirectoryPass(root.rootPath, rootPath: root.rootPath, generationID: generation.generationID, connection: connection)
            return .init(rootPath: root.rootPath, status: .active,
                         frontier: [.init(directoryPath: root.rootPath, depth: 0)],
                         processedEntryCount: root.processedEntryCount,
                         observedFileCount: 0)
        }
        guard affected else { return }
        let stagedCount = Int(try connection.scalarInt("SELECT COUNT(DISTINCT path) FROM scan_generation_entries WHERE generation_id = '\(sqlLiteral(generation.generationID))'"))
        let restarted = copyScanGeneration(generation, status: .active, stagedFileCount: stagedCount,
            updatedAt: max(date, generation.updatedAt),
            limitations: generation.limitations + ["New dirty evidence restarted affected roots; superseded observations cannot prove current presence or absence."],
            roots: roots, reconciliationToken: UUID().uuidString.lowercased())
        try persistScanGeneration(restarted, rowStatus: .active, connection: connection)
    }

    private static func resolveReconciliationInvalidations(generation: MetadataScanGeneration, at date: Date, connection: SQLiteConnection) throws {
        try connection.withStatement(
            "SELECT invalidation_id, root_path FROM reconciliation_invalidations WHERE state = 'open'"
        ) { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = columnString(statement, column: 0), let root = columnString(statement, column: 1) else {
                    throw connection.lastError(SQLITE_CORRUPT)
                }
                let affectedRoots = generation.roots.filter {
                    root == "*" || path(root, isWithin: $0.rootPath) || path($0.rootPath, isWithin: root)
                }
                let covered = !affectedRoots.isEmpty && affectedRoots.allSatisfy { $0.status == .completed }
                guard covered else { continue }
                try connection.withStatement("UPDATE reconciliation_invalidations SET resolved_at = ?, state = 'resolved' WHERE invalidation_id = ?") { update in
                    try connection.bind(date.timeIntervalSince1970, at: 1, in: update)
                    try connection.bind(id, at: 2, in: update)
                    try connection.stepDone(update)
                }
            }
        }
    }

    private static func readCurrentFile(
        objectID: String? = nil,
        path: String? = nil,
        fromPriorSnapshot: Bool = false,
        connection: SQLiteConnection
    ) throws -> CurrentFileStateRecord? {
        precondition((objectID == nil) != (path == nil))
        let column = objectID == nil ? "path" : "object_id"
        let table = fromPriorSnapshot ? "reconcile_prior_current" : "current_file_state"
        return try connection.withStatement(
            "SELECT object_id, identity_method, path, root_path, scope_version_id, logical_bytes, allocated_bytes, modified_at, presence, state_as_of_observation_id, observed_at, actionable FROM \(table) WHERE \(column) = ? LIMIT 1"
        ) { statement in
            try connection.bind(objectID ?? path!, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeCurrentFile(statement, connection: connection)
        }
    }

    private static func readPriorFileAtPath(_ path: String, connection: SQLiteConnection) throws -> CurrentFileStateRecord? {
        let objectID = try connection.withStatement("SELECT object_id FROM reconcile_prior_paths WHERE path = ? ORDER BY object_id LIMIT 1") { statement -> String? in
            try connection.bind(path, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columnString(statement, column: 0)
        }
        if let objectID { return try readCurrentFile(objectID: objectID, fromPriorSnapshot: true, connection: connection) }
        let historical = try readCurrentFile(path: path, fromPriorSnapshot: true, connection: connection)
        return historical?.presence == .outOfScope ? nil : historical
    }

    private static func restorePriorCurrent(
        _ old: CurrentFileStateRecord,
        path: String,
        rootPath: String,
        presence: CurrentFilePresence,
        scope: EvidenceScopeVersion,
        connection: SQLiteConnection
    ) throws {
        try connection.withStatement("""
            INSERT INTO current_file_state (object_id, identity_method, path, root_path, scope_version_id,
                logical_bytes, allocated_bytes, modified_at, presence, state_as_of_observation_id, observed_at, actionable, timing_verified)
            SELECT object_id, identity_method, ?, ?, ?, logical_bytes, allocated_bytes, modified_at, ?,
                state_as_of_observation_id, observed_at, 0, timing_verified FROM reconcile_prior_current WHERE object_id = ?
            """) { statement in
            try connection.bind(path, at: 1, in: statement)
            try connection.bind(rootPath, at: 2, in: statement)
            try connection.bind(scope.scopeVersionID, at: 3, in: statement)
            try connection.bind(presence.rawValue, at: 4, in: statement)
            try connection.bind(old.objectID, at: 5, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func decodeCurrentFile(
        _ statement: OpaquePointer,
        connection: SQLiteConnection
    ) throws -> CurrentFileStateRecord {
        guard let objectID = columnString(statement, column: 0),
              let identityText = columnString(statement, column: 1),
              let identity = FileIdentityMethod(rawValue: identityText),
              let path = columnString(statement, column: 2),
              let rootPath = columnString(statement, column: 3),
              let scopeVersionID = columnString(statement, column: 4),
              let presenceText = columnString(statement, column: 8),
              let presence = CurrentFilePresence(rawValue: presenceText),
              let observationID = columnString(statement, column: 9)
        else { throw connection.lastError(SQLITE_CORRUPT) }
        return CurrentFileStateRecord(
            objectID: objectID,
            identityMethod: identity,
            path: path,
            rootPath: rootPath,
            scopeVersionID: scopeVersionID,
            logicalBytes: sqlite3_column_int64(statement, 5),
            allocatedBytes: sqlite3_column_int64(statement, 6),
            modifiedAt: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            presence: presence,
            stateAsOfObservationID: observationID,
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            actionable: sqlite3_column_int64(statement, 11) == 1
        )
    }

    private static func readCanonicalStagedFile(
        input: ReconciliationInput,
        generationID: String,
        objectID: String,
        preferredPath: String?,
        connection: SQLiteConnection
    ) throws -> (FileMetadata, Int, Int) {
        let counts = try connection.withStatement(
            "SELECT COUNT(*), COALESCE(MAX(link_count), 1) FROM \(input.table) WHERE generation_id = ? AND object_id = ?"
        ) { statement -> (Int, Int) in
            try connection.bind(generationID, at: 1, in: statement)
            try connection.bind(objectID, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
        }
        // A stable display path must not suppress fresher object metadata from
        // another hard link. Keep the actual newest sample and its path/time
        // together; prefer the previous path only when timestamps tie.
        let file = try connection.withStatement(
            "SELECT object_id, identity_method, root_path, path, logical_bytes, allocated_bytes, modified_at, link_count, payload FROM \(input.table) WHERE generation_id = ? AND object_id = ? ORDER BY observed_at DESC, CASE WHEN path = ? THEN 0 ELSE 1 END, path LIMIT 1"
        ) { statement -> FileMetadata in
            try connection.bind(generationID, at: 1, in: statement)
            try connection.bind(objectID, at: 2, in: statement)
            try connection.bind(preferredPath ?? "", at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return try decodeStagedFile(statement, effectiveLinkCount: max(counts.0, counts.1), connection: connection)
        }
        return (file, counts.0, counts.1)
    }

    private static func decodeStagedFile(
        _ statement: OpaquePointer,
        effectiveLinkCount: Int? = nil,
        connection: SQLiteConnection
    ) throws -> FileMetadata {
        guard let objectID = columnString(statement, column: 0),
              let identityText = columnString(statement, column: 1),
              let identity = FileIdentityMethod(rawValue: identityText),
              let rootPath = columnString(statement, column: 2),
              let path = columnString(statement, column: 3)
        else { throw connection.lastError(SQLITE_CORRUPT) }
        struct ObservationTime: Decodable { let observedAt: Date? }
        guard let payload = sqlite3_column_blob(statement, 8) else { throw connection.lastError(SQLITE_CORRUPT) }
        let time = try JSONDecoder().decode(ObservationTime.self, from: Data(bytes: payload, count: Int(sqlite3_column_bytes(statement, 8))))
        return FileMetadata(
            objectID: objectID,
            identityMethod: identity,
            rootPath: rootPath,
            path: path,
            logicalBytes: sqlite3_column_int64(statement, 4),
            allocatedBytes: sqlite3_column_int64(statement, 5),
            modifiedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            linkCount: effectiveLinkCount ?? Int(sqlite3_column_int64(statement, 7)),
            observedAt: time.observedAt
        )
    }

    private static func forEachStagedFile(
        input: ReconciliationInput,
        generationID: String,
        objectID: String,
        connection: SQLiteConnection,
        body: (FileMetadata) throws -> Void
    ) throws {
        var afterPath = ""
        while true {
            let file = try connection.withStatement(
                "SELECT object_id, identity_method, root_path, path, logical_bytes, allocated_bytes, modified_at, link_count, payload FROM \(input.table) WHERE generation_id = ? AND object_id = ? AND path > ? ORDER BY path LIMIT 1"
            ) { statement -> FileMetadata? in
                try connection.bind(generationID, at: 1, in: statement)
                try connection.bind(objectID, at: 2, in: statement)
                try connection.bind(afterPath, at: 3, in: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return try decodeStagedFile(statement, connection: connection)
            }
            guard let file else { return }
            afterPath = file.path
            try body(file)
        }
    }

    private static func forEachOpenPath(
        objectID: String,
        connection: SQLiteConnection,
        body: (String) throws -> Void
    ) throws {
        var afterPath = ""
        while true {
            let path = try connection.withStatement(
                "SELECT path FROM path_bindings WHERE object_id = ? AND valid_through IS NULL AND path > ? ORDER BY path LIMIT 1"
            ) { statement -> String? in
                try connection.bind(objectID, at: 1, in: statement)
                try connection.bind(afterPath, at: 2, in: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
                return columnString(statement, column: 0)
            }
            guard let path else { return }
            afterPath = path
            try body(path)
        }
    }

    private static func openPathCount(objectID: String, connection: SQLiteConnection) throws -> Int {
        try connection.withStatement(
            "SELECT COUNT(*) FROM path_bindings WHERE object_id = ? AND valid_through IS NULL"
        ) { statement in
            try connection.bind(objectID, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private static func hasOpenPathBinding(objectID: String, path: String, connection: SQLiteConnection) throws -> Bool {
        try connection.withStatement(
            "SELECT EXISTS(SELECT 1 FROM path_bindings WHERE object_id = ? AND path = ? AND valid_through IS NULL)"
        ) { statement in
            try connection.bind(objectID, at: 1, in: statement)
            try connection.bind(path, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return sqlite3_column_int64(statement, 0) != 0
        }
    }

    private static func stagedPathExists(
        input: ReconciliationInput,
        generationID: String,
        path: String,
        objectID: String,
        connection: SQLiteConnection
    ) throws -> Bool {
        try connection.withStatement(
            "SELECT EXISTS(SELECT 1 FROM \(input.table) WHERE generation_id = ? AND path = ? AND object_id = ?)"
        ) { statement in
            try connection.bind(generationID, at: 1, in: statement)
            try connection.bind(path, at: 2, in: statement)
            try connection.bind(objectID, at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return sqlite3_column_int64(statement, 0) != 0
        }
    }

    private static func copyScanGeneration(
        _ generation: MetadataScanGeneration,
        status: MetadataScanGenerationStatus? = nil,
        stagedFileCount: Int? = nil,
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        limitations: [String]? = nil,
        roots: [MetadataScanRootProgress]? = nil,
        reconciliationToken: String? = nil
    ) -> MetadataScanGeneration {
        MetadataScanGeneration(
            generationID: generation.generationID,
            scopeVersionID: generation.scopeVersionID,
            rootPaths: generation.rootPaths,
            excludedPaths: generation.excludedPaths,
            status: status ?? generation.status,
            roots: roots ?? generation.roots,
            processedEntryCount: generation.processedEntryCount,
            stagedFileCount: stagedFileCount ?? generation.stagedFileCount,
            startedAt: generation.startedAt,
            updatedAt: updatedAt ?? generation.updatedAt,
            completedAt: status == .active ? nil : (completedAt ?? generation.completedAt),
            limitations: limitations ?? generation.limitations,
            schedulerCursor: generation.schedulerCursor,
            passProvenanceVersion: generation.passProvenanceVersion,
            reconciliationToken: reconciliationToken ?? generation.reconciliationToken
        )
    }

    private static func encodeCursor<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func currentQueryRevision(connection: SQLiteConnection) throws -> String {
        try connection.scalarText(
            "SELECT printf('%lld:%.6f:%lld', COUNT(*), COALESCE(MAX(observed_at), 0), COALESCE(SUM(allocated_bytes), 0)) FROM current_file_state"
        )
    }

    private static func historyQueryRevision(connection: SQLiteConnection) throws -> String {
        try connection.scalarText(
            """
            SELECT printf(
                '%lld:%.6f:%lld:%.6f:%lld:%.6f',
                (SELECT COUNT(*) FROM events), (SELECT COALESCE(MAX(observed_at), 0) FROM events),
                (SELECT COUNT(*) FROM hourly_summaries), (SELECT COALESCE(MAX(bucket_start), 0) FROM hourly_summaries),
                (SELECT COUNT(*) FROM daily_summaries), (SELECT COALESCE(MAX(bucket_start), 0) FROM daily_summaries)
            )
            """
        )
    }

    private static func fullQueryRevision(connection: SQLiteConnection) throws -> String {
        let current = try currentQueryRevision(connection: connection)
        let history = try historyQueryRevision(connection: connection)
        let bindings = try connection.scalarText(
            "SELECT printf('%lld:%.6f', COUNT(*), COALESCE(MAX(valid_from), 0)) FROM path_bindings"
        )
        return current + "|" + history + "|" + bindings
    }

    private static func decodeCursor<T: Decodable>(_ value: String) throws -> T {
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw EvidenceStoreError.invalidObservation("Evidence query cursor is invalid")
        }
        return decoded
    }

    private static func readEvents(statement: OpaquePointer, connection: SQLiteConnection) throws -> [EvidenceStoreEvent] {
        var values: [EvidenceStoreEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(try readEvent(statement: statement, connection: connection))
        }
        return values
    }

    private static func readEvent(statement: OpaquePointer, connection: SQLiteConnection) throws -> EvidenceStoreEvent {
            guard let eventID = columnString(statement, column: 0),
                  let operationText = columnString(statement, column: 2),
                  let operation = EvidenceStoreEvent.Operation(rawValue: operationText),
                  let path = columnString(statement, column: 3),
                  let category = columnString(statement, column: 6),
                  let confidenceText = columnString(statement, column: 7),
                  let confidence = EvidenceStoreEvent.Confidence(rawValue: confidenceText)
            else { throw connection.lastError(SQLITE_CORRUPT) }
            return EvidenceStoreEvent(
                eventID: eventID,
                observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                operation: operation,
                path: path,
                logicalDelta: sqlite3_column_int64(statement, 4),
                allocatedDelta: sqlite3_column_int64(statement, 5),
                consumerCategory: category,
                confidence: confidence,
                isAnomaly: sqlite3_column_int64(statement, 8) != 0,
                isReviewed: sqlite3_column_int64(statement, 9) != 0
            ).withTiming(try EvidenceEventTiming.read(statement))
    }

    private func readProvenanceClaims(eventIDs: Set<String>, connection: SQLiteConnection) throws -> [ProvenanceClaim] {
        guard !eventIDs.isEmpty else { return [] }
        let ordered = eventIDs.sorted()
        let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ",")
        return try connection.withStatement(
            "SELECT payload, superseded_by_claim_id FROM provenance_claims WHERE event_id IN (\(placeholders)) ORDER BY occurred_start, occurred_end, detected_at, claim_id"
        ) { statement in
            for (offset, eventID) in ordered.enumerated() { try connection.bind(eventID, at: Int32(offset + 1), in: statement) }
            var values: [ProvenanceClaim] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let stored = try JSONDecoder().decode(ProvenanceClaim.self, from: Self.columnData(statement, column: 0, connection: connection))
                values.append(Self.copy(stored, supersededByClaimID: Self.columnString(statement, column: 1)))
            }
            return values
        }
    }

    private func readAgentSessions(registrationIDs: Set<String>, connection: SQLiteConnection) throws -> [AgentSessionRegistration] {
        guard !registrationIDs.isEmpty else { return [] }
        let ordered = registrationIDs.sorted()
        let placeholders = Array(repeating: "?", count: ordered.count).joined(separator: ",")
        return try connection.withStatement(
            "SELECT payload FROM agent_sessions WHERE registration_id IN (\(placeholders)) ORDER BY registered_at, registration_id"
        ) { statement in
            for (offset, registrationID) in ordered.enumerated() { try connection.bind(registrationID, at: Int32(offset + 1), in: statement) }
            var values: [AgentSessionRegistration] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(try JSONDecoder().decode(AgentSessionRegistration.self, from: Self.columnData(statement, column: 0, connection: connection)))
            }
            return values
        }
    }

    private static func columnString(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: value)
    }

    private static func columnDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func columnInt64(_ statement: OpaquePointer, column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    private static func columnData(
        _ statement: OpaquePointer,
        column: Int32,
        connection: SQLiteConnection
    ) throws -> Data {
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount >= 0 else { throw connection.lastError(SQLITE_CORRUPT) }
        if byteCount == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else {
            throw connection.lastError(SQLITE_CORRUPT)
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private static func decodeStringArray(
        _ statement: OpaquePointer,
        column: Int32,
        connection: SQLiteConnection
    ) throws -> [String] {
        try JSONDecoder().decode([String].self, from: columnData(statement, column: column, connection: connection))
    }

    private static func copy(_ claim: ProvenanceClaim, supersededByClaimID: String?) -> ProvenanceClaim {
        claim.withSupersededBy(supersededByClaimID)
    }
}
