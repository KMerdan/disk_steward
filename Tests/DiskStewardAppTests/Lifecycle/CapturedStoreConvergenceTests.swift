@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

/// TASK-614 AC-02, opt-in: a captured copy of a real stuck store, placed at
/// `.captured/evidence.sqlite` inside an isolated snapshot, is stopped on first
/// open before any slice, and its retained evidence stays readable. Never point
/// this at a live store.
@MainActor
final class CapturedStoreConvergenceTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testCapturedStuckStoreStopsOnFirstOpen() async throws {
        let captured = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".captured/evidence.sqlite")
        guard FileManager.default.fileExists(atPath: captured.path) else {
            throw XCTSkip("No captured store in this snapshot")
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "captured-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "evidence.sqlite")
        try FileManager.default.copyItem(at: captured, to: database)

        let opened = try EvidenceStore(url: database, availableCapacitySource: { _ in Int64.max })
        let active = try await opened.activeScanGenerationSummary()
        let before = try XCTUnwrap(active, "the capture holds an active generation")
        let filesBefore = try await opened.diagnostics()
        await opened.close()

        var settings = MonitoringSettings.defaults
        settings.watchedRoots = before.configuredRoots
        settings.excludedRoots = before.excludedPaths
        settings.maxDatabaseMiB = 512
        let commits = Counter()
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024),
            resourceMeasurementSource: { _, load in
                .init(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: load)
            },
            volumeSampleSource: { _ in
                let snapshot = StorageSnapshot(snapshotID: UUID().uuidString, observedAt: EvidenceTimestamp.format(Date()),
                    volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)])
                return (snapshot, .init(observedAt: snapshot.observedAt, usedByteDeltas: ["/": 0], limitations: []))
            },
            afterScanCommit: { commits.increment() },
            continuationBudget: 0
        )
        let observation = try await probe.sample(settings: settings)
        let stop = try XCTUnwrap(observation.scanStop, "\(observation.growthReport.limitations)")
        XCTAssertEqual(stop.reason, .processedFarBeyondStaged)
        XCTAssertEqual(stop.processedEntryCount, before.processedEntryCount)
        // Opening a schema-14 capture migrates it; staged counts are recomputed
        // from staged rows, so only an upper bound is stable here.
        XCTAssertLessThanOrEqual(stop.stagedFileCount, before.stagedFileCount)
        XCTAssertEqual(commits.count, 0, "no slice was attempted")
        XCTAssertFalse(observation.needsScanContinuation)

        let reader = try EvidenceStore(url: database, availableCapacitySource: { _ in Int64.max })
        let after = try await reader.activeScanGenerationSummary()
        XCTAssertNil(after, "the stuck generation is abandoned")
        let filesAfter = try await reader.diagnostics()
        XCTAssertEqual(filesAfter.observationCount, filesBefore.observationCount, "retained observations are untouched")
        let summary = try await reader.lifecycleSummary(try .init())
        XCTAssertNotNil(summary.status.retentionGapCount, "the lifecycle summary still answers")
        await reader.close()
        print("CAPTURED-STOP", stop.generationID, stop.processedEntryCount, stop.stagedFileCount, "before", before.stagedFileCount,
              "observations", filesAfter.observationCount)
    }
}
