@testable import DiskStewardCore
import Foundation
import XCTest

final class LifecycleProjectionTests: XCTestCase {
    private enum FixtureError: Error { case stop }

    func testV12MigrationPreservesPrivateCheckpointAndLeavesUnrecordedCountersUnknown() async throws {
        for interruption in [nil, "after-shadow-validation", "after-atomic-switch"] as [String?] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let database = root.appending(path: "evidence.sqlite")
            let start = Date(timeIntervalSince1970: 2_000_000_000)
            let original = try EvidenceStore(url: database)
            _ = try await original.beginOrResumeScanGeneration(scope: scope(at: start), at: start)
            await original.close()
            let old = try SQLiteConnection(url: database)
            // Schema 13 only adds this derived table. Removing it reconstructs
            // the actual v12 shape, not a version-number-only downgrade.
            try old.execute("DROP TABLE scan_generation_summaries; UPDATE scan_generations SET progress=zeroblob(1048576); PRAGMA user_version=12")
            old.close()
            if let interruption {
                do {
                    _ = try EvidenceStore(url: database, migrationCheckpoint: { if $0 == interruption { throw FixtureError.stop } }, availableCapacitySource: { _ in Int64.max })
                    XCTFail("Expected interrupted migration")
                } catch FixtureError.stop {}
                let inspect = try SQLiteConnection(url: database)
                XCTAssertEqual(try inspect.scalarInt("PRAGMA user_version"), interruption == "after-atomic-switch" ? EvidenceStore.currentSchemaVersion : 12)
                inspect.close()
            }
            for _ in 0..<2 {
                let store = try EvidenceStore(url: database, availableCapacitySource: { _ in Int64.max })
                let summary = try await store.lifecycleSummary(try .init(), at: start)
                XCTAssertEqual(summary.detailCoverage, "partial")
                XCTAssertNil(summary.scanCoverage?.activeGeneration?.pendingDirectoryCount)
                XCTAssertNil(summary.scanCoverage?.activeGeneration?.completedRootCount)
                let inspect = try SQLiteConnection(url: database)
                XCTAssertEqual(try inspect.scalarInt("SELECT length(progress) FROM scan_generations"), 1_048_576)
                XCTAssertEqual(try inspect.scalarInt("SELECT COUNT(*) FROM scan_generation_summaries"), 0)
                XCTAssertEqual(try inspect.scalarInt("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
                inspect.close()
                await store.close()
            }
        }
    }

    func testSummaryRefusesOversizedMetadataBeforeDecodeAndRollsBackReadSnapshot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        _ = try await store.applyRetention(try .init(), trigger: .manual)
        let fixture = try SQLiteConnection(url: database)
        try fixture.execute("UPDATE retention_runs SET limitations = zeroblob(600000)")
        do { _ = try await store.lifecycleSummary(try .init()); XCTFail("Expected pre-decode refusal") }
        catch { XCTAssertEqual(error as? EvidenceLifecycleSummaryError, .budgetExceeded) }
        try fixture.execute("UPDATE retention_runs SET limitations = '[]'")
        let recovered = try await store.lifecycleSummary(try .init())
        XCTAssertEqual(recovered.status.lastCompaction?.result, .completed)
        XCTAssertEqual(recovered.detailCoverage, "unknown")
        fixture.close()
        await store.close()
    }

    func testProjectionAndPrivateProgressCommitOrRollbackTogether() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        let now = Date()
        let scope = scope(at: now)
        let initial = try await store.beginOrResumeScanGeneration(scope: scope, at: now)
        let next = MetadataScanGeneration(generationID: initial.generationID, scopeVersionID: scope.scopeVersionID,
            rootPaths: scope.rootPaths, excludedPaths: [], status: .active,
            roots: [.init(rootPath: "/fixture", frontier: [.init(directoryPath: "/fixture/next", depth: 1)])],
            processedEntryCount: 30, stagedFileCount: 0, startedAt: now, updatedAt: now.addingTimeInterval(1),
            reconciliationToken: initial.reconciliationToken)
        let fixture = try SQLiteConnection(url: database)
        try fixture.execute("CREATE TRIGGER fail_projection BEFORE INSERT ON scan_generation_summaries BEGIN SELECT RAISE(ABORT, 'injected projection failure'); END")
        do {
            _ = try await store.recordScanSlice(snapshot: .init(snapshotID: "rollback", observedAt: EvidenceTimestamp.format(now), volumes: []),
                slice: .init(generation: next, entries: []), scope: scope, trigger: .scheduled)
            XCTFail("Expected the projection write to fail")
        } catch {}
        let privateState = try await store.scanCoverageStatus()
        let publicState = try await store.lifecycleSummary(try .init())
        XCTAssertEqual(privateState?.activeGeneration?.processedEntryCount, 0)
        XCTAssertEqual(publicState.scanCoverage?.activeGeneration?.processedEntryCount, 0)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM snapshots WHERE snapshot_id='rollback'"), 0)
        try fixture.execute("DROP TRIGGER fail_projection")
        _ = try await store.recordScanSlice(snapshot: .init(snapshotID: "committed", observedAt: EvidenceTimestamp.format(now), volumes: []),
            slice: .init(generation: next, entries: []), scope: scope, trigger: .scheduled)
        let committed = try await store.lifecycleSummary(try .init())
        XCTAssertEqual(committed.scanCoverage?.activeGeneration?.processedEntryCount, 30)
        fixture.close()
        await store.close()
    }

    func testSummaryProjectionSharesGenerationRetentionLifecycle() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        for index in 0..<68 {
            let date = Date(timeIntervalSince1970: Double(2_000_000_000 + index))
            let scope = EvidenceScopeVersion(scopeVersionID: "scope-\(index)", effectiveAt: date,
                rootPaths: ["/fixture"], excludedPaths: [], maximumEntries: 10, maximumDepth: 2)
            _ = try await store.beginOrResumeScanGeneration(scope: scope, at: date)
        }
        let fixture = try SQLiteConnection(url: database)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM scan_generations"), 65)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM scan_generation_summaries"), 65)
        XCTAssertEqual(try fixture.scalarInt("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
        fixture.close()
        await store.close()
    }

    func testReadSnapshotDoesNotBlockWALWriterAndUnwindsOnFailure() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "snapshot.sqlite")
        let reader = try SQLiteConnection(url: database)
        try reader.execute("PRAGMA journal_mode=WAL; CREATE TABLE value(n INTEGER); INSERT INTO value VALUES(1)")
        let writer = try SQLiteConnection(url: database)
        XCTAssertThrowsError(try reader.transaction(readOnly: true) {
            XCTAssertEqual(try reader.scalarInt("SELECT n FROM value"), 1)
            try writer.execute("UPDATE value SET n=2")
            XCTAssertEqual(try reader.scalarInt("SELECT n FROM value"), 1)
            throw FixtureError.stop
        })
        XCTAssertEqual(try reader.scalarInt("SELECT n FROM value"), 2)
        writer.close()
        reader.close()
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/ds-lifecycle-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func scope(at date: Date) -> EvidenceScopeVersion {
        .init(scopeVersionID: "scope", effectiveAt: date, rootPaths: ["/fixture"], excludedPaths: [], maximumEntries: 10, maximumDepth: 2)
    }
}
