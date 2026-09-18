import Foundation
import CSQLite
import XCTest
@testable import DiskStewardCore

final class ScanPublicationFenceTests: XCTestCase, @unchecked Sendable {
    func testCancellationInsideGuardedCommitPreservesErrorAndConnectionRecovery() async throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let database = try PublicationCancellationFixture(url: fixture.database)
        let cancelled = await Task { await database.cancelAtCommit() }.value
        XCTAssertTrue(cancelled, "An unsuccessful COMMIT in a cancelled task must still surface CancellationError")
        let count = try await database.checkRecovery()
        XCTAssertEqual(count, 1, "Cancelled write rolls back; a later uncancelled transaction can use the connection")
    }

    func testGuardedCommitDoesNotWaitForAConflictingSQLiteReader() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let writer = try SQLiteConnection(url: fixture.database)
        defer { writer.close() }
        try writer.execute("CREATE TABLE fixture (value INTEGER)")
        let reader = try SQLiteConnection(url: fixture.database)
        defer { reader.close() }
        try reader.execute("BEGIN")
        _ = try reader.scalarInt("SELECT COUNT(*) FROM fixture")
        let fence = ScanPublicationFence()
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try writer.transaction(publicationPermit: fence.permit()) {
            try writer.execute("INSERT INTO fixture VALUES (1)")
        })
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1,
                          "A commit holding the receipt fence must not use SQLite's five-second retry budget")
        try reader.execute("ROLLBACK")
        XCTAssertEqual(try writer.scalarInt("SELECT COUNT(*) FROM fixture"), 0)
        try writer.transaction { try writer.execute("INSERT INTO fixture VALUES (2)") }
        XCTAssertEqual(try writer.scalarInt("SELECT COUNT(*) FROM fixture"), 1)
    }

    func testSupersededCommitRollsBackAndLeavesConnectionReusable() throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        let writer = try SQLiteConnection(url: fixture.database)
        defer { writer.close() }
        try writer.execute("CREATE TABLE fixture (value INTEGER)")
        let fence = ScanPublicationFence()
        let permit = try fence.permit()
        XCTAssertThrowsError(try writer.transaction(publicationPermit: permit) {
            try writer.execute("INSERT INTO fixture VALUES (1)")
            fence.invalidate()
        }) { XCTAssertEqual($0 as? ScanPublicationError, .superseded) }
        XCTAssertEqual(try writer.scalarInt("SELECT COUNT(*) FROM fixture"), 0)
        try writer.transaction { try writer.execute("INSERT INTO fixture VALUES (2)") }
        XCTAssertEqual(try writer.scalarInt("SELECT COUNT(*) FROM fixture"), 1)
    }

    func testPendingAndNewerReceiptsCannotBeAcknowledgedByAnOlderCompletion() throws {
        let fence = ScanPublicationFence()
        let old = try fence.permit()
        let first = fence.invalidate()
        XCTAssertThrowsError(try fence.permit()) { XCTAssertEqual($0 as? ScanPublicationError, .pendingChanges) }
        let second = fence.invalidate()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(fence.acknowledge(first))
        XCTAssertThrowsError(try fence.permit())
        XCTAssertTrue(fence.acknowledge(second))
        XCTAssertThrowsError(try old.validate()) { XCTAssertEqual($0 as? ScanPublicationError, .superseded) }
        try fence.permit().validate()
    }

    func testReceiptDuringPreparedPublicationRollsBackCurrentStateAndRecovers() async throws {
        for checkpoint in ["after-observation", "after-present-objects", "before-finalize"] {
            let fixture = try PublicationFixture()
            defer { fixture.remove() }
            for name in ["A", "B", "C"] { try fixture.write(name, bytes: 1) }
            let arm = PublicationReceiptArm()
            let fence = ScanPublicationFence()
            let store = try EvidenceStore(url: fixture.database, reconciliationCheckpoint: { point in
                guard point == checkpoint, arm.takeArm() else { return }
                // The metadata/pass has already been read. This is a normal
                // change signal, not a lost-events flag or task cancellation.
                try FileManager.default.removeItem(at: fixture.root.appending(path: "A"))
                let accepted = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    arm.setReceipt(fence.invalidate())
                    accepted.signal()
                }
                // A regression that holds the fence for the entire transaction
                // fails within a bound rather than deadlocking this test.
                guard accepted.wait(timeout: .now() + 2) == .success else {
                    throw PublicationFixtureError.receiptBlockedByPreparation
                }
            })
            let baseline = try await fixture.complete(store: store, at: 100)
            let generation = try await store.beginOrResumeScanGeneration(scope: fixture.scope, at: fixture.date(200))
            let slice = DirectoryMetadataScanner().scanSlice(policy: fixture.policy, generation: generation, at: fixture.date(201))
            XCTAssertEqual(slice.generation.status, .completed)
            let permit = try fence.permit()
            arm.arm()
            do {
                _ = try await store.recordScanSlice(snapshot: fixture.snapshot(), slice: slice, scope: fixture.scope, trigger: .scheduled, publicationPermit: permit)
                XCTFail("A receipt during \(checkpoint) must reject publication")
            } catch let error as ScanPublicationError {
                XCTAssertEqual(error, .superseded)
            }
            let retained = try await store.currentFiles(includeNonActionable: true)
            XCTAssertEqual(retained, baseline.currentFiles, checkpoint)
            let diagnostics = try await store.diagnostics()
            XCTAssertEqual(diagnostics.observationCount, 1, checkpoint)
            XCTAssertEqual(diagnostics.integrity, "ok")
            let receipt = try XCTUnwrap(arm.receipt)
            XCTAssertThrowsError(try fence.permit())
            // Persistence precedes acknowledgement. Equal wall times do not
            // matter; both the memory permit and durable token use identities.
            try await store.recordReconciliationInvalidation(rootPath: fixture.root.path, reason: "file-change", at: fixture.date(201))
            XCTAssertTrue(fence.acknowledge(receipt))
            await store.close()
            let reopened = try EvidenceStore(url: fixture.database)
            let recovered = try await fixture.complete(store: reopened, at: 300, permit: fence.permit())
            XCTAssertEqual(recovered.currentFiles.filter { $0.presence == .present }.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted(), ["B", "C"])
            XCTAssertEqual(recovered.events.filter { $0.operation == .delete }.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["A"])
            await reopened.close()
        }
    }

    func testReceiptBeforeStoreAdmissionRejectsWithoutStartingStaging() async throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        try fixture.write("A", bytes: 1)
        let store = try EvidenceStore(url: fixture.database)
        let generation = try await store.beginOrResumeScanGeneration(scope: fixture.scope, at: fixture.date(100))
        let slice = DirectoryMetadataScanner().scanSlice(policy: fixture.policy, generation: generation, at: fixture.date(101))
        let fence = ScanPublicationFence()
        let permit = try fence.permit()
        fence.invalidate()
        do {
            _ = try await store.recordScanSlice(snapshot: fixture.snapshot(), slice: slice, scope: fixture.scope, trigger: .startup, publicationPermit: permit)
            XCTFail("Receipt already accepted")
        } catch let error as ScanPublicationError { XCTAssertEqual(error, .superseded) }
        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.observationCount, 0)
        XCTAssertEqual(diagnostics.snapshotCount, 0)
        await store.close()
    }

    func testReceiptAfterPublicationDoesNotRetroactivelyUndoTheCommittedObservation() async throws {
        let fixture = try PublicationFixture()
        defer { fixture.remove() }
        try fixture.write("A", bytes: 1)
        let store = try EvidenceStore(url: fixture.database)
        let fence = ScanPublicationFence()
        let result = try await fixture.complete(store: store, at: 100, permit: fence.permit())
        let receipt = fence.invalidate()
        XCTAssertThrowsError(try fence.permit())
        let retained = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(retained, result.currentFiles)
        try await store.recordReconciliationInvalidation(rootPath: fixture.root.path, reason: "file-change", at: fixture.date(100))
        XCTAssertTrue(fence.acknowledge(receipt))
        await store.close()
    }
}

