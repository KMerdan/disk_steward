import CryptoKit
import CSQLite
import Foundation

/// An object as stored in the capped index.
public struct IndexedObject: Sendable, Equatable {
    public let objectID: String
    public let projectID: String
    public let path: String
    public let kind: String
    public let recreateClass: String
    public let allocatedBytes: Int64
    public let fileCount: Int64
    public let measuredAt: Date
    public let lastActivity: Date
}

public struct StoredReviewReport: Sendable, Equatable {
    public let reportID: String
    public let scope: String
    public let startedAt: Date
    public let completedAt: Date
    public let coverage: String
    public let status: String
    public let totalItems: Int64
    public let truncated: Bool
    public let limitations: [String]
}

public struct ReviewIndexWrite: Sendable, Equatable {
    public let objectsStored: Int
    public let objectsOmitted: Int
    public let projectsStored: Int
}

public enum ReviewIndexError: Error, Equatable, Sendable {
    /// The bounded store refused a row it must keep, such as the report itself.
    case refused(table: String, reasons: [String])
}

/// TASK-621: objects, projects and review reports in the steward file, under
/// the CONTRACT-602 caps. Only objects are stored; never a file inside one.
public actor ReviewIndex {
    public static let maximumObjects = 20_000
    public static let maximumProjects = 2_000
    private let connection: SQLiteConnection
    private static var tables: [String: BoundedTable] {
        Dictionary(uniqueKeysWithValues: (BoundedStoreContract.tables[.steward] ?? []).map { ($0.name, $0) })
    }

    public init(url: URL) throws {
        connection = try SQLiteConnection(url: url)
        try connection.prepareBoundedStore(.steward)
    }

    public func close() { connection.close() }

    static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Replaces the scope's objects and projects with the review's and adds
    /// its report. The largest objects are kept when there are more than the
    /// index holds; the report says how many were left out.
    @discardableResult
    public func record(_ report: ReviewReport) throws -> ReviewIndexWrite {
        guard let objectTable = Self.tables["object_index"], let projectTable = Self.tables["projects"],
              let reportTable = Self.tables["review_reports"] else { throw ReviewIndexError.refused(table: "contract", reasons: ["missing table"]) }
        let pathLimit = BoundedStoreContract.pathBytes
        let measuredAt = report.completedAt.timeIntervalSince1970
        // Only a complete review replaces what is known about its scope; a
        // stopped one adds what it measured without erasing the rest.
        if report.status == .completed { try deleteRows(in: "object_index", under: report.scope) }
        try deleteRows(in: "projects", under: report.scope)

        let storable = report.objects.filter { $0.path.utf8.count <= pathLimit }
        let kept = Array(storable.prefix(Self.maximumObjects))
        if report.status != .completed, !kept.isEmpty {
            try connection.withStatement("DELETE FROM object_index WHERE path_key = ?") { statement in
                for object in kept {
                    sqlite3_reset(statement)
                    try connection.bind(Self.key(object.path), at: 1, in: statement)
                    try connection.stepDone(statement)
                }
            }
        }
        let objectRows: [[String: BoundedValue]] = kept.map { object in [
            "object_id": .text(Self.key("object\u{0}" + object.path)), "project_id": .text(object.projectPath.map(Self.key) ?? ""),
            "path_key": .text(Self.key(object.path)), "path": .text(object.path), "kind": .text(object.kind.rawValue),
            "recreate_class": .text(object.recreateClass.rawValue), "allocated_bytes": .integer(object.allocatedBytes),
            "file_count": .integer(Int64(object.fileCount)), "measured_at": .real(measuredAt), "last_activity": .real(object.lastActivity),
        ] }
        if !objectRows.isEmpty {
            let written = try connection.insertBounded(objectTable, rows: objectRows)
            guard written.refused.isEmpty else { throw ReviewIndexError.refused(table: "object_index", reasons: written.refused) }
        }
        let referenced = Set(kept.compactMap(\.projectPath))
        let projects = report.projects.filter { $0.path.utf8.count <= pathLimit }
            .sorted { (referenced.contains($0.path) ? 0 : 1, -$0.lastSourceActivity) < (referenced.contains($1.path) ? 0 : 1, -$1.lastSourceActivity) }
            .prefix(Self.maximumProjects)
        if !projects.isEmpty {
            let written = try connection.insertBounded(projectTable, rows: projects.map { project in [
                "project_id": .text(Self.key(project.path)), "path": .text(project.path),
                "kind": .text(String(project.marker.prefix(32))), "last_source_activity": .real(project.lastSourceActivity),
            ] })
            guard written.refused.isEmpty else { throw ReviewIndexError.refused(table: "projects", reasons: written.refused) }
        }
        let omitted = report.objects.count - kept.count
        var limitations = report.limitations
        if omitted > 0 { limitations.insert("The index keeps the \(kept.count) largest of \(report.objects.count) objects; \(omitted) smaller ones are not stored.", at: 0) }
        let encodedLimitations = Self.fitting(limitations, bytes: 4_096)
        let written = try connection.insertBounded(reportTable, rows: [[
            "report_id": .text(report.reportID), "scope": .text(String(report.scope.utf8.prefix(pathLimit)) ?? report.scope),
            "started_at": .real(report.startedAt.timeIntervalSince1970), "completed_at": .real(measuredAt),
            "coverage": .text(report.isComplete ? "complete" : "partial"), "status": .text(String(report.status.label.prefix(32))),
            "total_items": .integer(Int64(report.objects.count)), "truncated": .integer(omitted > 0 || !report.isComplete ? 1 : 0),
            "limitations": .text(encodedLimitations),
        ]])
        guard written.refused.isEmpty else { throw ReviewIndexError.refused(table: "review_reports", reasons: written.refused) }
        return ReviewIndexWrite(objectsStored: kept.count, objectsOmitted: omitted, projectsStored: projects.count)
    }

    /// Objects under a scope, largest first, in a bounded window.
    public func objects(under scope: String, limit: Int) throws -> BoundedWindow<IndexedObject> {
        let prefix = scope == "/" ? "/" : scope + "/"
        let total = Int(try connection.withStatement("SELECT COUNT(*) FROM object_index WHERE path = ? OR substr(path, 1, ?) = ?") { statement -> Int64 in
            try connection.bind(scope, at: 1, in: statement)
            try connection.bind(Int64(prefix.utf8.count), at: 2, in: statement)
            try connection.bind(prefix, at: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError() }
            return sqlite3_column_int64(statement, 0)
        })
        let items = try connection.withStatement("""
            SELECT object_id, project_id, path, kind, recreate_class, allocated_bytes, file_count, measured_at, last_activity
            FROM object_index WHERE path = ? OR substr(path, 1, ?) = ? ORDER BY allocated_bytes DESC, path ASC LIMIT ?
            """) { statement -> [IndexedObject] in
            try connection.bind(scope, at: 1, in: statement)
            try connection.bind(Int64(prefix.utf8.count), at: 2, in: statement)
            try connection.bind(prefix, at: 3, in: statement)
            try connection.bind(Int64(max(1, min(limit, Self.maximumObjects))), at: 4, in: statement)
            var rows: [IndexedObject] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
                rows.append(IndexedObject(objectID: text(0), projectID: text(1), path: text(2), kind: text(3), recreateClass: text(4),
                                          allocatedBytes: sqlite3_column_int64(statement, 5), fileCount: sqlite3_column_int64(statement, 6),
                                          measuredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                                          lastActivity: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))))
            }
            return rows
        }
        return BoundedWindow(items: items, total: total)
    }

    public func latestReport(scope: String) throws -> StoredReviewReport? {
        try connection.withStatement("""
            SELECT report_id, scope, started_at, completed_at, coverage, status, total_items, truncated, limitations
            FROM review_reports WHERE scope = ? ORDER BY started_at DESC LIMIT 1
            """) { statement in
            try connection.bind(scope, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            let limitations = (try? JSONDecoder().decode([String].self, from: Data(text(8).utf8))) ?? []
            return StoredReviewReport(reportID: text(0), scope: text(1), startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                                      completedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), coverage: text(4), status: text(5),
                                      totalItems: sqlite3_column_int64(statement, 6), truncated: sqlite3_column_int64(statement, 7) != 0, limitations: limitations)
        }
    }

    /// Row counts, for tests and diagnostics.
    public func count(_ table: String) throws -> Int {
        guard Self.tables[table] != nil else { return 0 }
        return Int(try connection.scalarInt("SELECT COUNT(*) FROM \(table)"))
    }

    private func deleteRows(in table: String, under scope: String) throws {
        let prefix = scope == "/" ? "/" : scope + "/"
        try connection.withStatement("DELETE FROM \(table) WHERE path = ? OR substr(path, 1, ?) = ?") { statement in
            try connection.bind(scope, at: 1, in: statement)
            try connection.bind(Int64(prefix.utf8.count), at: 2, in: statement)
            try connection.bind(prefix, at: 3, in: statement)
            try connection.stepDone(statement)
        }
    }

    /// A JSON list of sentences that fits the column: whole sentences only,
    /// dropping the last ones with a note when the list is too long.
    static func fitting(_ lines: [String], bytes: Int) -> String {
        var kept = lines
        while true {
            let note = kept.count < lines.count ? ["\(lines.count - kept.count) further limitations were not stored."] : []
            let data = (try? JSONEncoder().encode(kept + note)) ?? Data("[]".utf8)
            if data.count <= bytes || kept.isEmpty { return String(decoding: data.count <= bytes ? data : Data("[]".utf8), as: UTF8.self) }
            kept.removeLast()
        }
    }
}

