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

    func testForcedEvictionGapsAtTheRunCapStayWithinTheSummaryBudget() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        _ = try await store.applyRetention(try .init(), trigger: .manual)
        let fixture = try SQLiteConnection(url: database)
        // One gap per pressure run, as long as runs are kept (1500): the shape
        // a store pinned at its cap reaches. Both the old row and byte checks
        // would refuse it.
        try fixture.execute("""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1500)
            INSERT INTO retention_runs (run_id, trigger, policy, started_at, storage_bytes_before, result, limitations)
            SELECT printf('pressure-%036d', i), 'pressure', '{}', 1000000 + i, 0, 'completed', '[]' FROM n;
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1500)
            INSERT INTO retention_coverage_gaps (gap_id, retention_run_id, reason, affected_precision, started_at, rows_removed)
            SELECT printf('gap-pressure-%036d', i), printf('pressure-%036d', i), 'database-cap-forced-eviction', 'oldest-retained-history', 1000000 + i, i FROM n;
            """)
        XCTAssertGreaterThan(try fixture.scalarInt("SELECT SUM(256 + length(gap_id) + length(retention_run_id) + length(reason) + length(affected_precision)) FROM retention_coverage_gaps"), 512 * 1_024)
        let limit = EvidenceStore.retentionGapProjectionLimit
        let summary = try await store.lifecycleSummary(try .init())
        let full = try await store.lifecycleStatus(try .init())
        for status in [summary.status, full] {
            XCTAssertEqual(status.retentionGaps.count, limit)
            XCTAssertEqual(status.retentionGapCount, 1_500)
            XCTAssertEqual(status.retentionGaps.first?.gapID, String(format: "gap-pressure-%036d", 1_500))
            XCTAssertEqual(status.retentionGaps.last?.gapID, String(format: "gap-pressure-%036d", 1_500 - limit + 1))
        }
        // The window is still measured before decode: one oversized listed gap refuses.
        try fixture.execute("UPDATE retention_coverage_gaps SET reason = zeroblob(600000) WHERE started_at = 1001500")
        do { _ = try await store.lifecycleSummary(try .init()); XCTFail("Expected pre-decode refusal") }
        catch { XCTAssertEqual(error as? EvidenceLifecycleSummaryError, .budgetExceeded) }
        fixture.close()
        await store.close()
    }

    func testObservationGapVerdictsCoverRowsBeyondTheListedWindow() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watched = root.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try Data([1]).write(to: watched.appending(path: "recorded.bin"))
        let database = root.appending(path: "evidence.sqlite")
        let observedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let store = try EvidenceStore(url: database)
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "open-gaps", observedAt: EvidenceTimestamp.format(observedAt), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: observedAt),
            scope: policy.scopeVersion(at: observedAt), trigger: .scheduled)
        let fixture = try SQLiteConnection(url: database)
        try fixture.execute("""
            INSERT INTO coverage_gaps (gap_id, observation_id, root_path, reason, started_at, ended_at, state)
            SELECT 'gap-old-open', observation_id, '/fixture', 'entry-cap', 1700000000, NULL, 'open' FROM observation_runs LIMIT 1;
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)
            INSERT INTO coverage_gaps (gap_id, observation_id, root_path, reason, started_at, ended_at, state)
            SELECT printf('gap-resolved-%04d', i), (SELECT observation_id FROM observation_runs LIMIT 1), '/fixture', 'app-offline', 1790000000 + i, 1790000000 + i + 1, 'resolved' FROM n;
            """)
        let total = Int(try fixture.scalarInt("SELECT COUNT(*) FROM coverage_gaps"))
        let limit = EvidenceStore.observationGapProjectionLimit
        let summary = try await store.lifecycleSummary(try .init(),
            gapWindow: (Date(timeIntervalSince1970: 1_700_000_100), Date(timeIntervalSince1970: 1_700_000_200)))
        XCTAssertEqual(summary.status.observationGaps.count, limit)
        XCTAssertFalse(summary.status.observationGaps.contains { $0.gapID == "gap-old-open" })
        XCTAssertEqual(summary.status.observationGapCount, total)
        XCTAssertEqual(summary.status.openObservationGapCount, 1)
        XCTAssertEqual(summary.observationGapsOverlapWindow, true)
        let disjoint = try await store.lifecycleSummary(try .init(),
            gapWindow: (Date(timeIntervalSince1970: 1_699_000_000), Date(timeIntervalSince1970: 1_699_000_100)))
        XCTAssertEqual(disjoint.observationGapsOverlapWindow, false)
        let unwindowed = try await store.lifecycleSummary(try .init())
        XCTAssertNil(unwindowed.observationGapsOverlapWindow)
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
