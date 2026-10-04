import CryptoKit
import CSQLite
import Foundation

/// How a changed directory relates to a session's workspace root.
public enum SessionRelation: String, Codable, Sendable {
    /// The workspace root itself.
    case at
    /// Inside the workspace.
    case inside
    /// An ancestor of the workspace: the journal collapsed a change two levels
    /// below its watched root, so the change may lie outside the workspace.
    case containsWorkspace = "contains-workspace"

    /// The closest relation of `path` to any of `roots`, with that root.
    public static func of(_ path: String, roots: [String]) -> (relation: SessionRelation, root: String)? {
        var best: (relation: SessionRelation, root: String)?
        for root in roots {
            let relation: SessionRelation
            if path == root {
                relation = .at
            } else if path.hasPrefix(root == "/" ? "/" : root + "/") {
                relation = .inside
            } else if root.hasPrefix(path == "/" ? "/" : path + "/") {
                relation = .containsWorkspace
            } else {
                continue
            }
            if best == nil || rank(relation) < rank(best!.relation) || (rank(relation) == rank(best!.relation) && root.count > best!.root.count) {
                best = (relation, root)
            }
        }
        return best
    }

    private static func rank(_ relation: SessionRelation) -> Int {
        switch relation {
        case .at: 0
        case .inside: 1
        case .containsWorkspace: 2
        }
    }
}

/// A session as the steward file keeps it, so it can be asked about after
/// the app relaunches.
public struct PersistedSession: Sendable, Equatable {
    /// The stored session key: the session ID, or its hash when longer than 64 bytes.
    public let key: String
    public let client: String
    public let roots: [String]
    /// Roots that did not fit the 1 KiB column were dropped.
    public let rootsTruncated: Bool
    public let startedAt: Date
    /// When it ended, or when its lease ends; later than now means still open.
    public let endsAt: Date
}

/// One changed directory in a session's window.
public struct SessionDirectory: Sendable, Equatable {
    public let path: String
    public let relation: SessionRelation
    /// The workspace root it relates to.
    public let root: String
    public let changes: Int64
    /// Nil when read back from a frozen impact, which keeps no intervals.
    public let firstInterval: Date?
    public let lastInterval: Date?
    /// Other sessions whose workspace and window also cover this directory.
    public let alsoActiveSessions: Int

    public init(path: String, relation: SessionRelation, root: String, changes: Int64, firstInterval: Date?, lastInterval: Date?, alsoActiveSessions: Int) {
        self.path = path
        self.relation = relation
        self.root = root
        self.changes = changes
        self.firstInterval = firstInterval
        self.lastInterval = lastInterval
        self.alsoActiveSessions = alsoActiveSessions
    }
}

/// TASK-672: a session's directory impact from the change journal's dirty
/// sets. The journal records that a directory changed, not who changed it, so
/// every directory is a correlation with the session's workspace and window.
public enum SessionImpact {
    public static let maximumDirectories = 200

    public struct Directories: Sendable, Equatable {
        public let items: [SessionDirectory]
        public let total: Int
        /// Rows at a watched root itself: the journal's overflow collapse.
        /// They contain every workspace, so they are reported apart.
        public let overflow: [JournalChange]

        public init(items: [SessionDirectory], total: Int, overflow: [JournalChange]) {
            self.items = items
            self.total = total
            self.overflow = overflow
        }
    }

    public static func directories(changes: [JournalChange], roots: [String], watchedRoots: Set<String>,
                                   others: [[String]], limit: Int = maximumDirectories) -> Directories {
        var items: [SessionDirectory] = []
        var overflow: [JournalChange] = []
        for change in changes {
            guard let (relation, root) = SessionRelation.of(change.path, roots: roots) else { continue }
            if relation == .containsWorkspace, watchedRoots.contains(change.path) {
                overflow.append(change)
                continue
            }
            let shared = others.filter { SessionRelation.of(change.path, roots: $0) != nil }.count
            items.append(SessionDirectory(path: change.path, relation: relation, root: root, changes: change.changes,
                                          firstInterval: change.firstInterval, lastInterval: change.lastInterval, alsoActiveSessions: shared))
        }
        items.sort { ($0.changes, $1.path) > ($1.changes, $0.path) }
        let cap = max(1, min(limit, maximumDirectories))
        return Directories(items: Array(items.prefix(cap)), total: items.count, overflow: overflow)
    }
}

