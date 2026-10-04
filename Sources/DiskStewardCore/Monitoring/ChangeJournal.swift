import CryptoKit
import CSQLite
import Foundation

/// A directory that changed within one capacity interval.
public struct JournalChange: Equatable, Sendable {
    public let path: String
    public let changes: Int64
    public let firstInterval: Date
    public let lastInterval: Date

    public init(path: String, changes: Int64, firstInterval: Date, lastInterval: Date) {
        self.path = path
        self.changes = changes
        self.firstInterval = firstInterval
        self.lastInterval = lastInterval
    }
}

/// A stretch the journal cannot vouch for: dropped or wrapped events, a
/// journal reset, or the time before the journal started.
public struct JournalGap: Equatable, Sendable {
    public let reason: String
    public let path: String
    public let at: Date
}

public struct JournalWindow: Sendable {
    public let changes: BoundedWindow<JournalChange>
    public let gaps: [JournalGap]
}

/// TASK-652: which directories changed, from the FSEvents journal, without
/// walking the disk. Changes collapse to an attribution directory and are
/// kept per capacity interval in the steward file under CONTRACT-602.
public actor ChangeJournal {
    public static let intervalSeconds: TimeInterval = 5 * 60
    public static let directoriesPerInterval = 2_000
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// Directory names that are whole objects: a change inside one is
    /// attributed to the object, not to its internals.
    public static let objectNames: Set<String> = [
        "node_modules", "target", ".build", "build", "dist", ".next", ".nuxt", ".turbo", ".parcel-cache", "out",
        ".venv", "venv", "__pycache__", ".tox", ".pytest_cache", ".mypy_cache", ".gradle", "vendor", "Pods",
        ".swiftpm", ".git", "DerivedData",
    ]
    /// Without an object on the way, changes collapse this many levels below a root.
    public static let depthBelowRoot = 2

    private let connection: SQLiteConnection
    private static var tables: [String: BoundedTable] {
        Dictionary(uniqueKeysWithValues: (BoundedStoreContract.tables[.steward] ?? []).map { ($0.name, $0) })
    }

    public init(url: URL) throws {
        connection = try SQLiteConnection(url: url)
        try connection.prepareBoundedStore(.steward)
    }

    public static func defaultURL(beside databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appending(path: "steward.sqlite")
    }

    public func close() { connection.close() }

    /// The directory a change is attributed to, or nil outside every root.
    public static func attributionPath(for path: String, roots: [String]) -> String? {
        let standardized = normalized(path)
        guard let root = roots.map(normalized)
            .filter({ standardized == $0 || standardized.hasPrefix($0 == "/" ? "/" : $0 + "/") })
            .max(by: { $0.count < $1.count }) else { return nil }
        let relative = standardized == root ? [] : standardized.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/").map(String.init)
        var kept: [String] = []
        for component in relative {
            kept.append(component)
            if objectNames.contains(component) || kept.count == depthBelowRoot { break }
        }
        return kept.isEmpty ? root : (root == "/" ? "/" : root + "/") + kept.joined(separator: "/")
    }

    /// Lexical normalization only: FSEvents reports real paths and roots are
    /// resolved once by the caller, so no per-event file-system lookups.
    static func normalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") where component != "." {
            if component == ".." { _ = components.popLast() } else { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    public static func intervalStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / intervalSeconds).rounded(.down) * intervalSeconds)
    }

    // MARK: Cursor

    public func cursor(journalUUID: String) throws -> UInt64? {
        try connection.withStatement("SELECT last_event_id FROM journal_cursors WHERE volume_id = ? ORDER BY updated_at DESC LIMIT 1") { statement in
            try connection.bind(Self.volumeKey(journalUUID), at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return UInt64(bitPattern: sqlite3_column_int64(statement, 0))
        }
    }

    /// Whether any journal has ever been checkpointed. A new journal identity
    /// after that is a reset, not a first start.
    public func hasAnyCursor() throws -> Bool {
        try connection.withStatement("SELECT 1 FROM journal_cursors LIMIT 1") { statement in sqlite3_step(statement) == SQLITE_ROW }
    }

    /// Stores the newest delivered event ID; a cursor never moves backwards.
    public func checkpoint(journalUUID: String, eventID: UInt64, at date: Date) throws {
        guard let table = Self.tables["journal_cursors"] else { return }
        if let stored = try cursor(journalUUID: journalUUID), stored >= eventID { return }
        try connection.transaction {
            try connection.withStatement("DELETE FROM journal_cursors WHERE volume_id = ?") { statement in
                try connection.bind(Self.volumeKey(journalUUID), at: 1, in: statement)
                try connection.stepDone(statement)
            }
        }
        _ = try connection.insertBounded(table, rows: [[
            "volume_id": .integer(Self.volumeKey(journalUUID)), "fsevents_uuid": .text(String(journalUUID.prefix(64))),
            "last_event_id": .integer(Int64(bitPattern: eventID)), "updated_at": .real(date.timeIntervalSince1970),
        ]])
    }

    // MARK: Recording

    /// Records a delivered batch: each change collapses to its attribution
    /// directory in the current interval, at most 2,000 per interval, with
    /// overflow collapsing to the parent. Gap signals become gaps.
    public func record(_ batch: DirectoryChangeBatch, roots: [String], at date: Date) throws {
        let interval = Self.intervalStart(date).timeIntervalSince1970
        var counts: [String: Int64] = [:]
        for event in batch.events {
            guard let path = Self.attributionPath(for: event.path, roots: roots) else { continue }
            counts[path, default: 0] += 1
        }
        for (path, changes) in counts.sorted(by: { $0.key < $1.key }) {
            try upsert(path: try fitted(path: path, interval: interval, roots: roots), kind: "changed", changes: changes, interval: interval)
        }
        for gap in batch.gaps {
            let path = Self.attributionPath(for: gap.path, roots: roots) ?? roots.first ?? "/"
            try recordGap(reason: gap.signal, path: path, at: date)
        }
        try prune(before: date.addingTimeInterval(-Self.retention))
    }

    public func recordGap(reason: String, path: String, at date: Date) throws {
        try upsert(path: path, kind: "gap:" + String(reason.prefix(27)), changes: 1, interval: Self.intervalStart(date).timeIntervalSince1970)
    }

    // MARK: Reading

    /// Directories changed in [from, through], aggregated across intervals,
    /// most changes first, in a bounded window; plus the gaps in that range.
    public func changes(from: Date, through: Date, limit: Int) throws -> JournalWindow {
        let lower = Self.intervalStart(from).timeIntervalSince1970
        let upper = through.timeIntervalSince1970
        let total = Int(try connection.withStatement(
            "SELECT COUNT(DISTINCT path_key) FROM journal_dirty WHERE kind = 'changed' AND interval_start >= ? AND interval_start <= ?"
        ) { statement -> Int64 in
            try connection.bind(lower, at: 1, in: statement)
            try connection.bind(upper, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError() }
            return sqlite3_column_int64(statement, 0)
        })
        let affordable = max(1, (BoundedStoreContract.responseCeilingBytes - 8 * 1_024) / (BoundedStoreContract.pathBytes + 64))
        let items = try connection.withStatement("""
            SELECT path, SUM(changes), MIN(interval_start), MAX(interval_start) FROM journal_dirty
            WHERE kind = 'changed' AND interval_start >= ? AND interval_start <= ?
            GROUP BY path_key ORDER BY SUM(changes) DESC, path ASC LIMIT ?
            """) { statement -> [JournalChange] in
            try connection.bind(lower, at: 1, in: statement)
            try connection.bind(upper, at: 2, in: statement)
            try connection.bind(Int64(min(max(limit, 1), affordable)), at: 3, in: statement)
            var values: [JournalChange] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(.init(path: String(cString: sqlite3_column_text(statement, 0)), changes: sqlite3_column_int64(statement, 1),
                                    firstInterval: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                                    lastInterval: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
            }
            return values
        }
        let gaps = try connection.withStatement("""
            SELECT kind, path, interval_start FROM journal_dirty WHERE kind LIKE 'gap:%' AND interval_start >= ? AND interval_start <= ?
            ORDER BY interval_start DESC LIMIT 64
            """) { statement -> [JournalGap] in
            try connection.bind(lower, at: 1, in: statement)
            try connection.bind(upper, at: 2, in: statement)
            var values: [JournalGap] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(.init(reason: String(String(cString: sqlite3_column_text(statement, 0)).dropFirst(4)),
                                    path: String(cString: sqlite3_column_text(statement, 1)),
                                    at: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))))
            }
            return values
        }
        return JournalWindow(changes: BoundedWindow(items: items, total: total), gaps: gaps)
    }

    /// TASK-672: changed directories at, inside, or containing any of `roots`
    /// (a containing row is a change collapsed above the root), most changes
    /// first, with every gap in the window.
    public func changes(from: Date, through: Date, relatedTo roots: [String], limit: Int) throws -> JournalWindow {
        let roots = Array(Set(roots.map(Self.normalized))).sorted()
        guard !roots.isEmpty else { return JournalWindow(changes: BoundedWindow(items: [], total: 0), gaps: try changes(from: from, through: through, limit: 1).gaps) }
        let clause = Array(repeating: "(path = ? OR substr(path, 1, ?) = ? OR substr(?, 1, length(path) + 1) = path || '/')", count: roots.count)
            .joined(separator: " OR ")
        let lower = Self.intervalStart(from).timeIntervalSince1970
        let upper = through.timeIntervalSince1970
        func bindAll(_ statement: OpaquePointer) throws -> Int32 {
            try connection.bind(lower, at: 1, in: statement)
            try connection.bind(upper, at: 2, in: statement)
            var index: Int32 = 3
            for root in roots {
                let prefix = root == "/" ? "/" : root + "/"
                try connection.bind(root, at: index, in: statement)
                try connection.bind(Int64(prefix.utf8.count), at: index + 1, in: statement)
                try connection.bind(prefix, at: index + 2, in: statement)
                try connection.bind(root, at: index + 3, in: statement)
                index += 4
            }
            return index
        }
        let filter = "kind = 'changed' AND interval_start >= ? AND interval_start <= ? AND (\(clause))"
        let total = Int(try connection.withStatement("SELECT COUNT(DISTINCT path_key) FROM journal_dirty WHERE \(filter)") { statement -> Int64 in
            _ = try bindAll(statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError() }
            return sqlite3_column_int64(statement, 0)
        })
        let affordable = max(1, (BoundedStoreContract.responseCeilingBytes - 8 * 1_024) / (BoundedStoreContract.pathBytes + 64))
        let items = try connection.withStatement("""
            SELECT path, SUM(changes), MIN(interval_start), MAX(interval_start) FROM journal_dirty WHERE \(filter)
            GROUP BY path_key ORDER BY SUM(changes) DESC, path ASC LIMIT ?
            """) { statement -> [JournalChange] in
            let next = try bindAll(statement)
            try connection.bind(Int64(min(max(limit, 1), affordable)), at: next, in: statement)
            var values: [JournalChange] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(.init(path: String(cString: sqlite3_column_text(statement, 0)), changes: sqlite3_column_int64(statement, 1),
                                    firstInterval: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                                    lastInterval: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
            }
            return values
        }
        return JournalWindow(changes: BoundedWindow(items: items, total: total), gaps: try changes(from: from, through: through, limit: 1).gaps)
    }

    /// The oldest interval still held; before it the journal knows nothing.
    public func coverageStart() throws -> Date? {
        try connection.withStatement("SELECT MIN(interval_start) FROM journal_dirty") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    // MARK: Internals

    private static func pathKey(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func volumeKey(_ uuid: String) -> Int64 {
        Int64(bitPattern: SHA256.hash(data: Data(uuid.utf8)).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }

    /// Within the per-interval cap the path is kept; beyond it the change
    /// moves up to the first ancestor already present, or to its root.
    private func fitted(path: String, interval: Double, roots: [String]) throws -> String {
        let present = try connection.withStatement("SELECT COUNT(*) FROM journal_dirty WHERE interval_start = ? AND kind = 'changed'") { statement -> Int64 in
            try connection.bind(interval, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError() }
            return sqlite3_column_int64(statement, 0)
        }
        guard present >= Self.directoriesPerInterval, try existingRow(path: path, kind: "changed", interval: interval) == nil else { return path }
        let root = roots.map(Self.normalized).filter { path == $0 || path.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count }) ?? "/"
        var candidate = Self.parent(path)
        while candidate.count > root.count, try existingRow(path: candidate, kind: "changed", interval: interval) == nil {
            candidate = Self.parent(candidate)
        }
        return candidate.count < root.count ? root : candidate
    }

    private func existingRow(path: String, kind: String, interval: Double) throws -> Int64? {
        try connection.withStatement("SELECT rowid FROM journal_dirty WHERE interval_start = ? AND path_key = ? AND kind = ? LIMIT 1") { statement in
            try connection.bind(interval, at: 1, in: statement)
            try connection.bind(Self.pathKey(path), at: 2, in: statement)
            try connection.bind(kind, at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func upsert(path: String, kind: String, changes: Int64, interval: Double) throws {
        guard let table = Self.tables["journal_dirty"] else { return }
        if let rowid = try existingRow(path: path, kind: kind, interval: interval) {
            try connection.withStatement("UPDATE journal_dirty SET changes = changes + ? WHERE rowid = ?") { statement in
                try connection.bind(changes, at: 1, in: statement)
                try connection.bind(rowid, at: 2, in: statement)
                try connection.stepDone(statement)
            }
            return
        }
        let stored = String(path.utf8.prefix(BoundedStoreContract.pathBytes)) ?? path
        _ = try connection.insertBounded(table, rows: [[
            "interval_start": .real(interval), "path_key": .text(Self.pathKey(path)), "path": .text(stored),
            "kind": .text(kind), "changes": .integer(changes),
        ]])
    }

    private func prune(before date: Date) throws {
        try connection.withStatement("DELETE FROM journal_dirty WHERE interval_start < ?") { statement in
            try connection.bind(Self.intervalStart(date).timeIntervalSince1970, at: 1, in: statement)
            try connection.stepDone(statement)
        }
    }
}