/// Per-scope review memory outside the store: the entry count of the last
/// complete review and the cooldown after a stop. No frontier is ever kept,
/// so nothing resumes after a relaunch.
public struct ReviewScopeState: Codable, Sendable, Equatable {
    public var lastCompleteEntries: Int?
    public var cooldownUntil: Date?
    public var lastStatus: String?
    public var updatedAt: Date
}

public enum ReviewError: Error, Equatable, Sendable {
    case coolingDown(until: Date)
    case busy
    case scopeUnavailable(String)
}

/// Runs one review at a time on its own utility-QoS thread, stores the
/// report, and enforces the 24-hour cooldown after a stopped review.
public actor ReviewService {
    public static let cooldown: TimeInterval = 24 * 60 * 60
    public static let maximumRememberedScopes = 64
    private let index: ReviewIndex
    private let stateURL: URL
    private let makeWalker: @Sendable (_ previousCompleteEntries: Int?, _ isCancelled: @escaping @Sendable () -> Bool) -> ReviewWalker
    private let now: @Sendable () -> Date
    private var running = false
    private let queue = DispatchQueue(label: "dev.disksteward.review", qos: .utility)

    public init(index: ReviewIndex, stateURL: URL, now: @escaping @Sendable () -> Date = Date.init,
                makeWalker: @escaping @Sendable (_ previousCompleteEntries: Int?, _ isCancelled: @escaping @Sendable () -> Bool) -> ReviewWalker = { previous, cancelled in
                    ReviewWalker(previousCompleteEntries: previous, isCancelled: cancelled)
                }) {
        self.index = index
        self.stateURL = stateURL
        self.now = now
        self.makeWalker = makeWalker
    }

    public static func defaultStateURL(beside stewardURL: URL) -> URL {
        stewardURL.deletingLastPathComponent().appending(path: "review-state.json")
    }

    public func state(for scope: String) -> ReviewScopeState? { loadState()[scope] }

    public func review(scope requested: String, excluded: [String] = []) async throws -> ReviewReport {
        guard !running else { throw ReviewError.busy }
        let scope = DirectoryChangeStream.canonicalPath(requested)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scope, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReviewError.scopeUnavailable(requested)
        }
        var states = loadState()
        let started = now()
        if let until = states[scope]?.cooldownUntil, until > started { throw ReviewError.coolingDown(until: until) }
        running = true
        defer { running = false }
        let flag = cancel
        flag.reset()
        let walker = makeWalker(states[scope]?.lastCompleteEntries, { flag.value })
        let excludedPaths = excluded.map(DirectoryChangeStream.canonicalPath)
        let queue = self.queue
        let report: ReviewReport = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: walker.review(scope: scope, excluded: excludedPaths, startedAt: started)) }
            }
        } onCancel: { flag.set() }
        try await index.record(report)
        var entry = states[scope] ?? ReviewScopeState(updatedAt: started)
        entry.updatedAt = report.completedAt
        entry.lastStatus = report.status.label
        switch report.status {
        case .completed:
            entry.lastCompleteEntries = report.entriesVisited
            entry.cooldownUntil = nil
        case .stopped(.cancelled):
            break
        case .stopped:
            // The baseline stays the last complete review's; a stop never lowers it.
            entry.cooldownUntil = report.completedAt.addingTimeInterval(Self.cooldown)
        }
        states[scope] = entry
        saveState(states)
        return report
    }

    private let cancel = CancelFlag()

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func set() { lock.withLock { raised = true } }
        func reset() { lock.withLock { raised = false } }
        var value: Bool { lock.withLock { raised } }
    }

    private func loadState() -> [String: ReviewScopeState] {
        guard let data = try? Data(contentsOf: stateURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: ReviewScopeState].self, from: data)) ?? [:]
    }

    private func saveState(_ states: [String: ReviewScopeState]) {
        let kept = Dictionary(uniqueKeysWithValues: states.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(Self.maximumRememberedScopes).map { ($0.key, $0.value) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(kept).write(to: stateURL, options: .atomic)
    }
}
