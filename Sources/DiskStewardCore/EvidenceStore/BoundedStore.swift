import CSQLite
import Foundation

/// CONTRACT-602: every table of the redesigned stores is bounded at write, by
/// rows and by payload bytes, and read only through bounded windows.
/// See docs/reliability/evidence/CONTRACT-602/bounded-store-contract.md.
public struct BoundedColumn: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case text, integer, real }
    public let name: String
    public let kind: Kind
    /// Text values longer than this (UTF-8 bytes) refuse their row at write;
    /// numeric columns count 8 bytes.
    public let maximumBytes: Int
    /// Only short keys may be indexed; paths never are.
    public let indexed: Bool

    public static func text(_ name: String, _ maximumBytes: Int, indexed: Bool = false) -> BoundedColumn {
        .init(name: name, kind: .text, maximumBytes: maximumBytes, indexed: indexed)
    }
    public static func integer(_ name: String, indexed: Bool = false) -> BoundedColumn {
        .init(name: name, kind: .integer, maximumBytes: 8, indexed: indexed)
    }
    public static func real(_ name: String, indexed: Bool = false) -> BoundedColumn {
        .init(name: name, kind: .real, maximumBytes: 8, indexed: indexed)
    }
}

/// What gives way when a table is over either cap.
public enum BoundedEviction: Equatable, Sendable {
    /// Rows with the smallest `column` value go first (oldest sample,
    /// interval or measurement).
    case oldestFirst(column: String)
    /// Whole groups go, oldest `order` first (a whole report or session with
    /// its rows). A single batch must fit the caps on its own.
    case oldestGroup(group: String, order: String)
}

public struct BoundedTable: Equatable, Sendable {
    public let name: String
    public let columns: [BoundedColumn]
    public let rowCap: Int
    public let byteCap: Int64
    public let eviction: BoundedEviction

    public init(name: String, columns: [BoundedColumn], rowCap: Int, byteCap: Int64, eviction: BoundedEviction) {
        self.name = name
        self.columns = columns
        self.rowCap = rowCap
        self.byteCap = byteCap
        self.eviction = eviction
    }

    public var maximumRowBytes: Int { columns.reduce(0) { $0 + $1.maximumBytes } }
    /// Index entry bytes per row: indexed keys plus the rowid each entry carries.
    public var indexBytesPerRow: Int { columns.filter(\.indexed).reduce(0) { $0 + $1.maximumBytes + 8 } }
    /// Worst-case live bytes: payload is held under `byteCap`, index entries
    /// grow with rows.
    public var worstCaseBytes: Int64 { byteCap + Int64(rowCap) * Int64(indexBytesPerRow) }

    /// SQL for one row's payload bytes, the unit `byteCap` counts.
    var payloadExpression: String {
        columns.map { $0.kind == .text ? "COALESCE(length(CAST(\($0.name) AS BLOB)), 0)" : "8" }.joined(separator: " + ")
    }
}

public enum BoundedStoreFile: String, Equatable, Sendable {
    /// Capacity samples only, in its own file: written every few minutes, so a
    /// rollback journal and no -wal/-shm files.
    case capacityRing
    /// Change journal, objects, reviews and sessions.
    case steward
}

public enum BoundedStoreContract {
    /// Live-page ceiling across both files. Freed pages stay on SQLite's
    /// freelist, so a file sits at its steady-state maximum after eviction.
    public static let ceilingBytes: Int64 = 32 * 1_024 * 1_024
    /// The steward file's write-ahead log is bounded separately.
    public static let walLimitBytes: Int64 = 4 * 1_024 * 1_024
    /// One encoded answer never exceeds this.
    public static let responseCeilingBytes = 1_024 * 1_024
    public static let maximumIndexedColumnBytes = 64
    public static let pathBytes = 1_024

