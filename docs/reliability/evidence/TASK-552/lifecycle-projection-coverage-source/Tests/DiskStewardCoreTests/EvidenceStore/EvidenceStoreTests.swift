import Foundation
import XCTest
@testable import DiskStewardCore

final class EvidenceStoreTests: XCTestCase, @unchecked Sendable {
    func testMigrationEnablesWALAndIntegrityChecks() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)

        let diagnostics = try await store.diagnostics()

        XCTAssertEqual(diagnostics.schemaVersion, 13)
        XCTAssertEqual(diagnostics.journalMode.lowercased(), "wal")
        XCTAssertEqual(diagnostics.integrity, "ok")
        await store.close()
    }

    func testConcurrentReadsAndWritesPreserveEveryCommittedEvent() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 200 {
                group.addTask {
                    try await store.insert(Self.event(id: "event-\(index)", secondsAgo: index))
                }
            }
            for _ in 0 ..< 50 {
                group.addTask {
                    _ = try await store.eventCount()
                    _ = try await store.integrityCheck()
                }
            }
            try await group.waitForAll()
        }

        let count = try await store.eventCount()
        let integrity = try await store.integrityCheck()
        XCTAssertEqual(count, 200)
        XCTAssertEqual(integrity, "ok")
        await store.close()
    }

    func testInvalidBatchRollsBackAndReopenRecoversCommittedEvidence() async throws {
        let fixture = try Fixture()
        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL)
        try await store!.insert(Self.event(id: "committed", secondsAgo: 0))
        let invalid = EvidenceStoreEvent(
            eventID: "",
            observedAt: Self.now,
            operation: .create,
            path: "/fixture/invalid",
            logicalDelta: 1,
            allocatedDelta: 1,
            consumerCategory: "test",
            confidence: .unknown
        )

        do {
            try await store!.insert([Self.event(id: "must-rollback", secondsAgo: 0), invalid])
            XCTFail("Expected invalid batch to fail")
        } catch {
            XCTAssertEqual(error as? EvidenceStoreError, .invalidEvent("event_id is empty"))
        }
        let rolledBack = try await store!.containsEvent(id: "must-rollback")
        XCTAssertFalse(rolledBack)
        await store?.close()
        store = nil

        let reopened = try EvidenceStore(url: fixture.databaseURL)
        let containsCommitted = try await reopened.containsEvent(id: "committed")
        let containsRolledBack = try await reopened.containsEvent(id: "must-rollback")
        let reopenedIntegrity = try await reopened.integrityCheck()
        XCTAssertTrue(containsCommitted)
        XCTAssertFalse(containsRolledBack)
        XCTAssertEqual(reopenedIntegrity, "ok")
        await reopened.close()
    }

    func testRetentionAggregatesRawEventsAndBoundsHistory() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { Self.now })
        try await store.insert([
            Self.event(id: "old-1", secondsAgo: 2 * 86_400, delta: 10),
            Self.event(id: "old-2", secondsAgo: 2 * 86_400 - 60, delta: 15),
            Self.event(id: "recent", secondsAgo: 60, delta: 20),
            Self.event(id: "preserved-anomaly", secondsAgo: 2 * 86_400, delta: 30, anomaly: true),
        ])
        let policy = try EvidenceStoreRetentionPolicy(
            rawEventDays: 1,
            hourlySummaryDays: 7,
            dailySummaryDays: 30,
            maxDatabaseBytes: 10 * 1_024 * 1_024,
            writeCoalesceSeconds: 10,
            preserveUnreviewedAnomalies: true
        )

        let report = try await store.applyRetention(policy)
        let hourly = try await store.summaries(hourly: true)

        XCTAssertEqual(report.aggregatedRawEvents, 2)
        let retainedEventCount = try await store.eventCount()
        XCTAssertEqual(retainedEventCount, 2)
        XCTAssertEqual(hourly.reduce(0) { $0 + $1.eventCount }, 2)
        XCTAssertEqual(hourly.reduce(0) { $0 + $1.logicalDelta }, 25)
        XCTAssertLessThanOrEqual(report.storageBytes, policy.maxDatabaseBytes)
        await store.close()
    }

    func testBackupIsConsistentAndReadable() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        try await store.insert((0 ..< 25).map { Self.event(id: "backup-\($0)", secondsAgo: $0) })
        let snapshot = StorageSnapshot(
            snapshotID: "stored-snapshot",
            observedAt: "2026-09-12T00:00:00.000Z",
            volumes: [.init(mountPath: "/fixture", totalBytes: 100, availableBytes: 25, isInternal: true, isReadOnly: false)]
        )
        try await store.recordSnapshot(snapshot, observedAt: Self.now)
        try await store.backup(to: fixture.backupURL)

        let backup = try EvidenceStore(url: fixture.backupURL)
        let diagnostics = try await backup.diagnostics()
        XCTAssertEqual(diagnostics.eventCount, 25)
        XCTAssertEqual(diagnostics.snapshotCount, 1)
        XCTAssertEqual(diagnostics.integrity, "ok")
        await backup.close()
        await store.close()
    }

    func testDatabaseCeilingForcesBoundedEvictionAndCompaction() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL, dateSource: { Self.now })
        let longPath = "/fixture/" + String(repeating: "metadata-segment-", count: 70)
        let events = (0 ..< 12_000).map { index in
            EvidenceStoreEvent(
                eventID: "ceiling-\(index)",
                observedAt: Self.now,
                operation: .writeSummary,
                path: longPath + "\(index)",
                logicalDelta: 1,
                allocatedDelta: 1,
                consumerCategory: "developer-cache",
                confidence: .inferred
            )
        }
        try await store.insert(events)
        let policy = try EvidenceStoreRetentionPolicy(
            rawEventDays: 30,
            hourlySummaryDays: 180,
            dailySummaryDays: 730,
            maxDatabaseBytes: 10 * 1_024 * 1_024,
            writeCoalesceSeconds: 300,
            preserveUnreviewedAnomalies: true
        )

        let report = try await store.applyRetention(policy)
        let remainingEvents = try await store.eventCount()
        let integrity = try await store.integrityCheck()

        XCTAssertGreaterThan(report.forcedEvictions, 0)
        XCTAssertLessThanOrEqual(report.storageBytes, policy.maxDatabaseBytes)
        XCTAssertLessThan(remainingEvents, events.count)
        XCTAssertEqual(integrity, "ok")
        let runs = try await store.retentionRuns()
        let gaps = try await store.retentionCoverageGaps()
        XCTAssertEqual(runs.first?.runID, report.runID)
        XCTAssertEqual(runs.first?.result, .completed)
        XCTAssertEqual(runs.first?.forcedEvictions, report.forcedEvictions)
        XCTAssertEqual(gaps.first?.retentionRunID, report.runID)
        XCTAssertEqual(gaps.first?.rowsRemoved, report.forcedEvictions)
        await store.close()
    }

    func testCorruptionIsDetectedOnOpen() throws {
        let fixture = try Fixture()
        try Data("not a sqlite database".utf8).write(to: fixture.databaseURL)

        XCTAssertThrowsError(try EvidenceStore(url: fixture.databaseURL)) { error in
            guard case .sqlite = error as? EvidenceStoreError else {
                return XCTFail("Expected SQLite corruption error, got \(error)")
            }
        }
    }

    func testRetentionContractRejectsUnboundedValues() {
        XCTAssertThrowsError(
            try EvidenceStoreRetentionPolicy(
                rawEventDays: 0,
                hourlySummaryDays: 1_000,
                dailySummaryDays: 10_000,
                maxDatabaseBytes: Int64.max,
                writeCoalesceSeconds: 0,
                preserveUnreviewedAnomalies: true
            )
        )
    }

    func testStorageAdmissionRejectsAWriteBeforeItCanRunPastTheAllFileBudget() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL, maximumStorageBytes: 1 * 1_024 * 1_024)
        let oversizedBatch = (0 ..< 3_000).map { index in
            Self.event(id: "admission-\(index)", secondsAgo: index)
        }

        do {
            try await store.insert(oversizedBatch)
            XCTFail("Expected storage admission to reject the oversized batch")
        } catch let EvidenceStoreError.storageCapacityExceeded(currentBytes, capBytes) {
            XCTAssertLessThan(currentBytes, capBytes)
            XCTAssertEqual(capBytes, 1 * 1_024 * 1_024)
        }
        let retainedEventCount = try await store.eventCount()
        XCTAssertEqual(retainedEventCount, 0)
        await store.close()
    }

    func testLegacyUpgradeUsesAValidatedAtomicShadowAndPreservesEvidence() async throws {
        let fixture = try Fixture()
        try await seedLegacyFixture(fixture)
        let checkpoints = LockedStrings()

        let upgraded = try EvidenceStore(
            url: fixture.databaseURL,
            migrationCheckpoint: { checkpoints.append($0) },
            availableCapacitySource: { _ in Int64.max }
        )

        let diagnostics = try await upgraded.diagnostics()
        let containsLegacyEvent = try await upgraded.containsEvent(id: "legacy-event")
        let integrity = try await upgraded.integrityCheck()
        XCTAssertEqual(diagnostics.schemaVersion, 13)
        XCTAssertTrue(containsLegacyEvent)
        XCTAssertEqual(integrity, "ok")
        XCTAssertEqual(checkpoints.values, [
            "after-consistent-copy",
            "after-shadow-validation",
            "before-atomic-switch",
            "after-atomic-switch",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.migrationURL.path))
        await upgraded.close()
    }

    func testEveryMigrationInterruptionRecoversWithoutLosingTheLegacyDatabase() async throws {
        for interruption in [
            "after-consistent-copy",
            "after-shadow-validation",
            "before-atomic-switch",
            "after-atomic-switch",
        ] {
            let fixture = try Fixture()
            try await seedLegacyFixture(fixture)

            XCTAssertThrowsError(
                try EvidenceStore(
                    url: fixture.databaseURL,
                    migrationCheckpoint: { checkpoint in
                        if checkpoint == interruption {
                            throw InjectedMigrationFailure.interrupted(checkpoint)
                        }
                    },
                    availableCapacitySource: { _ in Int64.max }
                )
            ) { error in
                XCTAssertEqual(error as? InjectedMigrationFailure, .interrupted(interruption))
            }

            let recovered = try EvidenceStore(
                url: fixture.databaseURL,
                availableCapacitySource: { _ in Int64.max }
            )
            let containsLegacyEvent = try await recovered.containsEvent(id: "legacy-event")
            let integrity = try await recovered.integrityCheck()
            let diagnostics = try await recovered.diagnostics()
            XCTAssertTrue(containsLegacyEvent, interruption)
            XCTAssertEqual(integrity, "ok", interruption)
            XCTAssertEqual(diagnostics.schemaVersion, 13, interruption)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.migrationURL.path), interruption)
            await recovered.close()
        }
    }

    func testMigrationPreflightLeavesTheLegacyDatabaseUntouchedWhenCapacityIsInsufficient() async throws {
        let fixture = try Fixture()
        try await seedLegacyFixture(fixture)

        XCTAssertThrowsError(
            try EvidenceStore(
                url: fixture.databaseURL,
                availableCapacitySource: { _ in 1 }
            )
        ) { error in
            guard case let EvidenceStoreError.migrationInsufficientSpace(required, available) = error else {
                return XCTFail("Expected migrationInsufficientSpace, got \(error)")
            }
            XCTAssertGreaterThan(required, available)
            XCTAssertEqual(available, 1)
        }

        let unchanged = try SQLiteConnection(url: fixture.databaseURL)
        XCTAssertEqual(try unchanged.scalarInt("PRAGMA user_version"), 5)
        XCTAssertEqual(try unchanged.scalarInt("SELECT COUNT(*) FROM events WHERE event_id = 'legacy-event'"), 1)
        unchanged.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.migrationURL.path))
    }

    private func seedLegacyFixture(_ fixture: Fixture) async throws {
        let connection = try SQLiteConnection(url: fixture.databaseURL)
        defer { connection.close() }
        try connection.execute(HistoricalEvidenceSchema.v5)
        try connection.execute("""
            INSERT INTO events (event_id, observed_at, operation, path, logical_delta, allocated_delta,
                consumer_category, confidence, is_anomaly, is_reviewed)
            VALUES ('legacy-event', 2000000000, 'write-summary', '/fixture/cache.bin', 1, 1, 'developer-cache', 'inferred', 0, 0)
            """)
    }

    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    private static func event(
        id: String,
        secondsAgo: Int,
        delta: Int64 = 1,
        anomaly: Bool = false
    ) -> EvidenceStoreEvent {
        EvidenceStoreEvent(
            eventID: id,
            observedAt: now.addingTimeInterval(-Double(secondsAgo)),
            operation: .writeSummary,
            path: "/fixture/cache.bin",
            logicalDelta: delta,
            allocatedDelta: delta,
            consumerCategory: "developer-cache",
            confidence: .inferred,
            isAnomaly: anomaly
        )
    }
}

private final class Fixture {
    let directory: URL
    let databaseURL: URL
    let backupURL: URL
    var migrationURL: URL { databaseURL.appendingPathExtension("migration") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        databaseURL = directory.appending(path: "evidence.sqlite")
        backupURL = directory.appending(path: "backup.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum InjectedMigrationFailure: Error, Equatable {
    case interrupted(String)
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
