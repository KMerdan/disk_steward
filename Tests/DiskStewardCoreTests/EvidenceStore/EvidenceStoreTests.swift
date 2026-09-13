import Foundation
import XCTest
@testable import DiskStewardCore

final class EvidenceStoreTests: XCTestCase, @unchecked Sendable {
    func testMigrationEnablesWALAndIntegrityChecks() async throws {
        let fixture = try Fixture()
        let store = try EvidenceStore(url: fixture.databaseURL)

        let diagnostics = try await store.diagnostics()

        XCTAssertEqual(diagnostics.schemaVersion, 5)
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