/// TASK-672: agent sessions and their frozen directory impact in the steward
/// file (CONTRACT-602 `sessions` and `session_impacts`). Directories only;
/// never a file.
public actor SessionStore {
    public static let maximumSessions = 500
    private let connection: SQLiteConnection
    private static var tables: [String: BoundedTable] {
        Dictionary(uniqueKeysWithValues: (BoundedStoreContract.tables[.steward] ?? []).map { ($0.name, $0) })
    }

    public init(url: URL) throws {
        connection = try SQLiteConnection(url: url)
        try connection.prepareBoundedStore(.steward)
    }

    public func close() { connection.close() }

    /// The stored key: the ID when it fits the 64-byte column, else its hash.
    public static func key(_ sessionID: String) -> String {
        guard sessionID.utf8.count > 64 else { return sessionID }
        return "sha256:" + String(SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined().prefix(57))
    }

    /// Roots as JSON in the 1 KiB `cwd` column, dropping roots that do not fit.
    static func encode(roots: [String]) -> (text: String, truncated: Bool) {
        var kept = roots
        while true {
            let object: [String: Any] = ["r": kept, "t": kept.count < roots.count]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
            if data.count <= BoundedStoreContract.pathBytes || kept.isEmpty { return (String(decoding: data, as: UTF8.self), kept.count < roots.count) }
            kept.removeLast()
        }
    }

    static func decode(roots text: String) -> (roots: [String], truncated: Bool) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return ([], true) }
        return ((object["r"] as? [String]) ?? [], (object["t"] as? Bool) ?? false)
    }

    /// Records or refreshes a session; one row per session ID and start.
    public func record(sessionID: String, client: String, roots: [String], startedAt: Date, endsAt: Date) throws {
        guard let table = Self.tables["sessions"] else { return }
        let key = Self.key(sessionID)
        try connection.withStatement("DELETE FROM sessions WHERE session_id = ? AND started_at = ?") { statement in
            try connection.bind(key, at: 1, in: statement)
            try connection.bind(startedAt.timeIntervalSince1970, at: 2, in: statement)
            try connection.stepDone(statement)
        }
        let written = try connection.insertBounded(table, rows: [[
            "session_id": .text(key), "cwd": .text(Self.encode(roots: roots).text), "client": .text(String(client.prefix(64))),
            "started_at": .real(startedAt.timeIntervalSince1970), "ended_at": .real(endsAt.timeIntervalSince1970),
        ]])
        guard written.refused.isEmpty else { throw ReviewIndexError.refused(table: "sessions", reasons: written.refused) }
        try pruneOrphanImpacts()
    }

    /// Sessions recorded under this ID, oldest first.
    public func sessions(sessionID: String) throws -> [PersistedSession] {
        try rows("SELECT session_id, client, cwd, started_at, ended_at FROM sessions WHERE session_id = ? ORDER BY started_at ASC") { statement in
            try connection.bind(Self.key(sessionID), at: 1, in: statement)
        }
    }

    /// Sessions whose window overlaps [from, through], at most the cap.
    public func sessions(overlapping from: Date, through: Date) throws -> [PersistedSession] {
        try rows("SELECT session_id, client, cwd, started_at, ended_at FROM sessions WHERE started_at <= ? AND ended_at >= ? ORDER BY started_at DESC LIMIT ?") { statement in
            try connection.bind(through.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(from.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(Self.maximumSessions), at: 3, in: statement)
        }
    }

    public func count() throws -> Int {
        Int(try connection.withStatement("SELECT COUNT(*) FROM sessions") { statement -> Int64 in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw connection.lastError() }
            return sqlite3_column_int64(statement, 0)
        })
    }

    /// Keeps a session's directories so its impact outlives the journal's
    /// retention. Replaces any earlier freeze of the same session.
    public func freeze(sessionID: String, startedAt: Date, directories: [SessionDirectory]) throws {
        guard let table = Self.tables["session_impacts"] else { return }
        let key = Self.key(sessionID)
        try connection.withStatement("DELETE FROM session_impacts WHERE session_id = ? AND session_started_at = ?") { statement in
            try connection.bind(key, at: 1, in: statement)
            try connection.bind(startedAt.timeIntervalSince1970, at: 2, in: statement)
            try connection.stepDone(statement)
        }
        let rows: [[String: BoundedValue]] = directories.prefix(SessionImpact.maximumDirectories)
            .filter { $0.path.utf8.count <= BoundedStoreContract.pathBytes }
            .map { [
                "session_id": .text(key), "session_started_at": .real(startedAt.timeIntervalSince1970),
                "path_key": .text(ReviewIndex.key($0.path)), "path": .text($0.path), "changes": .integer($0.changes),
            ] }
        guard !rows.isEmpty else { return }
        let written = try connection.insertBounded(table, rows: rows)
        guard written.refused.isEmpty else { throw ReviewIndexError.refused(table: "session_impacts", reasons: written.refused) }
    }

    /// A frozen impact as (path, changes), most changes first; nil when none is kept.
    public func frozen(sessionID: String, startedAt: Date) throws -> [(path: String, changes: Int64)]? {
        let values = try connection.withStatement("""
            SELECT path, changes FROM session_impacts WHERE session_id = ? AND session_started_at = ? ORDER BY changes DESC, path ASC
            """) { statement -> [(path: String, changes: Int64)] in
            try connection.bind(Self.key(sessionID), at: 1, in: statement)
            try connection.bind(startedAt.timeIntervalSince1970, at: 2, in: statement)
            var values: [(path: String, changes: Int64)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append((String(cString: sqlite3_column_text(statement, 0)), sqlite3_column_int64(statement, 1)))
            }
            return values
        }
        return values.isEmpty ? nil : values
    }

    /// The bounded store evicts each table on its own; a session that left
    /// `sessions` takes its impacts with it here.
    private func pruneOrphanImpacts() throws {
        try connection.execute("""
            DELETE FROM session_impacts WHERE NOT EXISTS (
                SELECT 1 FROM sessions WHERE sessions.session_id = session_impacts.session_id
                AND sessions.started_at = session_impacts.session_started_at)
            """)
    }

    private func rows(_ sql: String, bind: (OpaquePointer) throws -> Void) throws -> [PersistedSession] {
        try connection.withStatement(sql) { statement in
            try bind(statement)
            var values: [PersistedSession] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
                let roots = Self.decode(roots: text(2))
                values.append(PersistedSession(key: text(0), client: text(1), roots: roots.roots, rootsTruncated: roots.truncated,
                                               startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                                               endsAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))))
            }
            return values
        }
    }
}
