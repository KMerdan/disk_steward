import CSQLite
import Foundation

/// One capacity measurement of one volume.
public struct CapacitySample: Equatable, Sendable {
    public let volumeUUID: String
    public let mountPath: String
    public let observedAt: Date
    public let totalBytes: Int64
    public let availableBytes: Int64
}

/// What the ring holds for a volume, in one bounded read.
public struct CapacityHistorySummary: Equatable, Sendable {
    public let sampleCount: Int
    public let oldest: Date?
    public let newest: CapacitySample?
    /// Smallest available capacity within the last 24 hours of samples.
    public let minimumAvailableLastDay: Int64?
}

/// Capacity history in its own small file (TASK-651, CONTRACT-602): 5-minute
/// samples for a week and one sample per hour for a year, per volume. It
/// never touches the evidence store, so capacity history survives anything
/// that happens to file detail.
public actor CapacityRing {
    public static let fineInterval: TimeInterval = 5 * 60
    public static let hourlyInterval: TimeInterval = 60 * 60
    /// Per volume: 2,016 fine samples (7 days) and 8,760 hourly ones (a year).
    public static let fineRetention: TimeInterval = 7 * 24 * 60 * 60
    public static let hourlyRetention: TimeInterval = 365 * 24 * 60 * 60

    private let connection: SQLiteConnection
    private static var tables: [String: BoundedTable] {
        Dictionary(uniqueKeysWithValues: (BoundedStoreContract.tables[.capacityRing] ?? []).map { ($0.name, $0) })
    }

    public init(url: URL) throws {
        connection = try SQLiteConnection(url: url)
        try connection.prepareBoundedStore(.capacityRing)
    }

    public static func defaultURL(beside databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appending(path: "capacity.sqlite")
    }

    public func close() { connection.close() }

    /// Records a sample. A fine row is kept when at least most of a fine
    /// interval has passed since the last one, so on-demand and wake samples
    /// cannot flood the week; one hourly row is kept per clock hour.
    @discardableResult
    public func record(volumeUUID: String, mountPath: String, totalBytes: Int64, availableBytes: Int64, at date: Date) throws -> Bool {
        guard let fine = Self.tables["capacity_fine"], let hourly = Self.tables["capacity_hourly"] else { return false }
        let volumeID = try volumeID(uuid: volumeUUID, mountPath: mountPath, at: date)
        let row: [String: BoundedValue] = [
            "volume_id": .integer(volumeID), "observed_at": .real(date.timeIntervalSince1970),
            "total_bytes": .integer(totalBytes), "available_bytes": .integer(availableBytes),
            "important_available_bytes": .integer(availableBytes),
        ]
        var recorded = false
        let lastFine = try latestTime(table: "capacity_fine", volumeID: volumeID)
        if lastFine.map({ date.timeIntervalSince($0) >= Self.fineInterval * 0.8 || date < $0 }) ?? true {
            _ = try connection.insertBounded(fine, rows: [row])
            recorded = true
        }
        let hour = (date.timeIntervalSince1970 / Self.hourlyInterval).rounded(.down) * Self.hourlyInterval
        let lastHourly = try latestTime(table: "capacity_hourly", volumeID: volumeID)
        if lastHourly.map({ $0.timeIntervalSince1970 < hour }) ?? true {
            var hourlyRow = row
            hourlyRow["observed_at"] = .real(hour)
            _ = try connection.insertBounded(hourly, rows: [hourlyRow])
            recorded = true
        }
        if recorded {
            // Time windows per volume; the contract's row and byte caps stay
            // the hard backstop across volumes.
            try connection.withStatement("DELETE FROM capacity_fine WHERE volume_id = ? AND observed_at < ?") { statement in
                try connection.bind(volumeID, at: 1, in: statement)
                try connection.bind(date.addingTimeInterval(-Self.fineRetention).timeIntervalSince1970, at: 2, in: statement)
                try connection.stepDone(statement)
            }
            try connection.withStatement("DELETE FROM capacity_hourly WHERE volume_id = ? AND observed_at < ?") { statement in
                try connection.bind(volumeID, at: 1, in: statement)
                try connection.bind(date.addingTimeInterval(-Self.hourlyRetention).timeIntervalSince1970, at: 2, in: statement)
                try connection.stepDone(statement)
            }
        }
        return recorded
    }

    /// Newest fine samples for a volume, newest first, in a bounded window.
    public func recent(volumeUUID: String, limit: Int) throws -> BoundedWindow<CapacitySample> {
        guard let fine = Self.tables["capacity_fine"], let volume = try volume(uuid: volumeUUID) else {
            return BoundedWindow(items: [], total: 0)
        }
        let total = Int(try connection.scalarInt("SELECT COUNT(*) FROM capacity_fine WHERE volume_id = \(volume.id)"))
        let affordable = max(1, (BoundedStoreContract.responseCeilingBytes - 8 * 1_024) / max(1, fine.maximumRowBytes))
        let items = try connection.withStatement(
            "SELECT observed_at, total_bytes, available_bytes FROM capacity_fine WHERE volume_id = ? ORDER BY observed_at DESC, rowid DESC LIMIT ?"
        ) { statement -> [CapacitySample] in
            try connection.bind(volume.id, at: 1, in: statement)
            try connection.bind(Int64(min(max(limit, 1), affordable)), at: 2, in: statement)
            var values: [CapacitySample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(.init(volumeUUID: volumeUUID, mountPath: volume.mountPath,
                                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                                    totalBytes: sqlite3_column_int64(statement, 1), availableBytes: sqlite3_column_int64(statement, 2)))
            }
            return values
        }
        return BoundedWindow(items: items, total: total)
    }

    public func summary(volumeUUID: String, now: Date = Date()) throws -> CapacityHistorySummary {
        guard let volume = try volume(uuid: volumeUUID) else {
            return .init(sampleCount: 0, oldest: nil, newest: nil, minimumAvailableLastDay: nil)
        }
        let counts = try connection.withStatement(
            "SELECT (SELECT COUNT(*) FROM capacity_fine WHERE volume_id = ?1) + (SELECT COUNT(*) FROM capacity_hourly WHERE volume_id = ?1), MIN(t) FROM (SELECT MIN(observed_at) AS t FROM capacity_fine WHERE volume_id = ?1 UNION ALL SELECT MIN(observed_at) FROM capacity_hourly WHERE volume_id = ?1)"
        ) { statement -> (Int, Date?) in
            try connection.bind(volume.id, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError() }
            let oldest = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            return (Int(sqlite3_column_int64(statement, 0)), oldest)
        }
        let minimum = try connection.withStatement(
            "SELECT MIN(available_bytes) FROM capacity_fine WHERE volume_id = ? AND observed_at >= ?"
        ) { statement -> Int64? in
            try connection.bind(volume.id, at: 1, in: statement)
            try connection.bind(now.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, 0)
        }
        return .init(sampleCount: counts.0, oldest: counts.1, newest: try recent(volumeUUID: volumeUUID, limit: 1).items.first,
                     minimumAvailableLastDay: minimum)
    }

    /// The most recently seen volume mounted at this path.
    public func volumeUUID(mountPath: String) throws -> String? {
        try connection.withStatement("SELECT volume_uuid FROM capacity_volumes WHERE mount_path = ? ORDER BY first_seen_at DESC LIMIT 1") { statement in
            try connection.bind(mountPath, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return String(cString: sqlite3_column_text(statement, 0))
        }
    }

    private struct Volume { let id: Int64; let mountPath: String }

    private func volume(uuid: String) throws -> Volume? {
        try connection.withStatement("SELECT volume_id, mount_path FROM capacity_volumes WHERE volume_uuid = ? ORDER BY first_seen_at DESC LIMIT 1") { statement in
            try connection.bind(uuid, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Volume(id: sqlite3_column_int64(statement, 0), mountPath: String(cString: sqlite3_column_text(statement, 1)))
        }
    }

    private func volumeID(uuid: String, mountPath: String, at date: Date) throws -> Int64 {
        if let existing = try volume(uuid: uuid) { return existing.id }
        guard let volumes = Self.tables["capacity_volumes"] else { throw BoundedStoreError.unknownColumn(table: "capacity_volumes", column: "*") }
        let next = try connection.scalarInt("SELECT COALESCE(MAX(volume_id), 0) + 1 FROM capacity_volumes")
        let report = try connection.insertBounded(volumes, rows: [[
            "volume_id": .integer(next), "volume_uuid": .text(String(uuid.prefix(64))),
            "mount_path": .text(String(mountPath.utf8.prefix(BoundedStoreContract.pathBytes)) ?? "/"),
            "first_seen_at": .real(date.timeIntervalSince1970),
        ]])
        guard report.inserted == 1 else { throw BoundedStoreError.unknownColumn(table: "capacity_volumes", column: "mount_path") }
        return next
    }

    private func latestTime(table: String, volumeID: Int64) throws -> Date? {
        try connection.withStatement("SELECT MAX(observed_at) FROM \(table) WHERE volume_id = ?") { statement in
            try connection.bind(volumeID, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }
}
