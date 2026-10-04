import CSQLite
@testable import DiskStewardCore
import Foundation
import XCTest

/// CONTRACT-602: row and byte caps hold at write, oversized rows are refused
/// at write, readers return bounded windows, and the static budget proves the
/// 32 MiB ceiling.
final class BoundedStoreContractTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "bounded-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func connection(_ file: BoundedStoreFile) throws -> SQLiteConnection {
        let connection = try SQLiteConnection(url: directory.appending(path: "\(file.rawValue).sqlite"))
        try connection.prepareBoundedStore(file)
        return connection
    }

    /// A row for any table: every text column filled to `fill` bytes (or its
    /// limit), numbers from `order` so eviction order is deterministic.
    private func row(_ table: BoundedTable, order: Int, group: String? = nil, fill: Int? = nil) -> [String: BoundedValue] {
        var values: [String: BoundedValue] = [:]
        for column in table.columns {
            switch column.kind {
            case .integer: values[column.name] = .integer(Int64(order))
            case .real: values[column.name] = .real(Double(order))
            case .text:
                let size = min(column.maximumBytes, fill ?? 8)
                values[column.name] = .text(String(repeating: "x", count: max(0, size - 8)) + String(format: "%08d", order % 100_000_000).suffix(min(8, size)))
            }
        }
        if let group, case let .oldestGroup(groupColumn, orderColumn) = table.eviction {
            values[groupColumn] = .text(group)
            values[orderColumn] = .real(Double(order))
        }
        return values
    }

    private func usage(_ connection: SQLiteConnection, _ table: BoundedTable) throws -> (rows: Int64, bytes: Int64) {
        try connection.withStatement("SELECT COUNT(*), COALESCE(SUM(\(table.payloadExpression)), 0) FROM \(table.name)") { statement in
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
        }
    }

    func testStaticBudgetProvesTheCeiling() {
        XCTAssertEqual(BoundedStoreContract.validateBudget(), [])
        XCTAssertLessThanOrEqual(BoundedStoreContract.worstCaseBytes, BoundedStoreContract.ceilingBytes)
        let names = Set(BoundedStoreContract.allTables.map(\.name))
        for required in ["capacity_fine", "capacity_hourly", "journal_cursors", "journal_dirty", "object_index",
                         "review_reports", "review_items", "sessions", "session_impacts"] {
            XCTAssertTrue(names.contains(required), required)
        }
        for table in BoundedStoreContract.allTables {
            XCTAssertFalse(table.columns.contains { $0.indexed && $0.maximumBytes >= BoundedStoreContract.pathBytes }, "\(table.name) indexes a path")
        }
        // The index term counts: byte caps alone inside the ceiling, index
        // entries pushing it over, must fail.
        let wide = BoundedTable(name: "wide", columns: [.text("key", 64, indexed: true), .text("body", 64)],
                                rowCap: 500_000, byteCap: 1 * 1_024 * 1_024, eviction: .oldestFirst(column: "key"))
        XCTAssertLessThan(wide.byteCap, BoundedStoreContract.ceilingBytes)
        XCTAssertFalse(BoundedStoreContract.validateBudget([wide]).isEmpty, "index entries must count against the ceiling")
        let unindexedOrder = BoundedTable(name: "bad", columns: [.text("path", 1_024), .real("at")], rowCap: 10, byteCap: 1 * 1_024 * 1_024,
                                          eviction: .oldestFirst(column: "at"))
        XCTAssertFalse(BoundedStoreContract.validateBudget([unindexedOrder]).isEmpty, "eviction needs an indexed order column")
    }

    func testInsertingCapPlusOneKeepsEveryTableAtItsCap() throws {
        for file in [BoundedStoreFile.capacityRing, .steward] {
            let connection = try connection(file)
            defer { connection.close() }
            for table in BoundedStoreContract.tables[file] ?? [] {
                switch table.eviction {
                case .oldestFirst:
                    let report = try connection.insertBounded(table, rows: (0...table.rowCap).map { row(table, order: $0) })
                    XCTAssertEqual(report.inserted, table.rowCap + 1, table.name)
                    XCTAssertEqual(try usage(connection, table).rows, Int64(table.rowCap), table.name)
                    let oldest = try connection.scalarInt("SELECT COUNT(*) FROM \(table.name) WHERE rowid = 1")
                    XCTAssertEqual(oldest, 0, "\(table.name): the oldest row was evicted")
                case .oldestGroup:
                    // Fill with groups of 1,000 rows, then one more group.
                    let groups = table.rowCap / 1_000 + 1
                    for group in 0..<groups {
                        _ = try connection.insertBounded(table, rows: (0..<1_000).map { row(table, order: group * 1_000 + $0, group: "g\(group)") })
                    }
                    let (rows, _) = try usage(connection, table)
                    XCTAssertLessThanOrEqual(rows, Int64(table.rowCap), table.name)
                    XCTAssertEqual(try connection.scalarInt("SELECT COUNT(*) FROM \(table.name) WHERE \(groupColumn(table)) = 'g0'"), 0,
                                   "\(table.name): the oldest whole group was evicted")
                    XCTAssertEqual(try connection.scalarInt("SELECT COUNT(*) FROM \(table.name) WHERE \(groupColumn(table)) = 'g\(groups - 1)'"), 1_000,
                                   "\(table.name): the newest group is complete")
                }
            }
        }
    }

    private func groupColumn(_ table: BoundedTable) -> String {
        if case let .oldestGroup(group, _) = table.eviction { return group }
        return ""
    }

    func testByteCapEvictsTheOldestRowsEvenUnderTheRowCap() throws {
        let connection = try connection(.steward)
        defer { connection.close() }
        let table = try XCTUnwrap(BoundedStoreContract.tables[.steward]?.first { $0.name == "journal_dirty" })
        let maximumRows = Int(table.byteCap) / table.maximumRowBytes + 50
        XCTAssertLessThan(maximumRows, table.rowCap, "this fixture exercises the byte cap, not the row cap")
        _ = try connection.insertBounded(table, rows: (0..<maximumRows).map { row(table, order: $0, fill: BoundedStoreContract.pathBytes) })
        let (rows, bytes) = try usage(connection, table)
        XCTAssertLessThanOrEqual(bytes, table.byteCap)
        XCTAssertLessThan(rows, Int64(maximumRows))
        let newest = try connection.scalarInt("SELECT MAX(interval_start) FROM \(table.name)")
        XCTAssertEqual(newest, Int64(maximumRows - 1), "the newest rows are kept")
    }

    func testOversizedRowIsRefusedAtWriteAndReported() throws {
        let connection = try connection(.steward)
        defer { connection.close() }
        let table = try XCTUnwrap(BoundedStoreContract.tables[.steward]?.first { $0.name == "object_index" })
        var oversized = row(table, order: 2)
        oversized["path"] = .text(String(repeating: "p", count: BoundedStoreContract.pathBytes + 1))
        let report = try connection.insertBounded(table, rows: [row(table, order: 1), oversized, row(table, order: 3)])
        XCTAssertEqual(report.inserted, 2)
        XCTAssertEqual(report.refused.count, 1)
        XCTAssertTrue(report.refused[0].contains("path is 1025 bytes"), report.refused[0])
        XCTAssertEqual(try usage(connection, table).rows, 2)
        XCTAssertThrowsError(try connection.insertBounded(table, rows: [["unknown": .integer(1)]]))
    }

    func testAGroupBatchLargerThanTheCapsIsRefusedWhole() throws {
        let connection = try connection(.steward)
        defer { connection.close() }
        let table = try XCTUnwrap(BoundedStoreContract.tables[.steward]?.first { $0.name == "review_items" })
        let tooMany = (0...table.rowCap).map { row(table, order: $0, group: "huge") }
        XCTAssertThrowsError(try connection.insertBounded(table, rows: tooMany)) { error in
            XCTAssertEqual(error as? BoundedStoreError, .batchExceedsCaps(table: "review_items"))
        }
        XCTAssertEqual(try usage(connection, table).rows, 0, "nothing of a refused batch is written")
    }

    func testEveryReaderAtCapAnswersAWindowUnderTheResponseCeiling() throws {
        for file in [BoundedStoreFile.capacityRing, .steward] {
            let connection = try connection(file)
            defer { connection.close() }
            for table in BoundedStoreContract.tables[file] ?? [] {
                // Maximum-size rows up to the byte cap, at most the row cap.
                let rows = min(table.rowCap, Int(table.byteCap) / table.maximumRowBytes)
                if case .oldestGroup = table.eviction {
                    let perGroup = max(1, rows / 2)
                    for group in 0..<2 {
                        _ = try connection.insertBounded(table, rows: (0..<perGroup).map {
                            row(table, order: group * perGroup + $0, group: "g\(group)", fill: Int.max)
                        })
                    }
                } else {
                    _ = try connection.insertBounded(table, rows: (0..<rows).map { row(table, order: $0, fill: Int.max) })
                }
                let order: String
                switch table.eviction {
                case let .oldestFirst(column): order = column
                case let .oldestGroup(_, column): order = column
                }
                var payload = 0
                let window = try connection.readBoundedWindow(table, orderBy: order, limit: 1_000_000) { statement -> Int in
                    (0..<Int32(table.columns.count)).reduce(0) { $0 + Int(sqlite3_column_bytes(statement, $1)) }
                }
                payload = window.items.reduce(0, +)
                XCTAssertGreaterThan(window.items.count, 0, table.name)
                XCTAssertLessThanOrEqual(payload, BoundedStoreContract.responseCeilingBytes, table.name)
                XCTAssertEqual(window.total, Int(try usage(connection, table).rows), table.name)
                XCTAssertEqual(window.truncated, window.items.count < window.total, table.name)
            }
        }
    }

    func testFilesUseTheirJournalModes() throws {
        let ring = try connection(.capacityRing)
        defer { ring.close() }
        let steward = try connection(.steward)
        defer { steward.close() }
        let ringMode = try ring.withStatement("PRAGMA journal_mode") { statement -> String in
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return String(cString: sqlite3_column_text(statement, 0))
        }
        let stewardMode = try steward.withStatement("PRAGMA journal_mode") { statement -> String in
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return String(cString: sqlite3_column_text(statement, 0))
        }
        XCTAssertEqual(ringMode, "delete")
        XCTAssertEqual(stewardMode, "wal")
    }
}