    public static let tables: [BoundedStoreFile: [BoundedTable]] = [
        .capacityRing: [
            .init(name: "capacity_volumes",
                  columns: [.integer("volume_id", indexed: true), .text("volume_uuid", 64), .text("mount_path", pathBytes), .real("first_seen_at", indexed: true)],
                  rowCap: 16, byteCap: 32 * 1_024, eviction: .oldestFirst(column: "first_seen_at")),
            .init(name: "capacity_fine",
                  columns: [.integer("volume_id", indexed: true), .real("observed_at", indexed: true), .integer("total_bytes"),
                            .integer("available_bytes"), .integer("important_available_bytes")],
                  rowCap: 4 * 2_016, byteCap: 384 * 1_024, eviction: .oldestFirst(column: "observed_at")),
            .init(name: "capacity_hourly",
                  columns: [.integer("volume_id", indexed: true), .real("observed_at", indexed: true), .integer("total_bytes"),
                            .integer("available_bytes"), .integer("important_available_bytes")],
                  rowCap: 4 * 8_760, byteCap: 1_536 * 1_024, eviction: .oldestFirst(column: "observed_at")),
        ],
        .steward: [
            .init(name: "journal_cursors",
                  columns: [.integer("volume_id", indexed: true), .text("fsevents_uuid", 64), .integer("last_event_id"), .real("updated_at", indexed: true)],
                  rowCap: 16, byteCap: 16 * 1_024, eviction: .oldestFirst(column: "updated_at")),
            .init(name: "journal_dirty",
                  columns: [.real("interval_start", indexed: true), .text("path_key", 32, indexed: true), .text("path", pathBytes),
                            .text("kind", 32), .integer("changes")],
                  rowCap: 14_000, byteCap: 3 * 1_024 * 1_024, eviction: .oldestFirst(column: "interval_start")),
            .init(name: "projects",
                  columns: [.text("project_id", 32, indexed: true), .text("path", pathBytes), .text("kind", 32), .real("last_source_activity", indexed: true)],
                  rowCap: 2_000, byteCap: 1 * 1_024 * 1_024, eviction: .oldestFirst(column: "last_source_activity")),
            .init(name: "object_index",
                  columns: [.text("object_id", 32, indexed: true), .text("project_id", 32, indexed: true), .text("path_key", 32, indexed: true),
                            .text("path", pathBytes), .text("kind", 32), .text("recreate_class", 32), .integer("allocated_bytes"),
                            .integer("file_count"), .real("measured_at", indexed: true), .real("last_activity")],
                  rowCap: 20_000, byteCap: 6 * 1_024 * 1_024, eviction: .oldestFirst(column: "measured_at")),
            .init(name: "review_reports",
                  columns: [.text("report_id", 32, indexed: true), .text("scope", pathBytes), .real("started_at", indexed: true),
                            .real("completed_at"), .text("coverage", 32), .text("status", 32), .integer("total_items"),
                            .integer("truncated"), .text("limitations", 4_096)],
                  rowCap: 20, byteCap: 128 * 1_024, eviction: .oldestFirst(column: "started_at")),
            .init(name: "review_items",
                  columns: [.text("report_id", 32, indexed: true), .real("report_started_at", indexed: true), .integer("rank", indexed: true),
                            .text("object_id", 32), .text("project_id", 32), .text("path", pathBytes), .text("kind", 32),
                            .text("recreate_class", 32), .integer("allocated_bytes"), .integer("reclaimable_bytes"), .text("state", 32),
                            .real("verified_at"), .text("reasons", 1_024)],
                  rowCap: 20 * 2_000, byteCap: 6 * 1_024 * 1_024, eviction: .oldestGroup(group: "report_id", order: "report_started_at")),
            .init(name: "sessions",
                  columns: [.text("session_id", 64, indexed: true), .text("cwd", pathBytes), .text("client", 64),
                            .real("started_at", indexed: true), .real("ended_at")],
                  rowCap: 500, byteCap: 512 * 1_024, eviction: .oldestFirst(column: "started_at")),
            .init(name: "session_impacts",
                  columns: [.text("session_id", 64, indexed: true), .real("session_started_at", indexed: true), .text("path_key", 32),
                            .text("path", pathBytes), .integer("changes")],
                  rowCap: 10_000, byteCap: 1_536 * 1_024, eviction: .oldestGroup(group: "session_id", order: "session_started_at")),
        ],
    ]

    public static var allTables: [BoundedTable] { [BoundedStoreFile.capacityRing, .steward].flatMap { tables[$0] ?? [] } }
    public static var worstCaseBytes: Int64 { allTables.reduce(0) { $0 + $1.worstCaseBytes } }

