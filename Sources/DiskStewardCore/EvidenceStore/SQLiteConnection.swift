import CSQLite
import Foundation

final class SQLiteConnection {
    private var handle: OpaquePointer?
    let url: URL

    init(url: URL) throws {
        self.url = url
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
    }

    deinit { close() }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    func execute(_ sql: String) throws {
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
        let database = try requireHandle()
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw lastError(code) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
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
        let stepCode = sqlite3_backup_step(backup, -1)
        let finishCode = sqlite3_backup_finish(backup)
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
