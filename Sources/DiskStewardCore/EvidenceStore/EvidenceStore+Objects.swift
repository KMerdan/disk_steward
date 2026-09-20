import CSQLite
import Foundation

/// A classified directory as the store keeps it: one row, no per-file rows
/// inside it. Aggregates are absent until something measures them, which is
/// TASK-621's work, so `measuredAt` is optional and a size without it is not
/// publishable. See docs/reliability/evidence/CONTRACT-601/object-contract.md.
public struct StoredObject: Equatable, Sendable {
    public let classification: ClassifiedObject
    public let logicalBytes: Int64
    public let fileCount: Int64
    public let measuredAt: Date?
    public let dirty: Bool
    public let projectLastActivity: Date?
    public let rebuildCommand: String?
    public let observedAt: Date

    public var path: String { classification.path }
    /// A repository is measured and never offered for cleanup.
    public var isCleanupCandidate: Bool { classification.isCleanupCandidate }

    public init(classification: ClassifiedObject, logicalBytes: Int64 = 0, fileCount: Int64 = 0,
                measuredAt: Date? = nil, dirty: Bool = true, projectLastActivity: Date? = nil,
                rebuildCommand: String? = nil, observedAt: Date) {
        self.classification = classification
        self.logicalBytes = max(0, logicalBytes)
        self.fileCount = max(0, fileCount)
        self.measuredAt = measuredAt
        self.dirty = dirty
        self.projectLastActivity = projectLastActivity
        self.rebuildCommand = rebuildCommand
        self.observedAt = observedAt
    }
}

/// What a collapse did. `interrupted` reports an attempt that stopped at a
/// checkpoint: what it had already committed stands, and running it again
/// continues from there.
public struct ObjectCollapseReport: Equatable, Sendable {
    public let objectsWritten: Int
    public let perFileRowsRemoved: Int
    public let bindingsClosed: Int
    public let interrupted: Bool

    public init(objectsWritten: Int, perFileRowsRemoved: Int, bindingsClosed: Int, interrupted: Bool) {
        self.objectsWritten = objectsWritten
        self.perFileRowsRemoved = perFileRowsRemoved
        self.bindingsClosed = bindingsClosed
        self.interrupted = interrupted
    }
}

public extension EvidenceStore {
    /// Record classified objects. Existing rows for the same path are replaced,
    /// preserving aggregates that the caller did not supply.
    func recordObjects(_ objects: [StoredObject]) throws {
        guard !objects.isEmpty else { return }
        let connection = try requireConnection()
        try connection.transaction {
            for object in objects {
                try Self.upsertObject(object, connection: connection)
            }
        }
    }