    /// Static proof of the ceiling and of the table rules; empty when valid.
    public static func validateBudget(_ candidate: [BoundedTable] = allTables, ceiling: Int64 = ceilingBytes) -> [String] {
        var problems: [String] = []
        var names = Set<String>()
        for table in candidate {
            if !names.insert(table.name).inserted { problems.append("\(table.name): duplicate table name") }
            if table.rowCap < 1 { problems.append("\(table.name): row cap must be positive") }
            if Int64(table.maximumRowBytes) > table.byteCap { problems.append("\(table.name): one maximum-size row exceeds the byte cap") }
            for column in table.columns where column.indexed && column.maximumBytes > maximumIndexedColumnBytes {
                problems.append("\(table.name).\(column.name): indexed column wider than \(maximumIndexedColumnBytes) bytes")
            }
            let orderColumns: [String]
            switch table.eviction {
            case let .oldestFirst(column): orderColumns = [column]
            case let .oldestGroup(group, order): orderColumns = [group, order]
            }
            for name in orderColumns where !table.columns.contains(where: { $0.name == name && $0.indexed }) {
                problems.append("\(table.name): eviction column \(name) must be an indexed column")
            }
        }
        let total = candidate.reduce(Int64(0)) { $0 + $1.worstCaseBytes }
        if total > ceiling { problems.append("worst-case live bytes \(total) exceed the \(ceiling)-byte ceiling") }
        return problems
    }
}

public enum BoundedValue: Equatable, Sendable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
}

public struct BoundedWriteReport: Equatable, Sendable {
    public var inserted = 0
    /// Rows refused at write because a column exceeded its limit.
    public var refused: [String] = []
    public var evicted = 0
}

public struct BoundedWindow<Item> {
    public let items: [Item]
    /// Every row in the table, listed or not.
    public let total: Int
    public var truncated: Bool { items.count < total }
}

extension BoundedWindow: Sendable where Item: Sendable {}
extension BoundedWindow: Equatable where Item: Equatable {}

public enum BoundedStoreError: Error, Equatable, Sendable {
    case unknownColumn(table: String, column: String)
    /// A group batch larger than the table's caps; the writer must truncate it.
    case batchExceedsCaps(table: String)
}

extension SQLiteConnection {
    /// Creates the file's tables and their short-key indexes. The ring uses a
    /// rollback journal; the steward file uses a bounded write-ahead log.
    func prepareBoundedStore(_ file: BoundedStoreFile) throws {
        switch file {
        case .capacityRing: try execute("PRAGMA journal_mode=DELETE")
        case .steward:
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA journal_size_limit=\(BoundedStoreContract.walLimitBytes)")
        }
        for table in BoundedStoreContract.tables[file] ?? [] { try createBoundedTable(table) }
    }

    func createBoundedTable(_ table: BoundedTable) throws {
        let columns = table.columns.map { column -> String in
            let type: String
            switch column.kind { case .text: type = "TEXT"; case .integer: type = "INTEGER"; case .real: type = "REAL" }
            return "\(column.name) \(type)"
        }.joined(separator: ", ")
        try execute("CREATE TABLE IF NOT EXISTS \(table.name) (\(columns))")
        for column in table.columns where column.indexed {
            try execute("CREATE INDEX IF NOT EXISTS \(table.name)_\(column.name) ON \(table.name)(\(column.name))")
        }
    }

    /// Inserts a batch in one transaction, refusing rows whose text exceeds a
    /// column limit, then enforces the row and byte caps by the table's rule.
    func insertBounded(_ table: BoundedTable, rows: [[String: BoundedValue]]) throws -> BoundedWriteReport {
        var report = BoundedWriteReport()
        let byName = Dictionary(uniqueKeysWithValues: table.columns.map { ($0.name, $0) })
        var accepted: [[String: BoundedValue]] = []
        for (index, row) in rows.enumerated() {
            var reason: String?
            for (name, value) in row {
                guard let column = byName[name] else { throw BoundedStoreError.unknownColumn(table: table.name, column: name) }
                if case let .text(text) = value, text.utf8.count > column.maximumBytes {
                    reason = "row \(index): \(name) is \(text.utf8.count) bytes, above its \(column.maximumBytes)-byte limit"
                    break
                }
            }
            if let reason { report.refused.append(reason) } else { accepted.append(row) }
        }
        if case .oldestGroup = table.eviction {
            let bytes = accepted.reduce(Int64(0)) { total, row in
                total + Int64(table.columns.reduce(0) { sum, column in
                    if case let .text(text)? = row[column.name] { return sum + text.utf8.count }
                    return sum + (column.kind == .text ? 0 : 8)
                })
            }
            guard accepted.count <= table.rowCap, bytes <= table.byteCap else { throw BoundedStoreError.batchExceedsCaps(table: table.name) }
        }
        try transaction {
            let names = table.columns.map(\.name)
            let sql = "INSERT INTO \(table.name) (\(names.joined(separator: ", "))) VALUES (\(names.map { _ in "?" }.joined(separator: ", ")))"
            try withStatement(sql) { statement in
                for row in accepted {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    for (offset, name) in names.enumerated() {
                        let index = Int32(offset + 1)
                        switch row[name] ?? .null {
                        case let .text(value): try bind(value, at: index, in: statement)
                        case let .integer(value): try bind(value, at: index, in: statement)
                        case let .real(value): try bind(value, at: index, in: statement)
                        case .null: try bindNull(at: index, in: statement)
                        }
                    }
                    try stepDone(statement)
                    report.inserted += 1
                }
            }
            report.evicted = try enforceBoundedCaps(table)
        }
        return report
    }

