import CSQLite
import Foundation

public struct EvidenceBundleExporter: Sendable {
    public typealias IdentifierSource = @Sendable () -> String
    public typealias DateSource = @Sendable () -> Date

    private let productVersion: String
    private let identifierSource: IdentifierSource
    private let dateSource: DateSource

    public init(
        productVersion: String = "0.1.0",
        identifierSource: @escaping IdentifierSource = { UUID().uuidString.lowercased() },
        dateSource: @escaping DateSource = Date.init
    ) {
        self.productVersion = productVersion
        self.identifierSource = identifierSource
        self.dateSource = dateSource
    }

    public func export(
        store: EvidenceStore,
        options: EvidenceBundleExportOptions,
        to parentDirectory: URL
    ) async throws -> EvidenceBundleExportResult {
        guard options.from <= options.through else { throw EvidenceBundleExportError.invalidRange }
        let bundleID = identifierSource()
        guard isSafePathComponent(bundleID) else { throw EvidenceBundleExportError.unsafeBundleIdentifier }
        let bundleURL = parentDirectory.appending(path: "disk-steward-evidence-\(bundleID)", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw EvidenceBundleExportError.destinationAlreadyExists
        }

        let temporaryBackup = FileManager.default.temporaryDirectory
            .appending(path: "disk-steward-export-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporaryBackup) }
        try await store.backup(to: temporaryBackup)
        let view = try ConsistentEvidenceView(databaseURL: temporaryBackup).read(options: options)

        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)
        do {
            let encoder = Self.encoder()
            let range = EvidenceBundleManifest.RequestedRange(
                from: Self.timestamp(options.from),
                through: Self.timestamp(options.through)
            )
            var limitations = view.limitations + view.snapshots.flatMap(\.limitations)
            if view.events.isEmpty { limitations.append("No raw events were retained inside the requested period.") }
            if view.snapshots.isEmpty { limitations.append("No storage snapshots were retained inside the requested period.") }
            limitations.append("Creator process and agent session fields are null unless a recorded attribution source established them.")
            limitations = Array(Set(limitations)).sorted()

            let exportedEvents = view.events.map { exportEvent($0, pathDetail: options.pathDetail) }
            let lineEncoder = Self.lineEncoder()
            let eventLines = try exportedEvents.map { String(decoding: try lineEncoder.encode($0), as: UTF8.self) }
                .joined(separator: "\n") + (exportedEvents.isEmpty ? "" : "\n")
            let compressedEvents = try ZlibCodec.compress(Data(eventLines.utf8))
            let categories = Dictionary(grouping: view.events, by: \.consumerCategory).map { name, events in
                EvidenceBundleSummary.Category(
                    name: name,
                    eventCount: events.count,
                    allocatedDelta: events.reduce(0) { $0 + $1.allocatedDelta }
                )
            }.sorted { $0.name < $1.name }
            let rollupDelta = (view.hourly + view.daily).reduce(0) { $0 + $1.allocatedDelta }
            let summary = EvidenceBundleSummary(
                schema: "evidence-summary-v1",
                requestedRange: range,
                rawEventCount: view.events.count,
                snapshotCount: view.snapshots.count,
                hourlySummaryCount: view.hourly.count,
                dailySummaryCount: view.daily.count,
                allocatedDelta: view.events.reduce(0) { $0 + $1.allocatedDelta } + rollupDelta,
                categories: categories,
                limitations: limitations
            )
            let rollups = EvidenceBundleRollups(
                schema: "evidence-rollups-v1",
                hourly: view.hourly.map { rollupRow($0, pathDetail: options.pathDetail) },
                daily: view.daily.map { rollupRow($0, pathDetail: options.pathDetail) }
            )
            let payloads: [(path: String, role: String, data: Data)] = [
                ("codex-brief.md", "codex-brief", Data((brief(summary: summary, events: exportedEvents) + "\n").utf8)),
                ("summary.json", "summary", try encoder.encode(summary)),
                ("rollups.json", "summary", try encoder.encode(rollups)),
                ("events.jsonl.zlib", "events", compressedEvents),
                ("snapshots.json", "snapshot", try encoder.encode(EvidenceBundleSnapshots(schema: "storage-snapshots-v1", snapshots: view.snapshots))),
            ]
            for payload in payloads {
                try payload.data.write(to: bundleURL.appending(path: payload.path), options: .atomic)
            }
            let integrity = EvidenceBundleIntegrity(
                schema: "integrity-v1",
                algorithm: "sha256",
                files: payloads.map { .init(path: $0.path, sha256: SHA256Digest.hex(for: $0.data), bytes: $0.data.count) }
            )
            let integrityData = try encoder.encode(integrity)
            try integrityData.write(to: bundleURL.appending(path: "integrity.json"), options: .atomic)
            let allPayloads = payloads + [("integrity.json", "integrity", integrityData)]
            let manifest = EvidenceBundleManifest(
                schema: "export-manifest-v1",
                bundleID: bundleID,
                createdAt: Self.timestamp(dateSource()),
                producer: .init(name: ProductIdentity.diskSteward.evidenceProducer, version: productVersion, evidenceSchemaVersion: 1),
                requestedRange: range,
                files: allPayloads.map { .init(path: $0.path, role: $0.role, sha256: SHA256Digest.hex(for: $0.data), bytes: $0.data.count) },
                limitations: limitations,
                privacy: .init(containsFileContents: false, containsEnvironment: false, pathDetail: options.pathDetail)
            )
            try encoder.encode(manifest).write(to: bundleURL.appending(path: "manifest.json"), options: .atomic)
            return EvidenceBundleExportResult(bundleURL: bundleURL, manifest: manifest)
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
    }

    private func exportEvent(_ event: EvidenceStoreEvent, pathDetail: EvidencePathDetail) -> ExportedEvidenceEvent {
        let method: String
        switch event.confidence {
        case .exact: method = "endpoint-security"
        case .toolLinked: method = "tool-registration"
        case .inferred: method = "snapshot-delta"
        case .unknown: method = "unknown"
        }
        let classification: (String, String)
        switch event.consumerCategory {
        case "developer-cache": classification = ("reproducible", "yellow")
        case "agent-artifact": classification = ("conditional", "yellow")
        case "downloads": classification = ("user-data", "red")
        default: classification = ("unknown", "unknown")
        }
        return ExportedEvidenceEvent(
            schema: "evidence-event-v1",
            eventID: event.eventID,
            observedAt: Self.timestamp(event.observedAt),
            operation: event.operation.rawValue,
            path: sanitized(path: event.path, detail: pathDetail),
            size: .init(
                logicalBefore: nil,
                logicalAfter: nil,
                logicalDelta: event.logicalDelta,
                allocatedBefore: nil,
                allocatedAfter: nil,
                allocatedDelta: event.allocatedDelta
            ),
            actor: .init(processID: nil, executable: nil, command: nil, workingDirectory: nil, ancestorExecutables: []),
            session: .init(provider: "none", sessionID: nil, title: nil, workingDirectory: nil),
            attribution: .init(
                confidence: event.confidence.rawValue,
                method: method,
                limitations: event.confidence == .exact ? [] : ["No exact creator-process identity was recorded for this event."]
            ),
            classification: .init(
                consumerCategory: event.consumerCategory,
                reclaimability: classification.0,
                cleanupSafety: classification.1
            ),
            evidence: [.init(kind: "stored-metadata-event", reference: event.eventID)]
        )
    }

    private func rollupRow(_ summary: EvidenceSummary, pathDetail: EvidencePathDetail) -> EvidenceBundleRollups.Row {
        .init(
            bucketStart: Self.timestamp(summary.bucketStart),
            path: sanitized(path: summary.path, detail: pathDetail),
            operation: summary.operation.rawValue,
            eventCount: summary.eventCount,
            logicalDelta: summary.logicalDelta,
            allocatedDelta: summary.allocatedDelta
        )
    }

    private func sanitized(path: String, detail: EvidencePathDetail) -> String {
        let shaped: String
        switch detail {
        case .full: shaped = path
        case .basename: shaped = URL(fileURLWithPath: path).lastPathComponent
        case .hashed: return "sha256:" + SHA256Digest.hex(for: Data(path.utf8))
        }
        let pattern = #"(?i)(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|AKIA[A-Z0-9]{16}|(?:token|password|secret|api[_-]?key)=[^/\\s]+)"#
        return shaped.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
    }

    private func brief(summary: EvidenceBundleSummary, events: [ExportedEvidenceEvent]) -> String {
        let categoryRows = summary.categories.isEmpty
            ? "| None retained | 0 | 0 |"
            : summary.categories.map { "| \($0.name) | \($0.eventCount) | \($0.allocatedDelta) |" }.joined(separator: "\n")
        let notable = events
            .sorted { abs($0.size.allocatedDelta) > abs($1.size.allocatedDelta) }
            .prefix(10)
            .map { "- `\($0.path)` — \($0.operation), \($0.size.allocatedDelta) allocated bytes, \($0.attribution.confidence) via \($0.attribution.method)." }
            .joined(separator: "\n")
        let limitations = summary.limitations.map { "- \($0)" }.joined(separator: "\n")
        return """
        # Disk Steward Evidence Brief

        Requested period: \(summary.requestedRange.from) through \(summary.requestedRange.through)

        This bundle is a consistent, time-bounded view of previously recorded metadata. It does not rescan the disk.

        ## Summary

        - Raw events: \(summary.rawEventCount)
        - Hourly rollup rows: \(summary.hourlySummaryCount)
        - Daily rollup rows: \(summary.dailySummaryCount)
        - Storage snapshots: \(summary.snapshotCount)
        - Net allocated-byte delta across retained detail and rollups: \(summary.allocatedDelta)

        | Consumer category | Events | Allocated-byte delta |
        |---|---:|---:|
        \(categoryRows)

        ## Largest retained events

        \(notable.isEmpty ? "- No retained raw events in this period." : notable)

        ## Limitations

        \(limitations)

        ## How to inspect

        Verify `manifest.json` hashes, read `summary.json` and `rollups.json`, and decompress `events.jsonl.zlib` as zlib-compressed JSON Lines. Every attribution includes confidence and method. No file contents or environment variables are included.
        """
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func lineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct ConsistentEvidenceView {
    let databaseURL: URL

    func read(options: EvidenceBundleExportOptions) throws -> (events: [EvidenceStoreEvent], snapshots: [StorageSnapshot], hourly: [EvidenceSummary], daily: [EvidenceSummary], limitations: [String]) {
        let connection = try SQLiteConnection(url: databaseURL)
        defer { connection.close() }
        let events = try readEvents(connection, options: options)
        let snapshots = try readSnapshots(connection, options: options)
        let hourly = try readSummaries(connection, table: "hourly_summaries", bucketSeconds: 3_600, options: options)
        let daily = try readSummaries(connection, table: "daily_summaries", bucketSeconds: 86_400, options: options)
        var limitations: [String] = []
        if events.truncated {
            limitations.append("Raw event detail was truncated at the requested \(options.maximumEvents)-event export limit.")
        }
        if !hourly.isEmpty || !daily.isEmpty {
            limitations.append("Rollup rows represent complete hour or day buckets and may overlap an exact requested-range boundary.")
        }
        return (events.values, snapshots, hourly, daily, limitations)
    }

    private func readEvents(
        _ connection: SQLiteConnection,
        options: EvidenceBundleExportOptions
    ) throws -> (values: [EvidenceStoreEvent], truncated: Bool) {
        try connection.withStatement(
            """
            SELECT event_id, observed_at, operation, path, logical_delta, allocated_delta,
                   consumer_category, confidence, is_anomaly, is_reviewed
            FROM events WHERE observed_at >= ? AND observed_at <= ?
            ORDER BY observed_at, event_id LIMIT ?
            """
        ) { statement in
            try connection.bind(options.from.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(options.through.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(options.maximumEvents + 1), at: 3, in: statement)
            var values: [EvidenceStoreEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let eventID = sqlite3_column_text(statement, 0),
                      let operation = sqlite3_column_text(statement, 2),
                      let path = sqlite3_column_text(statement, 3),
                      let category = sqlite3_column_text(statement, 6),
                      let confidence = sqlite3_column_text(statement, 7),
                      let operationValue = EvidenceStoreEvent.Operation(rawValue: String(cString: operation)),
                      let confidenceValue = EvidenceStoreEvent.Confidence(rawValue: String(cString: confidence))
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    eventID: String(cString: eventID),
                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    operation: operationValue,
                    path: String(cString: path),
                    logicalDelta: sqlite3_column_int64(statement, 4),
                    allocatedDelta: sqlite3_column_int64(statement, 5),
                    consumerCategory: String(cString: category),
                    confidence: confidenceValue,
                    isAnomaly: sqlite3_column_int64(statement, 8) != 0,
                    isReviewed: sqlite3_column_int64(statement, 9) != 0
                ))
            }
            let truncated = values.count > options.maximumEvents
            return (Array(values.prefix(options.maximumEvents)), truncated)
        }
    }

    private func readSnapshots(_ connection: SQLiteConnection, options: EvidenceBundleExportOptions) throws -> [StorageSnapshot] {
        try connection.withStatement(
            "SELECT payload FROM snapshots WHERE observed_at >= ? AND observed_at <= ? ORDER BY observed_at, snapshot_id"
        ) { statement in
            try connection.bind(options.from.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(options.through.timeIntervalSince1970, at: 2, in: statement)
            var snapshots: [StorageSnapshot] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let byteCount = Int(sqlite3_column_bytes(statement, 0))
                guard byteCount >= 0, let bytes = sqlite3_column_blob(statement, 0) else {
                    throw connection.lastError(SQLITE_CORRUPT)
                }
                snapshots.append(try JSONDecoder().decode(StorageSnapshot.self, from: Data(bytes: bytes, count: byteCount)))
            }
            return snapshots
        }
    }

    private func readSummaries(
        _ connection: SQLiteConnection,
        table: String,
        bucketSeconds: TimeInterval,
        options: EvidenceBundleExportOptions
    ) throws -> [EvidenceSummary] {
        let firstBucket = floor(options.from.timeIntervalSince1970 / bucketSeconds) * bucketSeconds
        return try connection.withStatement(
            "SELECT bucket_start, path, operation, event_count, logical_delta, allocated_delta FROM \(table) WHERE bucket_start >= ? AND bucket_start <= ? ORDER BY bucket_start, path, operation"
        ) { statement in
            try connection.bind(firstBucket, at: 1, in: statement)
            try connection.bind(options.through.timeIntervalSince1970, at: 2, in: statement)
            var rows: [EvidenceSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = sqlite3_column_text(statement, 1),
                      let operation = sqlite3_column_text(statement, 2),
                      let operationValue = EvidenceStoreEvent.Operation(rawValue: String(cString: operation))
                else { throw connection.lastError(SQLITE_CORRUPT) }
                rows.append(.init(
                    bucketStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    path: String(cString: path),
                    operation: operationValue,
                    eventCount: Int(sqlite3_column_int64(statement, 3)),
                    logicalDelta: sqlite3_column_int64(statement, 4),
                    allocatedDelta: sqlite3_column_int64(statement, 5)
                ))
            }
            return rows
        }
    }
}