    /// Every stored object, largest first.
    func currentObjects() throws -> [StoredObject] {
        let connection = try requireConnection()
        return try connection.withStatement("""
            SELECT path, kind, detection_rule, confidence, reason, owning_project_path, owning_project_marker,
                   logical_bytes, file_count, measured_at, dirty, project_last_activity, rebuild_command, observed_at
            FROM current_objects ORDER BY logical_bytes DESC, path
            """) { statement in
            var rows: [StoredObject] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let path = Self.columnString(statement, column: 0),
                      let kind = Self.columnString(statement, column: 1).flatMap(ClassifiedObjectKind.init(rawValue:)),
                      let rule = Self.columnString(statement, column: 2).flatMap(ObjectDetectionRule.init(rawValue:)),
                      let confidence = Self.columnString(statement, column: 3).flatMap(ObjectDetectionConfidence.init(rawValue:)),
                      let reason = Self.columnString(statement, column: 4)
                else { continue }
                let measured = sqlite3_column_type(statement, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
                let activity = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
                rows.append(StoredObject(
                    classification: ClassifiedObject(
                        path: path, kind: kind, rule: rule, confidence: confidence, reason: reason,
                        owningProjectPath: Self.columnString(statement, column: 5),
                        owningProjectMarker: Self.columnString(statement, column: 6)),
                    logicalBytes: sqlite3_column_int64(statement, 7),
                    fileCount: sqlite3_column_int64(statement, 8),
                    measuredAt: measured,
                    dirty: sqlite3_column_int64(statement, 10) != 0,
                    projectLastActivity: activity,
                    rebuildCommand: Self.columnString(statement, column: 12),
                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))))
            }
            return rows
        }
    }

    /// Objects a person may be offered for cleanup. A repository never is.
    func cleanupCandidateObjects() throws -> [StoredObject] {
        try currentObjects().filter(\.isCleanupCandidate)
    }

    /// Collapse the per-file rows that fall inside `objects` into those object
    /// rows. Unrelated evidence, history and exports are untouched: only
    /// `current_file_state` rows under an object path and the open path
    /// bindings that name them are affected.
    ///
    /// `checkpoint` runs before each committed step and may throw to stop the
    /// collapse. Whatever was committed before that stands, and a later call
    /// continues from there, so an interrupted collapse never loses a row or
    /// leaves a half-written object.
    @discardableResult
    func collapsePerFileRows(
        into objects: [StoredObject],
        checkpoint: (String) throws -> Void = { _ in }
    ) throws -> ObjectCollapseReport {
        let connection = try requireConnection()
        var written = 0
        var removed = 0
        var bindings = 0
        var interrupted = false
        for object in objects {
            let prefix = object.path.hasSuffix("/") ? object.path : object.path + "/"
            do {
                try checkpoint("before-object-\(object.path)")
                try connection.transaction {
                    try Self.upsertObject(object, connection: connection)
                    bindings += try Self.closeBindings(under: prefix, at: object.observedAt, connection: connection)
                    removed += try Self.deleteCurrentFileState(under: prefix, connection: connection)
                }
                written += 1
            } catch is CollapseInterruption {
                interrupted = true
                break
            }
        }
        return ObjectCollapseReport(objectsWritten: written, perFileRowsRemoved: removed,
                                    bindingsClosed: bindings, interrupted: interrupted)
    }

    /// The distinct directories that current per-file rows live in. A migration
    /// asks the classifier about these, never about every file.
    func currentFileStateDirectories() throws -> [String] {
        let connection = try requireConnection()
        return try connection.withStatement(
            "SELECT DISTINCT rtrim(path, replace(path, '/', '')) FROM current_file_state") { statement in
            var paths: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = Self.columnString(statement, column: 0), value.count > 1 {
                    paths.insert(String(value.dropLast()))
                }
            }
            return paths.sorted()
        }
    }

    /// Thrown by a caller's checkpoint to stop a collapse between objects.
    struct CollapseInterruption: Error, Equatable {
        public init() {}
    }

    // MARK: - private

    internal static func upsertObject(_ object: StoredObject, connection: SQLiteConnection) throws {
        try connection.withStatement("""
            INSERT INTO current_objects (path, kind, detection_rule, confidence, reason, owning_project_path,
                                         owning_project_marker, logical_bytes, file_count, measured_at, dirty,
                                         project_last_activity, rebuild_command, review_required, observed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
            ON CONFLICT(path) DO UPDATE SET
                kind = excluded.kind, detection_rule = excluded.detection_rule, confidence = excluded.confidence,
                reason = excluded.reason, owning_project_path = excluded.owning_project_path,
                owning_project_marker = excluded.owning_project_marker,
                logical_bytes = MAX(excluded.logical_bytes, current_objects.logical_bytes),
                file_count = MAX(excluded.file_count, current_objects.file_count),
                measured_at = COALESCE(excluded.measured_at, current_objects.measured_at),
                dirty = excluded.dirty,
                project_last_activity = COALESCE(excluded.project_last_activity, current_objects.project_last_activity),
                rebuild_command = COALESCE(excluded.rebuild_command, current_objects.rebuild_command),
                observed_at = excluded.observed_at
            """) { statement in
            let classification = object.classification
            try connection.bind(classification.path, at: 1, in: statement)
            try connection.bind(classification.kind.rawValue, at: 2, in: statement)
            try connection.bind(classification.rule.rawValue, at: 3, in: statement)
            try connection.bind(classification.confidence.rawValue, at: 4, in: statement)
            try connection.bind(classification.reason, at: 5, in: statement)
            try connection.bind(classification.owningProjectPath, at: 6, in: statement)
            try connection.bind(classification.owningProjectMarker, at: 7, in: statement)
            try connection.bind(object.logicalBytes, at: 8, in: statement)
            try connection.bind(object.fileCount, at: 9, in: statement)
            if let measured = object.measuredAt {
                try connection.bind(measured.timeIntervalSince1970, at: 10, in: statement)
            } else {
                sqlite3_bind_null(statement, 10)
            }
            try connection.bind(Int64(object.dirty ? 1 : 0), at: 11, in: statement)
            if let activity = object.projectLastActivity {
                try connection.bind(activity.timeIntervalSince1970, at: 12, in: statement)
            } else {
                sqlite3_bind_null(statement, 12)
            }
            try connection.bind(object.rebuildCommand, at: 13, in: statement)
            try connection.bind(object.observedAt.timeIntervalSince1970, at: 14, in: statement)
            try connection.stepDone(statement)
        }
    }

    private static func deleteCurrentFileState(under prefix: String, connection: SQLiteConnection) throws -> Int {
        let before = try connection.scalarInt("SELECT COUNT(*) FROM current_file_state")
        try connection.withStatement("DELETE FROM current_file_state WHERE path >= ? AND path < ?") { statement in
            try connection.bind(prefix, at: 1, in: statement)
            try connection.bind(prefix + "\u{10FFFF}", at: 2, in: statement)
            try connection.stepDone(statement)
        }
        return Int(before - (try connection.scalarInt("SELECT COUNT(*) FROM current_file_state")))
    }

    /// An open binding for a path inside an object is closed, not deleted: the
    /// history of what was there stays readable.
    private static func closeBindings(under prefix: String, at date: Date, connection: SQLiteConnection) throws -> Int {
        let open = try connection.withStatement(
            "SELECT COUNT(*) FROM path_bindings WHERE valid_through IS NULL AND path >= ? AND path < ?") { statement in
            try connection.bind(prefix, at: 1, in: statement)
            try connection.bind(prefix + "\u{10FFFF}", at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return Int64(0) }
            return sqlite3_column_int64(statement, 0)
        }
        guard open > 0 else { return 0 }
        try connection.withStatement(
            "UPDATE path_bindings SET valid_through = ? WHERE valid_through IS NULL AND path >= ? AND path < ?") { statement in
            try connection.bind(date.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(prefix, at: 2, in: statement)
            try connection.bind(prefix + "\u{10FFFF}", at: 3, in: statement)
            try connection.stepDone(statement)
        }
        return Int(open)
    }
}
