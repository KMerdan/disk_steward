import CSQLite
import Foundation

final class SQLiteConnection {
    private var handle: OpaquePointer?
    let url: URL
    private let afterBackupStep: @Sendable () -> Void

    init(url: URL, afterBackupStep: @escaping @Sendable () -> Void = {}) throws {
        self.url = url
        self.afterBackupStep = afterBackupStep
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(url.path, &opened, flags, nil)
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let opened { sqlite3_close(opened) }
            throw EvidenceStoreError.sqlite(code: code, message: message)
        }
        handle = opened
        installCancellationHandler(on: opened)
    }

    deinit { close() }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    func execute(_ sql: String) throws {
        try Task.checkCancellation()
        let database = try requireHandle()
        installBusyHandler(on: database)
        do { try executeUnchecked(sql) }
        catch { try Task.checkCancellation(); throw error }
    }

    private func executeUnchecked(_ sql: String) throws {
        let database = try requireHandle()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw EvidenceStoreError.sqlite(code: code, message: message)
        }
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        try Task.checkCancellation()
        let database = try requireHandle()
        installBusyHandler(on: database)
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { try Task.checkCancellation(); throw lastError(code) }
        defer { sqlite3_finalize(statement) }
        do {
            let result = try body(statement)
            // Existing row readers stop when sqlite3_step no longer yields ROW.
            // SQLITE_INTERRUPT must never turn that prefix into a successful result.
            try Task.checkCancellation()
            if sqlite3_errcode(database) == SQLITE_INTERRUPT { throw lastError(SQLITE_INTERRUPT) }
            return result
        } catch { try Task.checkCancellation(); throw error }
    }

    func transaction<T>(readOnly: Bool = false, publicationPermit: ScanPublicationPermit? = nil, _ body: () throws -> T) throws -> T {
        // A summary needs one coherent snapshot without taking the writer's
        // reserved lock. Its body must not promote the transaction to a write.
        try execute(readOnly ? "BEGIN" : "BEGIN IMMEDIATE")
        do {
            let value = try body()
            if let publicationPermit {
                try publicationPermit.commit {
                    try Task.checkCancellation()
                    let database = try requireHandle()
                    // Receipt admission shares this very short commit fence.
                    // A competing reader must fail this attempt, not hold the
                    // callback behind the usual five-second SQLite busy retry.
                    sqlite3_busy_timeout(database, 0)
                    defer { installBusyHandler(on: database) }
                    do { try executeUnchecked("COMMIT") }
                    catch { try Task.checkCancellation(); throw error }
                }
            } else {
                try execute("COMMIT")
            }
            return value
        } catch {
            // Cleanup must run even in a cancelled task. This connection is
            // actor-confined; no unrelated query can run while the hook is off.
            if let handle {
                sqlite3_progress_handler(handle, 0, nil, nil)
                sqlite3_busy_timeout(handle, 100)
                defer {
                    if let recovered = self.handle {
                        installCancellationHandler(on: recovered)
                        installBusyHandler(on: recovered)
                    }
                }
                if sqlite3_get_autocommit(handle) == 0 {
                    do { try executeUnchecked("ROLLBACK") }
                    catch { close() } // Never reuse a connection with an unrolled-back transaction.
                }
            }
            throw error
        }
    }

    private func installCancellationHandler(on database: OpaquePointer) {
        // SQLite calls this synchronously in the current Swift task. It must
        // not mutate the connection or interrupt a different actor's query.
        sqlite3_progress_handler(database, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
    }

    private func installBusyHandler(on database: OpaquePointer) {
        // Match the store's five-second lock budget, but check cancellation
        // between short waits instead of sleeping inside SQLite's busy_timeout.
        sqlite3_busy_handler(database, { _, attempt in
            guard !Task.isCancelled, attempt < 500 else { return 0 }
            Thread.sleep(forTimeInterval: 0.01)
            return Task.isCancelled ? 0 : 1
        }, nil)
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func scalarText(_ sql: String) throws -> String {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
            guard let text = sqlite3_column_text(statement, 0) else { return "" }
            return String(cString: text)
        }
    }

    func backup(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw EvidenceStoreError.backupDestinationExists
        }
        try execute("PRAGMA wal_checkpoint(FULL)")
        var destinationHandle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            destination.path,
            &destinationHandle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let destinationHandle else {
            if let destinationHandle { sqlite3_close(destinationHandle) }
            throw EvidenceStoreError.sqlite(code: openCode, message: "Unable to open backup destination")
        }
        defer { sqlite3_close_v2(destinationHandle) }
        let source = try requireHandle()
        guard let backup = sqlite3_backup_init(destinationHandle, "main", source, "main") else {
            throw EvidenceStoreError.sqlite(
                code: sqlite3_errcode(destinationHandle),
                message: String(cString: sqlite3_errmsg(destinationHandle))
            )
        }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        let retryDeadline = ProcessInfo.processInfo.systemUptime + 5
        var stepCode: Int32
        repeat {
            try Task.checkCancellation()
            stepCode = sqlite3_backup_step(backup, 128)
            if stepCode == SQLITE_OK { afterBackupStep() }
            if stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED {
                guard ProcessInfo.processInfo.systemUptime < retryDeadline else { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
        } while stepCode == SQLITE_OK || stepCode == SQLITE_BUSY || stepCode == SQLITE_LOCKED
        let finishCode = sqlite3_backup_finish(backup)
        finished = true
        try Task.checkCancellation()
        guard stepCode == SQLITE_DONE, finishCode == SQLITE_OK else {
            throw EvidenceStoreError.sqlite(
                code: stepCode == SQLITE_DONE ? finishCode : stepCode,
                message: String(cString: sqlite3_errmsg(destinationHandle))
            )
        }
    }

    func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code = sqlite3_bind_text(statement, index, value, -1, transient)
        guard code == SQLITE_OK else { throw lastError(code) }
    }

    func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer) throws {
        let code = sqlite3_bind_int64(statement, index, value)
        guard code == SQLITE_OK else { throw lastError(code) }
    }

    func bind(_ value: Double, at index: Int32, in statement: OpaquePointer) throws {
        let code = sqlite3_bind_double(statement, index, value)
        guard code == SQLITE_OK else { throw lastError(code) }
    }

    func bind(_ value: Data, at index: Int32, in statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let code = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
        guard code == SQLITE_OK else { throw lastError(code) }
    }

    func bindNull(at index: Int32, in statement: OpaquePointer) throws {
        let code = sqlite3_bind_null(statement, index)
        guard code == SQLITE_OK else { throw lastError(code) }
    }

    func bind(_ value: String?, at index: Int32, in statement: OpaquePointer) throws {
        if let value {
            try bind(value, at: index, in: statement)
        } else {
            try bindNull(at: index, in: statement)
        }
    }

    func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) throws {
        if let value {
            try bind(value, at: index, in: statement)
        } else {
            try bindNull(at: index, in: statement)
        }
    }

    func stepDone(_ statement: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw lastError(code) }
    }

    func lastError(_ code: Int32? = nil) -> EvidenceStoreError {
        guard let handle else { return .closed }
        return .sqlite(
            code: code ?? sqlite3_errcode(handle),
            message: String(cString: sqlite3_errmsg(handle))
        )
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw EvidenceStoreError.closed }
        return handle
    }
}