    /// Deletes by the table's rule until both caps hold; returns rows removed.
    func enforceBoundedCaps(_ table: BoundedTable) throws -> Int {
        var removed = 0
        func usage() throws -> (rows: Int64, bytes: Int64) {
            try withStatement("SELECT COUNT(*), COALESCE(SUM(\(table.payloadExpression)), 0) FROM \(table.name)") { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
                return (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
            }
        }
        var current = try usage()
        switch table.eviction {
        case let .oldestFirst(column):
            guard current.rows > table.rowCap || current.bytes > table.byteCap else { return 0 }
            // The shortest oldest prefix that removes both the row excess and
            // the byte excess, in one statement.
            let rowExcess = max(0, current.rows - Int64(table.rowCap))
            let byteExcess = max(0, current.bytes - table.byteCap)
            try withStatement("""
                DELETE FROM \(table.name) WHERE rowid IN (
                  SELECT rowid FROM (
                    SELECT rowid,
                           ROW_NUMBER() OVER (ORDER BY \(column) ASC, rowid ASC) AS position,
                           SUM(\(table.payloadExpression)) OVER (ORDER BY \(column) ASC, rowid ASC ROWS UNBOUNDED PRECEDING) - (\(table.payloadExpression)) AS before
                    FROM \(table.name))
                  WHERE position <= ? OR before < ?)
                """) { statement in
                try bind(rowExcess, at: 1, in: statement)
                try bind(byteExcess, at: 2, in: statement)
                try stepDone(statement)
            }
            removed = try changeCount()
        case let .oldestGroup(group, order):
            while current.rows > table.rowCap || current.bytes > table.byteCap {
                let groups = try scalarInt("SELECT COUNT(DISTINCT \(group)) FROM \(table.name)")
                guard groups > 1 else { break }  // the newest group fits by construction
                try withStatement("DELETE FROM \(table.name) WHERE \(group) = (SELECT \(group) FROM \(table.name) GROUP BY \(group) ORDER BY MIN(\(order)) ASC LIMIT 1)") { statement in
                    try stepDone(statement)
                }
                removed += try changeCount()
                current = try usage()
            }
        }
        return removed
    }

    /// One bounded window ordered by an indexed column, with the total. The
    /// row limit is clamped so a window of maximum-size rows fits the
    /// response ceiling; a full table is listed in part, never refused.
    func readBoundedWindow<Item>(
        _ table: BoundedTable, orderBy column: String, descending: Bool = true, limit: Int,
        map: (OpaquePointer) throws -> Item
    ) throws -> BoundedWindow<Item> {
        let affordable = max(1, (BoundedStoreContract.responseCeilingBytes - 8 * 1_024) / max(1, table.maximumRowBytes))
        let applied = min(max(limit, 1), affordable)
        let total = Int(try scalarInt("SELECT COUNT(*) FROM \(table.name)"))
        let items = try withStatement(
            "SELECT \(table.columns.map(\.name).joined(separator: ", ")) FROM \(table.name) ORDER BY \(column) \(descending ? "DESC" : "ASC"), rowid \(descending ? "DESC" : "ASC") LIMIT \(applied)"
        ) { statement -> [Item] in
            var values: [Item] = []
            while sqlite3_step(statement) == SQLITE_ROW { values.append(try map(statement)) }
            return values
        }
        return BoundedWindow(items: items, total: total)
    }
}
