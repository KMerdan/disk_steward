import DiskStewardCore
import XCTest
@testable import DiskStewardApp
@testable import DiskStewardCore

/// TASK-531: unfinished file detail continues inside one sample in bounded,
/// separately committed slices instead of waiting for the next scheduler turn.
@MainActor
final class ScanContinuationIncrementTests: XCTestCase {
    func testOneSampleConvergesAThousandsOfEntriesTreeWithoutSchedulerRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "continuation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let watched = directory.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileCount = 2_600
        for index in 0..<fileCount {
            let bucket = watched.appending(path: "bucket-\(index % 20)", directoryHint: .isDirectory)
            if index < 20 { try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true) }
            try Data([5]).write(to: bucket.appending(path: String(format: "f-%05d", index)))
        }
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        settings.maxDatabaseMiB = 64
        let probe = try PersistentMonitoringProbe(
            databaseURL: directory.appending(path: "support/evidence.sqlite"),
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024),
            resourceMeasurementSource: { _, load in
                .init(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: load)
            },
            volumeSampleSource: { previous in
                let snapshot = StorageSnapshot(snapshotID: UUID().uuidString, observedAt: EvidenceTimestamp.format(Date()),
                    volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)])
                _ = previous
                return (snapshot, .init(observedAt: snapshot.observedAt, usedByteDeltas: ["/": 0], limitations: []))
            },
            continuationBudget: 10
        )
        let started = Date()
        let observation = try await probe.sample(settings: settings)
        // 2,600 entries plus 21 directory passes exceed the 512-entry safety
        // slice many times over; one sample must still publish complete detail.
        XCTAssertFalse(observation.needsScanContinuation, "Continuation slices completed the generation inside one sample")
        XCTAssertFalse(observation.scanStalled)
        XCTAssertGreaterThanOrEqual(observation.continuationSlices, 4)
        XCTAssertEqual(observation.evidenceLifecycle?.scanCoverage?.detailCoverage, "complete")
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
        let store = try EvidenceStore(url: directory.appending(path: "support/evidence.sqlite"))
        let published1 = try await store.currentFiles()
        XCTAssertEqual(published1.count, fileCount)
        await store.close()
    }

    func testContinuationBudgetOfZeroKeepsOneSliceAndReportsContinuation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "continuation-zero-\(UUID().uuidString)", directoryHint: .isDirectory)
        let watched = directory.appending(path: "watch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<1_200 { try Data([6]).write(to: watched.appending(path: String(format: "g-%05d", index))) }
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        let probe = try PersistentMonitoringProbe(
            databaseURL: directory.appending(path: "support/evidence.sqlite"),
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024),
            resourceMeasurementSource: { _, load in
                .init(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: load)
            },
            volumeSampleSource: { previous in
                let snapshot = StorageSnapshot(snapshotID: UUID().uuidString, observedAt: EvidenceTimestamp.format(Date()),
                    volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)])
                _ = previous
                return (snapshot, .init(observedAt: snapshot.observedAt, usedByteDeltas: ["/": 0], limitations: []))
            },
            continuationBudget: 0
        )
        let observation = try await probe.sample(settings: settings)
        XCTAssertTrue(observation.needsScanContinuation, "One 512-entry slice cannot finish 1,200 entries")
        XCTAssertEqual(observation.continuationSlices, 0)
        XCTAssertEqual(observation.evidenceLifecycle?.scanCoverage?.detailCoverage, "partial")
    }
}