private final class PublicationReceiptArm: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var value: UUID?
    var receipt: UUID? { lock.lock(); defer { lock.unlock() }; return value }
    func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
    func takeArm() -> Bool { lock.lock(); defer { lock.unlock() }; let result = armed; armed = false; return result }
    func setReceipt(_ receipt: UUID) { lock.lock(); defer { lock.unlock() }; value = receipt }
}

private actor PublicationCancellationFixture {
    private let connection: SQLiteConnection

    init(url: URL) throws {
        connection = try SQLiteConnection(url: url)
        try connection.execute("CREATE TABLE fixture (value INTEGER)")
    }

    func cancelAtCommit() -> Bool {
        do {
            try connection.withStatement("SELECT 1") { statement in
                // SQLite invokes this inside native COMMIT, after our explicit
                // precheck. Rejecting the commit rolls it back deterministically.
                _ = sqlite3_commit_hook(sqlite3_db_handle(statement), { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 1
                }, nil)
            }
            try connection.transaction(publicationPermit: ScanPublicationFence().permit()) {
                try connection.execute("INSERT INTO fixture VALUES (1)")
            }
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }

    func checkRecovery() throws -> Int64 {
        try connection.withStatement("SELECT 1") { statement in
            _ = sqlite3_commit_hook(sqlite3_db_handle(statement), nil, nil)
        }
        guard try connection.scalarInt("SELECT COUNT(*) FROM fixture") == 0 else { return -1 }
        try connection.transaction { try connection.execute("INSERT INTO fixture VALUES (2)") }
        return try connection.scalarInt("SELECT COUNT(*) FROM fixture")
    }
}

private struct PublicationFixture: Sendable {
    let directory: URL
    let root: URL
    let database: URL
    var policy: MonitoringPolicy { MonitoringPolicy(watchedRoots: [root], maximumEntries: 100, maximumDepth: 4) }
    var scope: EvidenceScopeVersion { policy.scopeVersion(at: date(0)) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "disk-steward-publication-\(UUID().uuidString)")
        root = directory.appending(path: "watched")
        database = directory.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    func write(_ name: String, bytes: Int) throws { try Data(repeating: 1, count: bytes).write(to: root.appending(path: name)) }
    func date(_ offset: Int) -> Date { Date(timeIntervalSince1970: 2_100_030_000 + Double(offset)) }
    func snapshot() -> StorageSnapshot {
        StorageSnapshot(snapshotID: UUID().uuidString, observedAt: "2036-07-19T00:00:00Z", volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)])
    }

    func complete(store: EvidenceStore, at offset: Int, permit: ScanPublicationPermit? = nil) async throws -> ObservationCommitResult {
        for index in 0..<20 {
            let generation = try await store.beginOrResumeScanGeneration(scope: scope, at: date(offset + index))
            let slice = DirectoryMetadataScanner().scanSlice(policy: policy, generation: generation, at: date(offset + index))
            let result = try await store.recordScanSlice(snapshot: snapshot(), slice: slice, scope: scope, trigger: .scheduled, publicationPermit: permit)
            if let observation = result.observation { return observation }
        }
        throw PublicationFixtureError.didNotComplete
    }
}

private enum PublicationFixtureError: Error {
    case didNotComplete
    case receiptBlockedByPreparation
}
