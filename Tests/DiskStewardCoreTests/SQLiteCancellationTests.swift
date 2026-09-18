import CSQLite
import Darwin
@testable import DiskStewardCore
import Foundation
import XCTest

final class SQLiteCancellationTests: XCTestCase {
    func testCancellationBetweenBackupPagesRollsBackAndReleasesDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = BackupCheckpoint()
        let fixture = try BackupFixture(url: root.appending(path: "source.sqlite"), checkpoint: gate)
        let interrupted = root.appending(path: "interrupted.sqlite")
        let cancelled = await Task {
            do { try await fixture.backup(to: interrupted); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(gate.didRun, "A successful page step must precede cancellation")
        let partial = try SQLiteConnection(url: interrupted)
        XCTAssertEqual(try partial.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE name='payload'"), 0,
                       "backup_finish must roll back an unfinished destination transaction")
        partial.close()
        let completed = root.appending(path: "complete.sqlite")
        try await fixture.backup(to: completed)
        let recovered = try SQLiteConnection(url: completed)
        XCTAssertEqual(try recovered.scalarInt("SELECT COUNT(*) FROM payload"), 512)
        recovered.close()
    }

    func testCancellationInterruptsLockWaitWithoutWaitingFiveSeconds() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "test.sqlite")
        let holder = try DatabaseFixture(url: url)
        let contender = try DatabaseFixture(url: url)
        try await holder.holdLock()
        let signal = SQLSignal()
        let task = Task { await contender.blockedInsert(signal: signal) }
        let startedBy = ProcessInfo.processInfo.systemUptime + 1
        while !signal.started, ProcessInfo.processInfo.systemUptime < startedBy { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(signal.started)
        try await Task.sleep(for: .milliseconds(30))
        let cancelledAt = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 1)
        try await holder.releaseLock()
        try await contender.insert()
        let count = try await contender.checkRecovery()
        XCTAssertEqual(count, 1)
    }

    func testSocketDeadlineInterruptsSQLiteInsideActorAndThenRecovers() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds-sql-cancel-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let signal = SQLSignal()
        let fixture = try SQLRequestFixture(url: root.appending(path: "test.sqlite"), signal: signal)
        let server = UnixSocketEvidenceServer(socketPath: root.appending(path: "s").path, handler: fixture, timeoutSeconds: 0.2)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: server.socketPath, timeoutSeconds: 1)
        let request = Task.detached { try? client.call(tool: "slow", arguments: [:], isCancelled: { false }) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !signal.cancelled, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(signal.started, "Cancellation must occur after SQLite has actually begun evaluating the query")
        XCTAssertTrue(signal.cancelled, "The socket watchdog must interrupt the real actor-confined SQLite operation")
        _ = await request.value
        let recovered = try await fixture.health()
        XCTAssertEqual(recovered, 42)
    }

    func testCancellationDuringRowsInterruptsAndDiscardsPartialResult() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try DatabaseFixture(url: root.appending(path: "test.sqlite"))
        let result = await Task { await fixture.cancelDuringRows(transaction: false) }.value
        XCTAssertTrue(result.cancelled, "An interrupted row loop must not return a successful partial result")
        XCTAssertLessThan(result.rows, 1_000, "Cancellation must stop SQLite execution, not merely discard its output")
        let recovered = try await fixture.checkRecovery()
        XCTAssertEqual(recovered, 0)
    }

    func testCancelledTransactionRollsBackAndConnectionRemainsUsable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try DatabaseFixture(url: root.appending(path: "test.sqlite"))
        let result = await Task { await fixture.cancelDuringRows(transaction: true) }.value
        XCTAssertTrue(result.cancelled)
        XCTAssertLessThan(result.rows, 1_000)
        let recovered = try await fixture.checkRecovery()
        XCTAssertEqual(recovered, 0, "The write before cancellation must roll back")
    }

    func testAlreadyCancelledWorkCannotStartAShortWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try DatabaseFixture(url: root.appending(path: "test.sqlite"))
        let refused = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await fixture.insert(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(refused)
        let recovered = try await fixture.checkRecovery()
        XCTAssertEqual(recovered, 0)
    }
}

