@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

/// TASK-642: when the evidence store fails, the board still receives a live
/// capacity observation with the reason, instead of a sampling error.
@MainActor
final class CapacityOnlyObservationTests: XCTestCase {
    private nonisolated static func volumeSample(_ previous: StorageSnapshot?) -> (StorageSnapshot, VolumeGrowthSample) {
        let snapshot = StorageSnapshot(snapshotID: UUID().uuidString, observedAt: EvidenceTimestamp.format(Date()),
            volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 400, isInternal: true, isReadOnly: false)])
        var growth = VolumeGrowthSample(observedAt: snapshot.observedAt, usedByteDeltas: ["/": previous == nil ? 0 : 25], limitations: [])
        growth.selectedVolumeIdentity = "UUID-capacity"
        return (snapshot, growth)
    }

    func testAFailingStoreDegradesToLiveCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "capacity-only-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        let probe = try PersistentMonitoringProbe(
            databaseURL: database, evidenceStore: store,
            resourceMeasurementSource: { _, load in
                .init(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: load)
            },
            volumeSampleSource: { Self.volumeSample($0) },
            continuationBudget: 0)
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [directory.path]
        settings.excludedRoots = []
        await store.close()  // every store call now fails

        let first = try await probe.sample(settings: settings)
        XCTAssertEqual(first.snapshot.volumes.first?.availableBytes, 400)
        XCTAssertEqual(first.capacity?.identity, "UUID-capacity")
        let reason = try XCTUnwrap(first.detailUnavailableReason)
        XCTAssertTrue(reason.contains("the volume figures are live"), reason)
        XCTAssertTrue(first.growthReport.limitations.contains(reason))
        XCTAssertFalse(first.needsScanContinuation)
        let second = try await probe.sample(settings: settings)
        XCTAssertEqual(second.growthReport.volumeUsedDelta, 25, "the volume baseline still advances")
    }

    func testCapacityOnlyProbeAnswersWhenTheStoreCannotOpen() async throws {
        let probe = CapacityOnlyMonitoringProbe(reason: "the evidence store could not be opened: fixture", volumeSampleSource: { Self.volumeSample($0) })
        let observation = try await probe.sample(settings: .defaults)
        XCTAssertEqual(observation.snapshot.volumes.count, 1)
        XCTAssertTrue(observation.detailUnavailableReason?.contains("could not be opened: fixture") == true)
        XCTAssertNil(observation.evidenceLifecycle)
    }
}
