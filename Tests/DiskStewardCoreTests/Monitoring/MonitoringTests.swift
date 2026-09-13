import Foundation
import CoreServices
import XCTest
@testable import DiskStewardCore

final class MonitoringTests: XCTestCase, @unchecked Sendable {
    func testPolicyCombinesStableRegisteredAndActiveInvestigationRoots() throws {
        let fixture = try Fixture()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let policy = MonitoringPolicy(
            watchedRoots: [fixture.watched],
            registeredRoots: [fixture.registered],
            excludedRoots: [fixture.excluded],
            investigations: [
                .init(root: fixture.investigation, expiresAt: now.addingTimeInterval(60)),
                .init(root: fixture.expired, expiresAt: now),
            ]
        )

        XCTAssertEqual(Set(policy.activeRoots(at: now).map(\.path)), Set([
            fixture.watched.path, fixture.registered.path, fixture.investigation.path,
        ]))
        XCTAssertTrue(policy.includes(path: fixture.watched.appending(path: "kept.bin").path, at: now))
        XCTAssertFalse(policy.includes(path: fixture.excluded.appending(path: "ignored.bin").path, at: now))
        XCTAssertFalse(policy.includes(path: fixture.expired.appending(path: "old.bin").path, at: now))
        XCTAssertTrue(policy.scopeLimitations(at: now).contains { $0.contains("Excluded subtree") })
        XCTAssertTrue(policy.scopeLimitations(at: now).contains { $0.contains("Investigation window expired") })
    }

