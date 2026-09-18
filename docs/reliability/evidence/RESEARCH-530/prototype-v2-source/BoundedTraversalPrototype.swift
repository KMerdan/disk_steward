import CSQLite
import Darwin
import Foundation
@testable import DiskStewardCore

/// RESEARCH ONLY. A normalized work-queue / current-generation experiment.
/// It deliberately does not implement the product's lifecycle history, multi-root
/// attribution, public DTOs, migration or retention. Its space numbers are a
/// lower bound for that product, not a claim that a whole 1M-file store fits.
final class BoundedTraversalPrototype {
    enum Mode: String { case stream, spool }
    enum Failure: Error { case changed, unavailable, incomplete, capacity, corrupt, injected, requiresReopen }
    struct Directory {
        var id: Int64
        var path: String
        var depth: Int
        var phase: Int
        var signature: String
        var epoch: Int64
        var offset: Int64
    }
    struct Counters {
        var enumerated = 0
        var processed = 0
        var enumerationPasses = 0
        var peakNames = 0
        var spoolRowsWritten = 0
        var restartedDirectories = 0
        var peakPendingRows: Int64 = 0
        var peakPendingPayloadBytes: Int64 = 0
        var maximumQueueVMSteps: Int32 = 0
    }

    let database: URL
    let mode: Mode
    let connection: SQLiteConnection
    private(set) var generation: Int64 = 0
    private(set) var counters = Counters()
    private var stream: UnsafeMutablePointer<DIR>?
    private var streamDirectory: Int64?
    private var requiresReopen = false
    private var generationPermit: ScanPublicationPermit?

