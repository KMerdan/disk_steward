@testable import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

final class LifecycleProjectionIPCIntegrationTests: XCTestCase {
    func testActiveScanOnlyDowngradesOverlappingGrowthWindows() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-summary-window-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let watched = root.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: watched.appending(path: "recorded.bin"))
        let database = root.appending(path: "evidence.sqlite")
        let observedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let scanStartedAt = observedAt.addingTimeInterval(100)
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let scope = policy.scopeVersion(at: observedAt)
        let store = try EvidenceStore(url: database)
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "before-active-scan", observedAt: EvidenceTimestamp.format(observedAt), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: observedAt),
            scope: scope, trigger: .scheduled)
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        func growth(from: Date, through: Date) throws -> JSONValue {
            try client.call(tool: "explain_growth", arguments: [
                "from": .string(EvidenceTimestamp.format(from)), "through": .string(EvidenceTimestamp.format(through))
            ], isCancelled: { false })
        }
        let historicalFrom = observedAt.addingTimeInterval(-1)
        let historicalThrough = observedAt.addingTimeInterval(1)
        let before = try growth(from: historicalFrom, through: historicalThrough)
        XCTAssertEqual(before.objectValue?["coverage"], .string("complete"))
        XCTAssertGreaterThan(try XCTUnwrap(before.objectValue?["matched_count"]?.integerValue), 0)

        _ = try await store.beginOrResumeScanGeneration(scope: scope, at: scanStartedAt)
        let after = try growth(from: historicalFrom, through: historicalThrough)
        XCTAssertEqual(after.objectValue?["coverage"], before.objectValue?["coverage"], "An unrelated later scan must not downgrade this recorded historical interval")
        XCTAssertEqual(after.objectValue?["items"], before.objectValue?["items"])
        for (from, through) in [
            (observedAt, scanStartedAt), // Inclusive boundary matches stored gap semantics.
            (scanStartedAt.addingTimeInterval(1), scanStartedAt.addingTimeInterval(60))
        ] {
            XCTAssertEqual(try growth(from: from, through: through).objectValue?["coverage"], .string("partial"))
        }
        await store.close()
    }

    func testOversizedLifecycleMetadataReturnsTypedNonretryableErrorThroughIPC() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-summary-budget-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        _ = try await store.applyRetention(try .init(), trigger: .manual)
        await store.close()
        let fixture = try SQLiteConnection(url: database)
        try fixture.execute("UPDATE retention_runs SET limitations = zeroblob(600000)")
        fixture.close()
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        // TASK-642: capacity never depends on the lifecycle summary.
        let summary = try client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
        XCTAssertEqual(summary.objectValue?["detail_status"], .string("unavailable"))
        do { _ = try client.call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false }); XCTFail("Expected budget refusal") }
        catch DiskStewardIPCError.remote(let code, _, let retryable) {
            XCTAssertEqual(code, "query_budget_exceeded")
            XCTAssertFalse(retryable)
        }
        // TASK-652: growth still answers from the ring and the change journal,
        // and says the file-level detail is missing instead of guessing.
        let growth = try client.call(tool: "explain_growth", arguments: [
            "from": .string("2026-01-01T00:00:00Z"), "through": .string("2026-01-02T00:00:00Z")
        ], isCancelled: { false }).objectValue
        XCTAssertEqual(growth?["detail_status"], .string("unavailable"))
        XCTAssertEqual(growth?["detail_reasons"], .array([.string("lifecycle metadata exceeds the summary budget")]))
        XCTAssertEqual(growth?["coverage"], .string("unavailable"))
        XCTAssertNotNil(growth?["capacity_change"]?.objectValue?["status"])
        XCTAssertEqual(growth?["changed_directories"], .null, "no journal yet: unknown, not an empty list")
        XCTAssertNotNil(growth?["journal_limitations"])
    }

    func testForcedEvictionGapHistoryDoesNotLockOutSummaryTools() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-summary-gaps-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        _ = try await store.applyRetention(try .init(), trigger: .manual)
        await store.close()
        let fixture = try SQLiteConnection(url: database)
        try fixture.execute("""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1500)
            INSERT INTO retention_runs (run_id, trigger, policy, started_at, storage_bytes_before, result, limitations)
            SELECT printf('pressure-%036d', i), 'pressure', '{}', 1000000 + i, 0, 'completed', '[]' FROM n;
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1500)
            INSERT INTO retention_coverage_gaps (gap_id, retention_run_id, reason, affected_precision, started_at, rows_removed)
            SELECT printf('gap-pressure-%036d', i), printf('pressure-%036d', i), 'database-cap-forced-eviction', 'oldest-retained-history', 1000000 + i, i FROM n;
            """)
        fixture.close()
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        // The helper self-check asks for this summary; it must not be refused.
        let summary = try client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
        XCTAssertEqual(summary.objectValue?["schema"], .string(StorageSummaryContract.schema))
        let lifecycle = try client.call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
        let status = try XCTUnwrap(lifecycle.objectValue?["status"]?.objectValue)
        let limit = EvidenceStore.retentionGapProjectionLimit
        guard case let .array(gaps)? = status["retention_gaps"], case let .array(notes)? = lifecycle.objectValue?["limitations"] else {
            return XCTFail("Expected retention_gaps and limitations arrays")
        }
        XCTAssertEqual(gaps.count, limit)
        XCTAssertEqual(status["retention_gap_count"], .integer(1_500))
        let limitations = notes.compactMap(\.stringValue)
        XCTAssertTrue(limitations.contains { $0.contains("newest \(limit) of 1500 retention coverage gaps") }, "\(limitations)")
    }

    func testCoverageCountsOpenGapsBeyondTheListedWindow() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-summary-open-gaps-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let watched = root.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: watched.appending(path: "recorded.bin"))
        let database = root.appending(path: "evidence.sqlite")
        let observedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let policy = MonitoringPolicy(watchedRoots: [watched])
        let store = try EvidenceStore(url: database)
        _ = try await store.recordObservation(
            snapshot: .init(snapshotID: "open-gaps", observedAt: EvidenceTimestamp.format(observedAt), volumes: []),
            metadata: DirectoryMetadataScanner().scan(policy: policy, at: observedAt),
            scope: policy.scopeVersion(at: observedAt), trigger: .scheduled)
        await store.close()
        // One old open gap sits behind 600 newer resolved ones, outside the
        // listed window. Coverage must still see it.
        let fixture = try SQLiteConnection(url: database)
        try fixture.execute("""
            INSERT INTO coverage_gaps (gap_id, observation_id, root_path, reason, started_at, ended_at, state)
            SELECT 'gap-old-open', observation_id, '/fixture', 'entry-cap', 1700000000, NULL, 'open' FROM observation_runs LIMIT 1;
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)
            INSERT INTO coverage_gaps (gap_id, observation_id, root_path, reason, started_at, ended_at, state)
            SELECT printf('gap-resolved-%04d', i), (SELECT observation_id FROM observation_runs LIMIT 1), '/fixture', 'app-offline', 1790000000 + i, 1790000000 + i + 1, 'resolved' FROM n;
            """)
        let total = try fixture.scalarInt("SELECT COUNT(*) FROM coverage_gaps")
        fixture.close()
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        let limit = EvidenceStore.observationGapProjectionLimit

        let lifecycle = try client.call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
        XCTAssertEqual(lifecycle.objectValue?["coverage"], .string("partial"))
        let status = try XCTUnwrap(lifecycle.objectValue?["status"]?.objectValue)
        guard case let .array(listed)? = status["observation_gaps"], case let .array(notes)? = lifecycle.objectValue?["limitations"] else {
            return XCTFail("Expected observation_gaps and limitations arrays")
        }
        XCTAssertEqual(listed.count, limit)
        XCTAssertEqual(status["observation_gap_count"], .integer(total))
        XCTAssertEqual(status["open_observation_gap_count"], .integer(1))
        XCTAssertTrue(notes.compactMap(\.stringValue).contains { $0.contains("newest \(limit) of \(total) observation coverage gaps") })
        let summary = try client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
        XCTAssertEqual(summary.objectValue?["coverage"], .string("partial"))

        func growthCoverage(from: TimeInterval, through: TimeInterval) throws -> JSONValue? {
            try client.call(tool: "explain_growth", arguments: [
                "from": .string(EvidenceTimestamp.format(Date(timeIntervalSince1970: from))),
                "through": .string(EvidenceTimestamp.format(Date(timeIntervalSince1970: through))),
            ], isCancelled: { false }).objectValue?["coverage"]
        }
        XCTAssertEqual(try growthCoverage(from: 1_700_000_100, through: 1_700_000_200), .string("partial"), "the unlisted open gap overlaps this window")
        XCTAssertNotEqual(try growthCoverage(from: 1_699_000_000, through: 1_699_000_100), .string("partial"), "no gap overlaps this window")

        // Every gap open, as on a store whose entry-cap gaps never close:
        // the summaries still answer and count them all.
        let reopen = try SQLiteConnection(url: database)
        try reopen.execute("UPDATE coverage_gaps SET ended_at = NULL, state = 'open'")
        reopen.close()
        let allOpen = try client.call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
        XCTAssertEqual(allOpen.objectValue?["status"]?.objectValue?["open_observation_gap_count"], .integer(total))
        XCTAssertEqual(allOpen.objectValue?["coverage"], .string("partial"))
        _ = try client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
    }

    func testLifecycleDoesNotDecodeThePrivateTraversalCheckpoint() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-summary-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let watch = root.appending(path: "watch").path
        let now = Date()
        let scope = EvidenceScopeVersion(scopeVersionID: "summary-scope", effectiveAt: now,
            rootPaths: [watch], excludedPaths: [], maximumEntries: 100_000, maximumDepth: 20)
        let store = try EvidenceStore(url: database)
        let initial = try await store.beginOrResumeScanGeneration(scope: scope, at: now)
        let generation = MetadataScanGeneration(generationID: initial.generationID,
            scopeVersionID: scope.scopeVersionID, rootPaths: scope.rootPaths, excludedPaths: [], status: .active,
            roots: [.init(rootPath: watch, status: .pending,
                frontier: (0..<4_000).map { .init(directoryPath: watch + "/private-frontier-\($0)", depth: 1) })],
            processedEntryCount: 123, stagedFileCount: 0, startedAt: now, updatedAt: now,
            reconciliationToken: initial.reconciliationToken)
        _ = try await store.recordScanSlice(snapshot: .init(snapshotID: "summary", observedAt: EvidenceTimestamp.format(now), volumes: []),
            slice: .init(generation: generation, entries: []), scope: scope, trigger: .scheduled)
        await store.close()
        // This intentionally undecodable checkpoint is an access sentinel: a
        // public summary must use its independently persisted scalar projection.
        // It is not a claim that the scanner can resume corrupt private state.
        let connection = try SQLiteConnection(url: database)
        try connection.execute("UPDATE scan_generations SET progress = zeroblob(1048576)")
        connection.close()
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        let response = try client.call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
        let status = try XCTUnwrap(response.objectValue?["status"]?.objectValue)
        let coverage = try XCTUnwrap(status["scan_coverage"]?.objectValue)
        let active = try XCTUnwrap(coverage["active_generation"]?.objectValue)
        XCTAssertEqual(active["processed_entry_count"], .integer(123))
        XCTAssertEqual(active["pending_directory_count"], .integer(4_000))
        XCTAssertEqual(active["frontier_omitted"], .bool(true))
        XCTAssertEqual(coverage["latest_generation"], .null)
        XCTAssertEqual(coverage["detail_coverage"], .string("partial"))
        XCTAssertEqual(response.objectValue?["coverage"], .string("partial"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bytes = try encoder.encode(response)
        XCTAssertLessThan(bytes.count, 16_384)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-frontier"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(root.path))
        let growth = try client.call(tool: "explain_growth", arguments: [
            "from": .string(EvidenceTimestamp.format(now.addingTimeInterval(-1))),
            "through": .string(EvidenceTimestamp.format(now.addingTimeInterval(60)))
        ], isCancelled: { false })
        XCTAssertEqual(growth.objectValue?["coverage"], .string("partial"), "An active generation overlaps this window even without a persisted coverage-gap row")
    }

    func testEmptyLifecycleDoesNotClaimCompleteCoverageOrRefreshUserExportInventory() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-summary-empty-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let now = Date()
        let store = try EvidenceStore(url: database)
        for status in [EvidenceExportStatus.creating, .available] {
        try await store.persistExportRecord(.init(exportID: "user-owned", kind: .manual,
            requestedFrom: now, requestedThrough: now, actualFrom: nil, actualThrough: nil,
            precision: "unknown", pathDetail: .basename, path: root.appending(path: "private-export").path,
            bytes: 0, manifestSHA256: nil, createdAt: now, updatedAt: now, status: status, failure: nil))
        }
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let response = try UnixSocketDiskStewardIPCClient(socketPath: socket).call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
        XCTAssertEqual(response.objectValue?["coverage"], .string("unknown"))
        let exports = try await store.exportRecords()
        XCTAssertEqual(exports.first?.status, .available, "A read-only MCP status request must not stat or mutate user export inventory")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        XCTAssertFalse(String(decoding: try encoder.encode(response), as: UTF8.self).contains(root.path))
        await store.close()
    }
}
