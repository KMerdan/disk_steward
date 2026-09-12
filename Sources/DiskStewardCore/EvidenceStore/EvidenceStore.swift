import CSQLite
import Foundation

public actor EvidenceStore {
    public typealias DateSource = @Sendable () -> Date

    private var connection: SQLiteConnection?
    private let databaseURL: URL
    private let dateSource: DateSource

    public init(url: URL, dateSource: @escaping DateSource = Date.init) throws {
        databaseURL = url
        self.dateSource = dateSource
        let connection = try SQLiteConnection(url: url)
        do {
            try Self.configure(connection)
            try Self.migrate(connection)
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

    public func recordSnapshot(_ snapshot: StorageSnapshot, observedAt: Date) throws {
        let connection = try requireConnection()
        let payload = try JSONEncoder().encode(snapshot)
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

    public func applyRetention(_ policy: EvidenceStoreRetentionPolicy) throws -> RetentionReport {
        let connection = try requireConnection()
        let now = dateSource().timeIntervalSince1970
        let rawCutoff = now - Double(policy.rawEventDays * 86_400)
        let hourlyCutoff = now - Double(policy.hourlySummaryDays * 86_400)
        let dailyCutoff = now - Double(policy.dailySummaryDays * 86_400)
        var rawAggregated = 0
        var hourlyAggregated = 0
        var dailyDeleted = 0

        try connection.transaction {
            let rawPredicate = policy.preserveUnreviewedAnomalies
                ? "observed_at < \(rawCutoff) AND (is_anomaly = 0 OR is_reviewed = 1)"
                : "observed_at < \(rawCutoff)"
            rawAggregated = Int(try connection.scalarInt("SELECT COUNT(*) FROM events WHERE \(rawPredicate)"))
            try connection.execute(
                """
                INSERT INTO hourly_summaries (bucket_start, path, operation, event_count, logical_delta, allocated_delta)
                SELECT CAST(observed_at / 3600 AS INTEGER) * 3600, path, operation, COUNT(*), SUM(logical_delta), SUM(allocated_delta)
                FROM events WHERE \(rawPredicate)
                GROUP BY CAST(observed_at / 3600 AS INTEGER), path, operation
                ON CONFLICT(bucket_start, path, operation) DO UPDATE SET
                    event_count = event_count + excluded.event_count,
                    logical_delta = logical_delta + excluded.logical_delta,
                    allocated_delta = allocated_delta + excluded.allocated_delta
                """
            )
            try connection.execute("DELETE FROM events WHERE \(rawPredicate)")

            hourlyAggregated = Int(try connection.scalarInt("SELECT COUNT(*) FROM hourly_summaries WHERE bucket_start < \(hourlyCutoff)"))
            try connection.execute(
                """
                INSERT INTO daily_summaries (bucket_start, path, operation, event_count, logical_delta, allocated_delta)
                SELECT CAST(bucket_start / 86400 AS INTEGER) * 86400, path, operation, SUM(event_count), SUM(logical_delta), SUM(allocated_delta)
                FROM hourly_summaries WHERE bucket_start < \(hourlyCutoff)
                GROUP BY CAST(bucket_start / 86400 AS INTEGER), path, operation
                ON CONFLICT(bucket_start, path, operation) DO UPDATE SET
                    event_count = event_count + excluded.event_count,
                    logical_delta = logical_delta + excluded.logical_delta,
                    allocated_delta = allocated_delta + excluded.allocated_delta
                """
            )
            try connection.execute("DELETE FROM hourly_summaries WHERE bucket_start < \(hourlyCutoff)")
            dailyDeleted = Int(try connection.scalarInt("SELECT COUNT(*) FROM daily_summaries WHERE bucket_start < \(dailyCutoff)"))
            try connection.execute("DELETE FROM daily_summaries WHERE bucket_start < \(dailyCutoff)")
        }

        try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try connection.execute("VACUUM")
        var forcedEvictions = 0
        var bytes = storageBytes()
        while bytes > policy.maxDatabaseBytes {
            let removed = try evictOldestBatch(limit: 1_000)
            forcedEvictions += removed
            guard removed > 0 else { break }
            try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try connection.execute("VACUUM")
            bytes = storageBytes()
        }

        return RetentionReport(
            aggregatedRawEvents: rawAggregated,
            aggregatedHourlySummaries: hourlyAggregated,
            deletedDailySummaries: dailyDeleted,
            forcedEvictions: forcedEvictions,
            storageBytes: bytes
        )
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
        return EvidenceStoreDiagnostics(
            schemaVersion: Int(try connection.scalarInt("PRAGMA user_version")),
            journalMode: try connection.scalarText("PRAGMA journal_mode"),
            integrity: try integrityCheck(),
            eventCount: try eventCount(),
            snapshotCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM snapshots")),
            hourlySummaryCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM hourly_summaries")),
            dailySummaryCount: Int(try connection.scalarInt("SELECT COUNT(*) FROM daily_summaries")),
            storageBytes: storageBytes()
        )
    }

    private func evictOldestBatch(limit: Int) throws -> Int {
        let connection = try requireConnection()
        for table in ["events", "hourly_summaries", "daily_summaries", "snapshots"] {
            let orderColumn = table == "snapshots" ? "observed_at" : (table == "events" ? "observed_at" : "bucket_start")
            let before = Int(try connection.scalarInt("SELECT COUNT(*) FROM \(table)"))
            guard before > 0 else { continue }
            try connection.execute(
                "DELETE FROM \(table) WHERE rowid IN (SELECT rowid FROM \(table) ORDER BY \(orderColumn) LIMIT \(limit))"
            )
            let after = Int(try connection.scalarInt("SELECT COUNT(*) FROM \(table)"))
            return before - after
        }
        return 0
    }

    private func storageBytes() -> Int64 {
        let manager = FileManager.default
        return [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"].reduce(0) { total, path in
            let attributes = try? manager.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func requireConnection() throws -> SQLiteConnection {
        guard let connection else { throw EvidenceStoreError.closed }
        return connection
    }

    private static func validate(_ event: EvidenceStoreEvent) throws {
        guard !event.eventID.isEmpty else { throw EvidenceStoreError.invalidEvent("event_id is empty") }
        guard !event.path.isEmpty else { throw EvidenceStoreError.invalidEvent("path is empty") }
        guard !event.consumerCategory.isEmpty else {
            throw EvidenceStoreError.invalidEvent("consumer_category is empty")
        }
    }

    private static func configure(_ connection: SQLiteConnection) throws {
        try connection.execute("PRAGMA busy_timeout=5000")
        try connection.execute("PRAGMA journal_mode=WAL")
        try connection.execute("PRAGMA synchronous=NORMAL")
        try connection.execute("PRAGMA foreign_keys=ON")
    }

    private static func migrate(_ connection: SQLiteConnection) throws {
        let version = try connection.scalarInt("PRAGMA user_version")
        guard version <= 1 else {
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
        guard try connection.scalarText("PRAGMA quick_check") == "ok" else {
            throw EvidenceStoreError.sqlite(code: SQLITE_CORRUPT, message: "Database integrity check failed")
        }
    }
}