    func testMetadataScannerDerivesBoundedChangesWithoutReadingContents() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.excluded, withIntermediateDirectories: true)
        let policy = MonitoringPolicy(
            watchedRoots: [fixture.watched],
            excludedRoots: [fixture.excluded],
            maximumEntries: 10,
            maximumDepth: 4
        )
        let scanner = DirectoryMetadataScanner()
        let before = scanner.scan(policy: policy, at: Date(timeIntervalSince1970: 100))
        try Data(repeating: 7, count: 8_192).write(to: fixture.watched.appending(path: "created.bin"))
        try Data(repeating: 9, count: 8_192).write(to: fixture.excluded.appending(path: "secret.bin"))
        let after = scanner.scan(policy: policy, at: Date(timeIntervalSince1970: 101))
        let changes = scanner.changes(from: before, to: after)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.operation, .create)
        XCTAssertEqual(changes.first?.logicalDelta, 8_192)
        XCTAssertGreaterThan(changes.first?.allocatedDelta ?? 0, 0)
        XCTAssertEqual(changes.first?.confidence, .inferred)
        XCTAssertFalse(changes.first?.path.contains("secret.bin") == true)
    }

    func testMetadataScannerReportsUnavailableAndEntryLimit() throws {
        let fixture = try Fixture()
        for index in 0 ..< 3 {
            try Data([UInt8(index)]).write(to: fixture.watched.appending(path: "file-\(index)"))
        }
        let missing = fixture.directory.appending(path: "missing", directoryHint: .isDirectory)
        let policy = MonitoringPolicy(watchedRoots: [fixture.watched, missing], maximumEntries: 1)

        let snapshot = DirectoryMetadataScanner().scan(policy: policy)

        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertTrue(snapshot.limitations.contains { $0.contains("entry limit") })
        XCTAssertTrue(snapshot.limitations.contains { $0.contains("Watched root unavailable") })
        XCTAssertTrue(snapshot.limitations.contains { $0.contains("File-level detail is limited") })
    }

    func testMetadataScannerPreservesSharedIdentityAndLinkCountForHardLinks() throws {
        let fixture = try Fixture()
        let original = fixture.watched.appending(path: "original.bin")
        let alias = fixture.watched.appending(path: "alias.bin")
        try Data(repeating: 3, count: 4_096).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)

        let snapshot = DirectoryMetadataScanner().scan(policy: MonitoringPolicy(watchedRoots: [fixture.watched]))
        let originalMetadata = try XCTUnwrap(snapshot.entries[original.path])
        let aliasMetadata = try XCTUnwrap(snapshot.entries[alias.path])

        XCTAssertEqual(originalMetadata.objectID, aliasMetadata.objectID)
        XCTAssertNotEqual(originalMetadata.identityMethod, .pathTemporal)
        XCTAssertGreaterThanOrEqual(originalMetadata.linkCount, 2)
        XCTAssertEqual(originalMetadata.linkCount, aliasMetadata.linkCount)
    }

    func testGrowthInsideAndOutsideWatchedRootBecomesDetailedAndUnexplained() throws {
        let fixture = try Fixture()
        let policy = MonitoringPolicy(watchedRoots: [fixture.watched])
        let scanner = DirectoryMetadataScanner()
        let before = scanner.scan(policy: policy, at: Date(timeIntervalSince1970: 100))
        let inside = fixture.watched.appending(path: "inside.bin")
        let outside = fixture.directory.appending(path: "outside.bin")
        try Data(repeating: 1, count: 8_192).write(to: inside)
        try Data(repeating: 2, count: 16_384).write(to: outside)
        let after = scanner.scan(policy: policy, at: Date(timeIntervalSince1970: 101))
        let events = scanner.changes(from: before, to: after)
        let insideAllocated = events.reduce(0) { $0 + max(0, $1.allocatedDelta) }
        let outsideAllocated = Int64(try outside.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)

        let report = GrowthExplanationEngine().explain(
            volumeUsedDelta: insideAllocated + outsideAllocated,
            detailedEvents: events,
            scopeLimitations: after.limitations
        )

        XCTAssertEqual(events.map(\.path), [inside.path])
        XCTAssertEqual(report.detailedPositiveDelta, insideAllocated)
        XCTAssertEqual(report.unexplainedDelta, outsideAllocated)
        XCTAssertTrue(report.causes.contains { $0.category == "unexplained" && $0.confidence == .unknown })
    }

    func testFSEventsInterpreterFiltersExclusionsAndPreservesGapEvidence() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.excluded, withIntermediateDirectories: true)
        let policy = MonitoringPolicy(watchedRoots: [fixture.watched], excludedRoots: [fixture.excluded])
        let included = fixture.watched.appending(path: "included.bin").path
        let excluded = fixture.excluded.appending(path: "excluded.bin").path
        let outside = fixture.directory.appending(path: "outside.bin").path
        let gapAndCreate = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemCreated
        )

        let batch = FSEventsBatchInterpreter.interpret(
            paths: [included, excluded, outside],
            flags: [gapAndCreate, FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), 0],
            eventIDs: [11, 12, 13],
            policy: policy,
            observedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(batch?.hints.map(\.path), [included])
        XCTAssertEqual(batch?.hints.first?.kind, .created)
        XCTAssertEqual(batch?.hints.first?.eventID, 11)
        XCTAssertTrue(batch?.eventGap == true)
        XCTAssertTrue(batch?.limitations.contains { $0.contains("rescan affected roots") } == true)
    }

    func testWriteCoalescerMergesOnlyMatchingPathAndOperationInWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let events = [
            event(id: "a", path: "/tmp/a", at: start, delta: 10, confidence: .exact),
            event(id: "b", path: "/tmp/a", at: start.addingTimeInterval(5), delta: 15, confidence: .inferred),
            event(id: "c", path: "/tmp/a", at: start.addingTimeInterval(30), delta: 20, confidence: .exact),
            event(id: "d", path: "/tmp/b", at: start.addingTimeInterval(1), delta: 5, confidence: .exact),
        ]

        let output = WriteCoalescer().coalesce(events, within: 10)

        XCTAssertEqual(output.count, 3)
        XCTAssertEqual(output.first { $0.eventID == "a" }?.allocatedDelta, 25)
        XCTAssertEqual(output.first { $0.eventID == "a" }?.confidence, .inferred)
    }

    func testWholeVolumeSamplerReturnsMountedVolumeMetrics() throws {
        let (snapshot, sample) = try WholeVolumeSampler().sample(after: nil)

        XCTAssertFalse(snapshot.volumes.isEmpty)
        XCTAssertEqual(Set(sample.usedByteDeltas.values), [0])
        XCTAssertTrue(snapshot.volumes.allSatisfy { $0.totalBytes >= $0.usedBytes && $0.usedBytes >= 0 })
    }

    func testNativeFSEventsCollectorEmitsRescanHintForWatchedRoot() throws {
        let fixture = try Fixture()
        let collector = TargetedFSEventsCollector()
        let observed = expectation(description: "FSEvents path hint")
        let expectedPath = fixture.watched.appending(path: "live-smoke.txt").path
        let batches = LockedBatches()
        try collector.start(
            policy: MonitoringPolicy(watchedRoots: [fixture.watched]),
            latency: 0.05
        ) { batch in
            batches.append(batch)
            if batch.hints.contains(where: { $0.path == expectedPath }) {
                observed.fulfill()
            }
        }
        try Data("smoke".utf8).write(to: URL(fileURLWithPath: expectedPath))

        wait(for: [observed], timeout: 5)
        collector.stop()

        let hints = batches.value.flatMap(\.hints).filter { $0.path == expectedPath }
        XCTAssertFalse(hints.isEmpty)
        XCTAssertTrue(hints.allSatisfy(\.requiresRescan))
    }

    private func event(
        id: String,
        path: String,
        at date: Date,
        delta: Int64,
        confidence: EvidenceStoreEvent.Confidence
    ) -> EvidenceStoreEvent {
        EvidenceStoreEvent(
            eventID: id,
            observedAt: date,
            operation: .writeSummary,
            path: path,
            logicalDelta: delta,
            allocatedDelta: delta,
            consumerCategory: "test",
            confidence: confidence
        )
    }
}

private final class LockedBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TargetedChangeBatch] = []

    var value: [TargetedChangeBatch] {
        lock.withLock { storage }
    }

    func append(_ batch: TargetedChangeBatch) {
        lock.withLock { storage.append(batch) }
    }
}

private final class Fixture {
    let directory: URL
    let watched: URL
    let registered: URL
    let excluded: URL
    let investigation: URL
    let expired: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        registered = directory.appending(path: "registered", directoryHint: .isDirectory)
        excluded = watched.appending(path: "excluded", directoryHint: .isDirectory)
        investigation = directory.appending(path: "investigation", directoryHint: .isDirectory)
        expired = directory.appending(path: "expired", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: registered, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: investigation, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: expired, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
