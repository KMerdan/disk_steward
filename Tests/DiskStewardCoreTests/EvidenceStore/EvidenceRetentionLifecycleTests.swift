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