private final class BackupCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var ran = false
    var didRun: Bool { lock.withLock { ran } }
    func step() {
        let cancel = lock.withLock { () -> Bool in
            guard !ran else { return false }
            ran = true
            return true
        }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

private actor BackupFixture {
    private let connection: SQLiteConnection
    init(url: URL, checkpoint: BackupCheckpoint) throws {
        connection = try SQLiteConnection(url: url, afterBackupStep: { checkpoint.step() })
        try connection.execute("CREATE TABLE payload(bytes BLOB)")
        try connection.execute("WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<512) INSERT INTO payload SELECT zeroblob(8192) FROM seq")
    }
    func backup(to url: URL) throws { try connection.backup(to: url) }
}

private final class SQLSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false
    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func start() { lock.withLock { didStart = true } }
    func cancel() { lock.withLock { didCancel = true } }
}

private actor SQLRequestFixture: DiskStewardIPCRequestHandling {
    private let connection: SQLiteConnection
    private let signal: SQLSignal
    init(url: URL, signal: SQLSignal) throws {
        self.signal = signal
        connection = try SQLiteConnection(url: url)
        try connection.withStatement("SELECT 1") { statement in
            let code = sqlite3_create_function_v2(sqlite3_db_handle(statement), "signal_started", 0, SQLITE_UTF8,
                Unmanaged.passUnretained(signal).toOpaque(), { context, _, _ in
                    guard let context, let pointer = sqlite3_user_data(context) else { return }
                    Unmanaged<SQLSignal>.fromOpaque(pointer).takeUnretainedValue().start()
                    sqlite3_result_int(context, 1)
                }, nil, nil, nil)
            guard code == SQLITE_OK else { throw CocoaError(.coderInvalidValue) }
        }
    }
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        do {
            let result = try connection.scalarInt("WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<50000000) SELECT SUM(CASE WHEN n=1 THEN signal_started() ELSE n END) FROM seq")
            return .integer(result)
        } catch is CancellationError { signal.cancel(); throw CancellationError() }
    }
    func health() throws -> Int64 { try connection.scalarInt("SELECT 42") }
}

private actor DatabaseFixture {
    let connection: SQLiteConnection
    private var rows = 0
    init(url: URL) throws {
        connection = try SQLiteConnection(url: url)
        try connection.execute("CREATE TABLE IF NOT EXISTS fixture(value INTEGER)")
        try connection.execute("PRAGMA busy_timeout=5000")
    }

    func insert() throws { try connection.execute("INSERT INTO fixture VALUES(1)") }
    func holdLock() throws { try connection.execute("BEGIN EXCLUSIVE") }
    func releaseLock() throws { try connection.execute("ROLLBACK") }
    func blockedInsert(signal: SQLSignal) -> Bool {
        signal.start()
        do { try insert(); return false }
        catch is CancellationError { return true }
        catch { return false }
    }

    func cancelDuringRows(transaction: Bool) -> (cancelled: Bool, rows: Int) {
        rows = 0
        do {
            if transaction {
                try connection.transaction { try insert(); try rowQuery() }
            } else { try rowQuery() }
            return (false, rows)
        } catch is CancellationError { return (true, rows) }
        catch { return (false, rows) }
    }

    private func rowQuery() throws {
        try connection.withStatement("WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<100000) SELECT n FROM seq") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                rows += 1
                // Cancellation occurs only after SQLite really yielded a row.
                if rows == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
    }

    func checkRecovery() throws -> Int64 {
        // A new transaction also proves that cancellation did not leave BEGIN open.
        try connection.transaction { try connection.scalarInt("SELECT COUNT(*) FROM fixture") }
    }
}
