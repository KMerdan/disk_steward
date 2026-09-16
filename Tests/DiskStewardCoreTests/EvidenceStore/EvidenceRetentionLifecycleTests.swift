import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardCore

final class EvidenceRetentionLifecycleTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 2_100_000_000)

    func testDefaultTierBoundariesAndSnapshotDownsamplingAreDeterministic() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = now
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { now })
        try await store.insert([
            event("recent", daysAgo: 1),
            event("raw-boundary", daysAgo: 7),
            event("expired-normal", daysAgo: 8),
            event("retained-anomaly", daysAgo: 20, anomaly: true),
            event("expired-anomaly", daysAgo: 31, anomaly: true),
        ])
        let snapshotDates = [
            now.addingTimeInterval(-3_600),
            now.addingTimeInterval(-7_200),
            now.addingTimeInterval(-10 * 86_400 - 10),
            now.addingTimeInterval(-10 * 86_400 - 1_000),
            now.addingTimeInterval(-10 * 86_400 - 4_000),
            now.addingTimeInterval(-40 * 86_400 - 10),
            now.addingTimeInterval(-40 * 86_400 - 1_000),
            now.addingTimeInterval(-366 * 86_400),
        ]
        for (index, date) in snapshotDates.enumerated() {
            try await store.recordSnapshot(snapshot(id: "snapshot-\(index)", at: date), observedAt: date)
        }

        let policy = try EvidenceStoreRetentionPolicy()
        let first = try await store.applyRetention(policy, trigger: .startup)
        let remaining = try await store.events(from: now.addingTimeInterval(-400 * 86_400), through: now, limit: 100)
        XCTAssertEqual(Set(remaining.map(\.eventID)), ["recent", "raw-boundary", "retained-anomaly"])
        XCTAssertEqual(first.aggregatedRawEvents, 2)
        XCTAssertEqual(first.deletedSnapshots, 3)
        let status = try await store.lifecycleStatus(policy, at: now)
        XCTAssertEqual(status.tiers.first { $0.tier == "snapshots" }?.count, 5)
        XCTAssertEqual(status.tiers.first { $0.tier == "anomaly-detail" }?.count, 1)
        XCTAssertEqual(status.lastCompaction?.runID, first.runID)
        XCTAssertEqual(status.databaseCapBytes, 512 * 1_024 * 1_024)

        let second = try await store.applyRetention(policy, trigger: .scheduled)
        XCTAssertEqual(second.aggregatedRawEvents, 0)
        XCTAssertEqual(second.deletedSnapshots, 0)
        let statusAfterReplay = try await store.lifecycleStatus(policy, at: now)
        XCTAssertEqual(statusAfterReplay.tiers.first { $0.tier == "snapshots" }?.count, 5)
    }

    func testCurrentPresentStateSurvivesWhileExpiredUnknownTombstoneIsRemoved() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let now = now
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { now })
        let old = now.addingTimeInterval(-10 * 86_400)
        try await observe(store, id: "o1", at: old, files: [
            file("A", path: "/fixture/a.bin", at: old),
            file("B", path: "/fixture/b.bin", at: old),
        ], coverage: .complete)
        try await observe(store, id: "o2", at: old.addingTimeInterval(60), files: [
            file("A", path: "/fixture/a.bin", at: old),
        ], coverage: .partial)
        let before = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(Set(before.map(\.objectID)), ["A", "B"])
        XCTAssertEqual(before.first { $0.objectID == "B" }?.presence, .unknown)

        _ = try await store.applyRetention(try .init(), trigger: .scheduled)
        let after = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(after.map(\.objectID), ["A"])
        XCTAssertEqual(after.first?.presence, .present)
        XCTAssertEqual(after.first?.stateAsOfObservationID, "o2")

        _ = try await store.applyRetention(try .init(), trigger: .scheduled)
        let afterReplay = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(afterReplay, after)
    }

    func testInterruptedExportsRecoverAsFailedAndInventoryRemainsBounded() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let old = now.addingTimeInterval(-7 * 60 * 60)
        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL, dateSource: { old })
        let interrupted = exportRecord(id: "interrupted", at: old, status: .creating)
        try await store!.persistExportRecord(interrupted)
        await store!.close()
        store = nil

        let restarted = try EvidenceStore(url: fixture.databaseURL, dateSource: { self.now })
        let recovered = try await restarted.exportRecords()
        XCTAssertEqual(recovered.first?.exportID, "interrupted")
        XCTAssertEqual(recovered.first?.status, .failed)
        XCTAssertTrue(recovered.first?.failure?.contains("stopped") == true)

        let protected = exportRecord(id: "protected-in-flight", at: now, status: .creating)
        try await restarted.persistExportRecord(protected)
        for index in 0 ..< 510 {
            let date = now.addingTimeInterval(Double(index + 1))
            let creating = exportRecord(id: "fill-\(index)", at: date, status: .creating)
            try await restarted.persistExportRecord(creating)
            try await restarted.persistExportRecord(exportRecord(id: "fill-\(index)", at: date, status: .failed))
        }
        let overflowDate = now.addingTimeInterval(1_000)
        try await restarted.persistExportRecord(exportRecord(id: "overflow", at: overflowDate, status: .creating))
        try await restarted.persistExportRecord(exportRecord(id: "protected-in-flight", at: now, status: .failed))

        for index in 0 ..< 513 {
            let date = now.addingTimeInterval(Double(index + 1))
            let creating = exportRecord(id: "bounded-\(index)", at: date, status: .creating)
            try await restarted.persistExportRecord(creating)
            try await restarted.persistExportRecord(exportRecord(id: "bounded-\(index)", at: date, status: .failed))
        }
        let inventory = try await restarted.exportRecords()
        let diagnostics = try await restarted.diagnostics()
        XCTAssertEqual(inventory.count, 512)
        XCTAssertEqual(diagnostics.exportRecordCount, 512)
    }

    func testUnchangedObservationsDoNotMultiplyDetailedStateHistory() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { self.now })
        let unchanged = file("A", path: "/fixture/a.bin", at: now)

        try await observe(store, id: "unchanged-1", at: now, files: [unchanged], coverage: .complete)
        try await observe(store, id: "unchanged-2", at: now.addingTimeInterval(60), files: [unchanged], coverage: .complete)

        let diagnostics = try await store.diagnostics()
        XCTAssertEqual(diagnostics.observationCount, 2)
        XCTAssertEqual(diagnostics.currentFileCount, 1)
        XCTAssertEqual(diagnostics.fileStateObservationCount, 1)
    }

    func testRetentionProcessesOldHistoryInBoundedRestartableBatches() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { self.now })
        let expiredCount = 10_050
        try await store.insert((0 ..< expiredCount).map { index in
            EvidenceStoreEvent(
                eventID: "expired-\(index)",
                observedAt: now.addingTimeInterval(-8 * 86_400),
                operation: .modify,
                path: "/fixture/expired-\(index)",
                logicalDelta: 1,
                allocatedDelta: 1,
                consumerCategory: "test",
                confidence: .inferred
            )
        })

        let first = try await store.applyRetention(try .init(), trigger: .scheduled)
        XCTAssertEqual(first.aggregatedRawEvents, 10_000)
        XCTAssertTrue(first.limitations.contains { $0.contains("bounded 10,000-row batch") })
        let afterFirst = try await store.eventCount()
        XCTAssertEqual(afterFirst, 50)

        let second = try await store.applyRetention(try .init(), trigger: .scheduled)
        XCTAssertEqual(second.aggregatedRawEvents, 50)
        let afterSecond = try await store.eventCount()
        XCTAssertEqual(afterSecond, 0)
    }

    func testCapacityRecoveryEvictsLegacyDetailedHistoryWithoutBreakingCurrentTruth() async throws {
        let fixture = try RetentionFixture()
        defer { fixture.cleanup() }
        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL, dateSource: { self.now })
        await store!.close()
        store = nil

        let connection = try SQLiteConnection(url: fixture.databaseURL)
        defer { connection.close() }
        try connection.execute("PRAGMA foreign_keys=ON")
        let nowValue = now.timeIntervalSince1970
        let oldValue = now.addingTimeInterval(-10 * 86_400).timeIntervalSince1970
        try connection.execute(
            """
            INSERT INTO scope_versions (scope_version_id, effective_at, roots_json, exclusions_json, maximum_entries, maximum_depth)
            VALUES ('legacy-scope', \(oldValue), '["/fixture"]', '[]', 100000, 20),
                   ('scan-scope', \(oldValue), '["/scan"]', '[]', 100000, 20);

            INSERT INTO scan_generations (generation_id, scope_version_id, status, started_at, updated_at, completed_at, processed_entry_count, staged_file_count, progress)
            VALUES ('scan-only', 'scan-scope', 'completed', \(oldValue), \(oldValue), \(oldValue), 0, 0, X'7B7D');

            INSERT INTO observation_runs (observation_id, scope_version_id, trigger, started_at, completed_at, coverage, event_gap)
            VALUES ('legacy-observation', 'legacy-scope', 'scheduled', \(nowValue - 60), \(nowValue - 60), 'complete', 0),
                   ('current-observation', 'legacy-scope', 'scheduled', \(nowValue), \(nowValue), 'complete', 0);

            WITH digits(value) AS (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)),
                 sequence(number) AS (
                    SELECT a.value + 10*b.value + 100*c.value + 1000*d.value + 10000*e.value
                    FROM digits a, digits b, digits c, digits d, digits e
                    WHERE a.value + 10*b.value + 100*c.value + 1000*d.value + 10000*e.value < 20000
                 )
            INSERT INTO file_objects (object_id, identity_method, first_observed_at, last_observed_at, lifecycle_state)
            SELECT printf('legacy-%05d', number), 'path-temporal', \(oldValue), \(oldValue), 'present'
            FROM sequence;

            WITH digits(value) AS (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)),
                 sequence(number) AS (
                    SELECT a.value + 10*b.value + 100*c.value + 1000*d.value + 10000*e.value
                    FROM digits a, digits b, digits c, digits d, digits e
                    WHERE a.value + 10*b.value + 100*c.value + 1000*d.value + 10000*e.value < 20000
                 )
            INSERT INTO file_state_observations (observation_id, object_id, path, root_path, logical_bytes, allocated_bytes, modified_at, existence, confidence)
            SELECT 'legacy-observation', printf('legacy-%05d', number),
                   '/fixture/' || printf('legacy-%05d-', number) || hex(zeroblob(512)),
                   '/fixture', 1, 4096, \(oldValue), 'present', 'inferred'
            FROM sequence;

            INSERT INTO file_objects (object_id, identity_method, first_observed_at, last_observed_at, lifecycle_state)
            VALUES ('current-object', 'path-temporal', \(nowValue), \(nowValue), 'present');
            INSERT INTO file_state_observations (observation_id, object_id, path, root_path, logical_bytes, allocated_bytes, modified_at, existence, confidence)
            VALUES ('current-observation', 'current-object', '/fixture/current', '/fixture', 10, 16, \(nowValue), 'present', 'inferred');
            INSERT INTO current_file_state (object_id, identity_method, path, root_path, scope_version_id, logical_bytes, allocated_bytes, modified_at, presence, state_as_of_observation_id, observed_at, actionable)
            VALUES ('current-object', 'path-temporal', '/fixture/current', '/fixture', 'legacy-scope', 10, 16, \(nowValue), 'present', 'current-observation', \(nowValue), 1);
            """
        )
        connection.close()

        let capBytes: Int64 = 10 * 1_024 * 1_024
        store = try EvidenceStore(url: fixture.databaseURL, dateSource: { self.now })
        let before = try await store!.diagnostics()
        XCTAssertGreaterThan(before.storageBytes, capBytes)

        let report = try await store!.applyRetention(
            try EvidenceStoreRetentionPolicy(maxDatabaseBytes: capBytes),
            trigger: .pressure
        )
        let after = try await store!.diagnostics()
        let current = try await store!.currentFiles(includeNonActionable: true)

        XCTAssertEqual(report.forcedEvictions, 20_000)
        XCTAssertEqual(after.fileStateObservationCount, 1)
        XCTAssertLessThanOrEqual(after.storageBytes, capBytes)
        XCTAssertEqual(current.map(\.objectID), ["current-object"])
        XCTAssertEqual(current.first?.stateAsOfObservationID, "current-observation")
        await store!.close()
        store = nil

        let verifier = try SQLiteConnection(url: fixture.databaseURL)
        XCTAssertEqual(try verifier.scalarInt("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
        XCTAssertEqual(try verifier.scalarInt("SELECT COUNT(*) FROM scope_versions WHERE scope_version_id = 'scan-scope'"), 1)
        verifier.close()
    }

    private func event(_ id: String, daysAgo: Int, anomaly: Bool = false) -> EvidenceStoreEvent {
        .init(
            eventID: id,
            observedAt: now.addingTimeInterval(-Double(daysAgo * 86_400)),
            operation: .modify,
            path: "/fixture/\(id)",
            logicalDelta: 1,
            allocatedDelta: 1,
            consumerCategory: "test",
            confidence: .inferred,
            isAnomaly: anomaly
        )
    }

    private func snapshot(id: String, at date: Date) -> StorageSnapshot {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .init(
            snapshotID: id,
            observedAt: formatter.string(from: date),
            volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)]
        )
    }

    private func exportRecord(id: String, at date: Date, status: EvidenceExportStatus) -> EvidenceExportRecord {
        .init(
            exportID: id,
            kind: .manual,
            requestedFrom: date,
            requestedThrough: date,
            actualFrom: nil,
            actualThrough: nil,
            precision: status == .creating ? "pending" : "none",
            pathDetail: .basename,
            path: "/tmp/\(id)",
            bytes: 0,
            manifestSHA256: nil,
            createdAt: date,
            updatedAt: date,
            status: status,
            failure: status == .failed ? "fixture failure" : nil
        )
    }

    private func file(_ id: String, path: String, at date: Date) -> FileMetadata {
        .init(objectID: id, identityMethod: .pathTemporal, rootPath: "/fixture", path: path, logicalBytes: 10, allocatedBytes: 16, modifiedAt: date)
    }

    private func observe(
        _ store: EvidenceStore,
        id: String,
        at date: Date,
        files: [FileMetadata],
        coverage: ObservationCoverage
    ) async throws {
        let metadata = MetadataSnapshot(
            observationID: id,
            scopeVersionID: "scope",
            observedAt: date,
            entries: Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) }),
            rootCoverage: [.init(rootPath: "/fixture", coverage: coverage, limitations: coverage == .complete ? [] : ["fixture partial coverage"])],
            limitations: []
        )
        _ = try await store.recordObservation(
            snapshot: snapshot(id: "snapshot-\(id)", at: date),
            metadata: metadata,
            scope: .init(scopeVersionID: "scope", effectiveAt: date, rootPaths: ["/fixture"], excludedPaths: [], maximumEntries: 100, maximumDepth: 5),
            trigger: .scheduled
        )
    }
}

private struct RetentionFixture {
    let root: URL
    let databaseURL: URL

    init() throws {
        root = URL(fileURLWithPath: "/tmp/ds-retention-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        databaseURL = root.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