    init(database: URL, mode: Mode) throws {
        self.database = database
        self.mode = mode
        connection = try SQLiteConnection(url: database)
        try connection.execute("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            PRAGMA cache_size=-4096;
            PRAGMA temp_store=FILE;
            CREATE TABLE IF NOT EXISTS generations(id INTEGER PRIMARY KEY, mode TEXT NOT NULL, status TEXT NOT NULL, fenced INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS visible(singleton INTEGER PRIMARY KEY CHECK(singleton=1), generation INTEGER);
            INSERT OR IGNORE INTO visible VALUES(1,NULL);
            CREATE TABLE IF NOT EXISTS directories(
              id INTEGER PRIMARY KEY, generation INTEGER NOT NULL, parent INTEGER,
              owner_epoch INTEGER, path TEXT NOT NULL, depth INTEGER NOT NULL,
              phase INTEGER NOT NULL DEFAULT 0, signature TEXT NOT NULL DEFAULT '',
              epoch INTEGER NOT NULL DEFAULT 1, offset INTEGER NOT NULL DEFAULT 0,
              UNIQUE(generation,path));
            CREATE INDEX IF NOT EXISTS directories_queue ON directories(generation,phase,id);
            CREATE INDEX IF NOT EXISTS directories_open ON directories(generation,id) WHERE phase<3;
            CREATE INDEX IF NOT EXISTS directories_unvalidated ON directories(generation,id) WHERE phase<4;
            CREATE UNIQUE INDEX IF NOT EXISTS directories_root ON directories(generation) WHERE parent IS NULL;
            CREATE TABLE IF NOT EXISTS names(
              directory INTEGER NOT NULL, epoch INTEGER NOT NULL, ordinal INTEGER NOT NULL,
              name TEXT NOT NULL, PRIMARY KEY(directory,epoch,ordinal)) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS entries(
              generation INTEGER NOT NULL, directory INTEGER NOT NULL, epoch INTEGER NOT NULL,
              name TEXT NOT NULL, device INTEGER NOT NULL, inode INTEGER NOT NULL,
              logical INTEGER NOT NULL, allocated INTEGER NOT NULL, modified REAL NOT NULL,
              sampled REAL NOT NULL, links INTEGER NOT NULL,
              PRIMARY KEY(generation,directory,epoch,name)) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS entries_identity ON entries(generation,device,inode);
            """)
        generation = try connection.scalarInt("SELECT COALESCE(MAX(id),0) FROM generations WHERE status='preparing'")
        if generation != 0 {
            guard try connection.scalarText("SELECT mode FROM generations WHERE id=\(generation)") == mode.rawValue else {
                throw Failure.corrupt
            }
            // A process-local permit cannot be reconstructed after restart. This
            // experiment fails closed; dirty-root reconciliation is a separate
            // production requirement, not silently replaced with a new permit.
            if try connection.scalarInt("SELECT fenced FROM generations WHERE id=\(generation)") != 0 {
                requiresReopen = true
                return
            }
            // Process-local DIR cookies are never persisted or trusted after reopen.
            // At most one directory is actively enumerating. Logical epochs hide
            // old staged rows without an unbounded delete; physical bytes still count.
            let active = try readDirectory(predicate: "d.phase=1")
            if let active {
                guard DirectoryMetadataScanner.directorySignature(atPath: active.path) == active.signature else {
                    throw Failure.changed
                }
                try connection.execute("UPDATE directories SET epoch=epoch+1, phase=0, offset=0, signature='' WHERE id=\(active.id)")
                counters.restartedDirectories += 1
            }
            // A previously validated directory must be revalidated after process loss.
            try connection.execute("UPDATE directories SET phase=3 WHERE generation=\(generation) AND phase=4")
        }
    }

    deinit { close() }

    func close() {
        closeStream()
        connection.close()
    }

    func begin(root: URL, permit: ScanPublicationPermit? = nil) throws {
        guard !requiresReopen else { throw Failure.requiresReopen }
        guard generation == 0 else { return }
        // This experiment only permits one published + one preparing generation.
        // It cannot accidentally become an unbounded history benchmark.
        guard try connection.scalarInt("SELECT COUNT(*) FROM generations") < 2 else { throw Failure.capacity }
        let created: Int64 = try connection.transaction(publicationPermit: permit) {
            try connection.withStatement("INSERT INTO generations(mode,status,fenced) VALUES(?,'preparing',?)") { statement in
                try connection.bind(mode.rawValue, at: 1, in: statement)
                try connection.bind(Int64(permit == nil ? 0 : 1), at: 2, in: statement)
                try connection.stepDone(statement)
            }
            let created = try connection.scalarInt("SELECT last_insert_rowid()")
            try connection.withStatement("INSERT INTO directories(generation,path,depth) VALUES(?,?,0)") { statement in
                try connection.bind(created, at: 1, in: statement)
                try connection.bind(root.path, at: 2, in: statement)
                try connection.stepDone(statement)
            }
            return created
        }
        generation = created
        generationPermit = permit
    }

    /// One bounded batch, or at most `limit` completed empty directories. No
    /// file-count-sized Swift collection and no full frontier serialization.
    /// Returns true only after bounded revalidation of all reachable directory passes.
    func step(limit: Int = 512, afterReading: () throws -> Void = {}) throws -> Bool {
        precondition((1...512).contains(limit))
        guard !requiresReopen else { throw Failure.requiresReopen }
        do { return try stepBatch(limit: limit, afterReading: afterReading) }
        catch {
            // SQL rollback cannot roll back readdir(). Never retry with a native
            // cursor ahead of the durable offset, including on cancellation.
            closeStream()
            requiresReopen = true
            throw error
        }
    }

    private func stepBatch(limit: Int, afterReading: () throws -> Void) throws -> Bool {
        guard generation != 0 else { throw Failure.incomplete }
        try generationPermit?.validate()
        try Task.checkCancellation()
        var remaining = limit
        while remaining > 0, var directory = try readDirectory(predicate: "d.phase<3") {
            try checkAdmission()
            if directory.phase == 0 {
                guard let signature = DirectoryMetadataScanner.directorySignature(atPath: directory.path) else { throw Failure.unavailable }
                directory.signature = signature
                directory.phase = 1
                try connection.withStatement("UPDATE directories SET signature=?,phase=1 WHERE id=?") { statement in
                    try connection.bind(signature, at: 1, in: statement)
                    try connection.bind(directory.id, at: 2, in: statement)
                    try connection.stepDone(statement)
                }
            }
            guard DirectoryMetadataScanner.directorySignature(atPath: directory.path) == directory.signature else { throw Failure.changed }
            if directory.phase == 1 {
                if streamDirectory != directory.id {
                    closeStream()
                    guard let opened = opendir(directory.path) else { throw Failure.unavailable }
                    stream = opened
                    streamDirectory = directory.id
                    counters.enumerationPasses += 1
                }
                let (names, ended) = try readNames(limit: remaining)
                try afterReading()
                guard DirectoryMetadataScanner.directorySignature(atPath: directory.path) == directory.signature else { throw Failure.changed }
                try connection.transaction {
                    if mode == .spool {
                        try connection.withStatement("INSERT INTO names(directory,epoch,ordinal,name) VALUES(?,?,?,?)") { statement in
                            for (index, name) in names.enumerated() {
                                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                                try connection.bind(directory.id, at: 1, in: statement)
                                try connection.bind(directory.epoch, at: 2, in: statement)
                                try connection.bind(directory.offset + Int64(index) + 1, at: 3, in: statement)
                                try connection.bind(name, at: 4, in: statement)
                                try connection.stepDone(statement)
                            }
                        }
                        counters.spoolRowsWritten += names.count
                    } else {
                        try record(names: names, directory: directory)
                    }
                    guard DirectoryMetadataScanner.directorySignature(atPath: directory.path) == directory.signature else { throw Failure.changed }
                    let phase = ended ? (mode == .spool ? 2 : 3) : 1
                    let offset = ended && mode == .spool ? 0 : directory.offset + Int64(names.count)
                    try connection.execute("UPDATE directories SET phase=\(phase),offset=\(offset) WHERE id=\(directory.id)")
                }
                if ended { closeStream() }
                remaining -= max(1, names.count)
            } else {
                let names: [(Int64, String)] = try connection.withStatement(
                    "SELECT ordinal,name FROM names WHERE directory=? AND epoch=? AND ordinal>? ORDER BY ordinal LIMIT ?"
                ) { statement in
                    try connection.bind(directory.id, at: 1, in: statement)
                    try connection.bind(directory.epoch, at: 2, in: statement)
                    try connection.bind(directory.offset, at: 3, in: statement)
                    try connection.bind(Int64(remaining), at: 4, in: statement)
                    var names: [(Int64, String)] = []
                    while sqlite3_step(statement) == SQLITE_ROW {
                        names.append((sqlite3_column_int64(statement, 0), String(cString: sqlite3_column_text(statement, 1))))
                    }
                    return names
                }
                counters.peakNames = max(counters.peakNames, names.count)
                try connection.transaction {
                    try record(names: names.map(\.1), directory: directory)
                    guard DirectoryMetadataScanner.directorySignature(atPath: directory.path) == directory.signature else { throw Failure.changed }
                    try connection.execute("UPDATE directories SET phase=\(names.isEmpty ? 3 : 2),offset=\(names.last?.0 ?? directory.offset) WHERE id=\(directory.id)")
                }
                remaining -= max(1, names.count)
            }
        }
        if try readDirectory(predicate: "d.phase<3") != nil { return false }
        var validated = 0
        while validated < limit, let directory = try readDirectory(predicate: "d.phase=3") {
            guard DirectoryMetadataScanner.directorySignature(atPath: directory.path) == directory.signature else { throw Failure.changed }
            try connection.execute("UPDATE directories SET phase=4 WHERE id=\(directory.id)")
            validated += 1
        }
        return try readDirectory(predicate: "d.phase<4") == nil
    }

    func publish(afterPointerUpdate: () throws -> Void = {}) throws {
        guard !requiresReopen else { throw Failure.requiresReopen }
        guard generation != 0,
              try connection.scalarInt("SELECT COUNT(*) FROM generations WHERE id=\(generation) AND status='preparing'") == 1,
              try connection.scalarInt("SELECT COUNT(*) FROM directories WHERE generation=\(generation) AND parent IS NULL") == 1,
              try readDirectory(predicate: "d.phase<4") == nil else { throw Failure.incomplete }
        try checkAdmission()
        try connection.transaction(publicationPermit: generationPermit) {
            try connection.execute("UPDATE visible SET generation=\(generation) WHERE singleton=1")
            try afterPointerUpdate()
            try connection.execute("UPDATE generations SET status='published' WHERE id=\(generation)")
        }
        generation = 0
        generationPermit = nil
    }

    func visibleCount() throws -> Int64 {
        try connection.scalarInt("""
          SELECT COUNT(*) FROM entries e JOIN visible v ON e.generation=v.generation
          JOIN directories d ON e.directory=d.id AND e.epoch=d.epoch
          WHERE d.parent IS NULL OR EXISTS(SELECT 1 FROM directories p WHERE p.id=d.parent AND p.epoch=d.owner_epoch)
          """)
    }

    /// The names are traversal scratch, not current evidence. Charge bounded
    /// reclamation between generations, leaving both generations' metadata intact.
    @discardableResult
    func reclaimPublishedNames(limit: Int = 512) throws -> Int64 {
        precondition((1...512).contains(limit))
        try connection.transaction {
            try connection.execute("""
              DELETE FROM names WHERE (directory,epoch,ordinal) IN (
                SELECT n.directory,n.epoch,n.ordinal FROM names n
                JOIN directories d ON n.directory=d.id
                JOIN generations g ON d.generation=g.id
                WHERE g.status='published' LIMIT \(limit))
              """)
        }
        return try connection.scalarInt("SELECT changes()")
    }

    func sampleFrontier() throws {
        let values = try connection.withStatement("""
          SELECT COUNT(*),COALESCE(SUM(length(CAST(d.path AS BLOB))+length(CAST(d.signature AS BLOB))),0)
          FROM directories d LEFT JOIN directories p ON d.parent=p.id
          WHERE d.generation=\(generation) AND d.phase<3 AND (d.parent IS NULL OR d.owner_epoch=p.epoch)
          """) { statement -> (Int64, Int64) in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.corrupt }
            return (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
        }
        counters.peakPendingRows = max(counters.peakPendingRows, values.0)
        counters.peakPendingPayloadBytes = max(counters.peakPendingPayloadBytes, values.1)
    }

    func directoryQuery(predicate: String) -> String {
        // A range on (generation,phase,id) plus ORDER BY id otherwise makes
        // SQLite sort the entire queue, even with LIMIT 1. Pin the measured
        // matching partial index, rather than assuming planner selection.
        precondition(["d.phase<3", "d.phase<4", "d.phase=1", "d.phase=3"].contains(predicate))
        let index = predicate == "d.phase<3" ? "directories_open" : predicate == "d.phase<4" ? "directories_unvalidated" : "directories_queue"
        return """
          SELECT d.id,d.path,d.depth,d.phase,d.signature,d.epoch,d.offset FROM directories d INDEXED BY \(index)
          LEFT JOIN directories p ON d.parent=p.id
          WHERE d.generation=\(generation) AND (\(predicate)) AND (d.parent IS NULL OR d.owner_epoch=p.epoch)
          ORDER BY d.id LIMIT 1
          """
    }

    private func readDirectory(predicate: String) throws -> Directory? {
        try connection.withStatement(directoryQuery(predicate: predicate)) { statement in
            defer { counters.maximumQueueVMSteps = max(counters.maximumQueueVMSteps, sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0)) }
            let code = sqlite3_step(statement)
            guard code != SQLITE_DONE else { return nil }
            guard code == SQLITE_ROW else { throw Failure.corrupt }
            return Directory(id: sqlite3_column_int64(statement, 0), path: String(cString: sqlite3_column_text(statement, 1)),
                depth: Int(sqlite3_column_int64(statement, 2)), phase: Int(sqlite3_column_int64(statement, 3)),
                signature: String(cString: sqlite3_column_text(statement, 4)), epoch: sqlite3_column_int64(statement, 5),
                offset: sqlite3_column_int64(statement, 6))
        }
    }

    private func readNames(limit: Int) throws -> ([String], Bool) {
        guard let stream else { throw Failure.corrupt }
        var names: [String] = []
        while names.count < limit {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Failure.unavailable }
                counters.peakNames = max(counters.peakNames, names.count)
                return (names, true)
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
            counters.enumerated += 1
        }
        counters.peakNames = max(counters.peakNames, names.count)
        return (names, false)
    }

    private func record(names: [String], directory: Directory) throws {
        try connection.withStatement("""
          INSERT INTO entries(generation,directory,epoch,name,device,inode,logical,allocated,modified,sampled,links)
          VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(generation,directory,epoch,name) DO UPDATE SET
          device=excluded.device,inode=excluded.inode,logical=excluded.logical,allocated=excluded.allocated,
          modified=excluded.modified,sampled=excluded.sampled,links=excluded.links
          """) { statement in
            for name in names {
                try Task.checkCancellation()
                let path = directory.path + "/" + name
                var information = stat()
                guard lstat(path, &information) == 0 else { throw Failure.unavailable }
                counters.processed += 1
                if information.st_mode & S_IFMT == S_IFDIR {
                    guard directory.depth < 64 else { throw Failure.incomplete }
                    try connection.withStatement("""
                      INSERT INTO directories(generation,parent,owner_epoch,path,depth) VALUES(?,?,?,?,?)
                      ON CONFLICT(generation,path) DO UPDATE SET owner_epoch=excluded.owner_epoch
                      """) { child in
                        try connection.bind(generation, at: 1, in: child)
                        try connection.bind(directory.id, at: 2, in: child)
                        try connection.bind(directory.epoch, at: 3, in: child)
                        try connection.bind(path, at: 4, in: child)
                        try connection.bind(Int64(directory.depth + 1), at: 5, in: child)
                        try connection.stepDone(child)
                    }
                } else if information.st_mode & S_IFMT == S_IFREG {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    try connection.bind(generation, at: 1, in: statement)
                    try connection.bind(directory.id, at: 2, in: statement)
                    try connection.bind(directory.epoch, at: 3, in: statement)
                    try connection.bind(name, at: 4, in: statement)
                    try connection.bind(Int64(information.st_dev), at: 5, in: statement)
                    try connection.bind(Int64(bitPattern: UInt64(information.st_ino)), at: 6, in: statement)
                    try connection.bind(information.st_size, at: 7, in: statement)
                    try connection.bind(information.st_blocks * 512, at: 8, in: statement)
                    try connection.bind(Double(information.st_mtimespec.tv_sec) + Double(information.st_mtimespec.tv_nsec) / 1e9, at: 9, in: statement)
                    try connection.bind(Date().timeIntervalSince1970, at: 10, in: statement)
                    try connection.bind(Int64(information.st_nlink), at: 11, in: statement)
                    try connection.stepDone(statement)
                } // Symlinks and special entries are never followed or published as files.
            }
        }
    }

    private func checkAdmission() throws {
        var bytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            bytes += (try? FileManager.default.attributesOfItem(atPath: database.path + suffix)[.size] as? NSNumber)?.int64Value ?? 0
        }
        // Conservative per-batch reserve for this compact research schema. Real
        // history/migration reserve is intentionally NOT claimed to be covered.
        guard bytes + 4 * 1_024 * 1_024 < 512 * 1_024 * 1_024 else { throw Failure.capacity }
    }

    private func closeStream() {
        if let stream { closedir(stream) }
        stream = nil
        streamDirectory = nil
    }
}
