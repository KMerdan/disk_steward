@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

@MainActor
final class MonitoringProbeCancellationTests: XCTestCase {
    func testCommittedCancelledSampleStillAdvancesTheNextVolumeBaseline() async throws {
        for cancelledCommit in [1, 2] {
            let fixture = try ProbeCancellationFixture()
            defer { fixture.remove() }
            let source = CommitCancellationSource(cancelledCommit: cancelledCommit)
            let probe = try PersistentMonitoringProbe(
                databaseURL: fixture.database,
                resourceMeasurementSource: { _, underLoad in
                    ResourceMeasurement(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: underLoad)
                },
                volumeSampleSource: source.sample,
                afterScanCommit: source.afterCommit
            )
            if cancelledCommit == 2 { _ = try await probe.sample(settings: fixture.settings) }
            let settings = fixture.settings
            let cancelled = Task { try await probe.sample(settings: settings) }
            do {
                _ = try await cancelled.value
                XCTFail("Cancellation after the durable commit must suppress the result")
            } catch { XCTAssertTrue(error is CancellationError) }
            let recovered = try await probe.sample(settings: settings)
            XCTAssertEqual(source.previousSnapshotIDs.last, "volume-\(cancelledCommit)", "The next volume interval must match the already-committed detailed baseline")
            XCTAssertEqual(recovered.growthReport.volumeUsedDelta, 100)
            let reader = try EvidenceStore(url: fixture.database)
            let diagnostics = try await reader.diagnostics()
            XCTAssertEqual(diagnostics.observationCount, cancelledCommit + 1)
            await reader.close()
        }
    }

    func testAlreadyCancelledSampleDoesNotStartResourceOrStoreWork() async throws {
        let fixture = try ProbeCancellationFixture()
        defer { fixture.remove() }
        let source = CancellingResourceSource(cancelUnderLoad: false)
        let probe = try PersistentMonitoringProbe(databaseURL: fixture.database, resourceMeasurementSource: source.measure)
        let settings = fixture.settings
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await probe.sample(settings: settings)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled sample must not proceed")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(source.calls, 0)
        let reader = try EvidenceStore(url: fixture.database)
        let diagnostics = try await reader.diagnostics()
        let coverage = try await reader.scanCoverageStatus()
        XCTAssertEqual(diagnostics.observationCount, 0)
        XCTAssertEqual(diagnostics.snapshotCount, 0)
        XCTAssertNil(coverage?.activeGeneration)
        await reader.close()
    }

    func testCancellationAfterTraversalDoesNotSubmitItsComputedSlice() async throws {
        let fixture = try ProbeCancellationFixture()
        defer { fixture.remove() }
        let source = CancellingResourceSource(cancelUnderLoad: true)
        let probe = try PersistentMonitoringProbe(databaseURL: fixture.database, resourceMeasurementSource: source.measure)
        let settings = fixture.settings
        let task = Task { try await probe.sample(settings: settings) }
        do {
            _ = try await task.value
            XCTFail("The completed traversal must not be submitted after cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let reader = try EvidenceStore(url: fixture.database)
        let diagnostics = try await reader.diagnostics()
        let coverage = try await reader.scanCoverageStatus()
        XCTAssertEqual(diagnostics.observationCount, 0)
        XCTAssertEqual(diagnostics.snapshotCount, 0)
        XCTAssertEqual(coverage?.activeGeneration?.processedEntryCount, 0)
        await reader.close()

        // Its durable empty generation remains usable by a fresh invocation.
        let recovery = try PersistentMonitoringProbe(databaseURL: fixture.database, resourceMeasurementSource: { _, underLoad in
            ResourceMeasurement(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: underLoad)
        })
        let observation = try await recovery.sample(settings: settings)
        XCTAssertFalse(observation.needsScanContinuation)
        XCTAssertEqual(observation.evidenceLifecycle?.scanCoverage?.detailCoverage, "complete")
    }

    func testPartialAndFailedProbeResultsHaveHonestLifecyclePresentation() async throws {
        for kind in ["partial", "failed"] {
            let fixture = try ProbeCancellationFixture(fileCount: kind == "partial" ? 600 : 0)
            defer { fixture.remove() }
            let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
            settings.update {
                $0 = fixture.settings
                if kind == "failed" { $0.watchedRoots = [fixture.directory.appending(path: "missing-root").path] }
            }
            let probe = try PersistentMonitoringProbe(databaseURL: fixture.database, resourceMeasurementSource: { _, underLoad in
                ResourceMeasurement(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: underLoad)
            })
            let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil)
            await lifecycle.sampleNow()
            let observation = try XCTUnwrap(lifecycle.latestObservation)
            if kind == "partial" {
                XCTAssertTrue(observation.needsScanContinuation)
                XCTAssertEqual(observation.evidenceLifecycle?.scanCoverage?.detailCoverage, "partial")
                XCTAssertTrue(lifecycle.status.detail.contains("File-detail scanning is still in progress"))
            } else {
                XCTAssertFalse(observation.needsScanContinuation)
                XCTAssertEqual(observation.evidenceLifecycle?.scanCoverage?.detailCoverage, "unavailable")
                XCTAssertEqual(lifecycle.status.kind, .degraded)
                XCTAssertTrue(lifecycle.status.detail.contains("uncertain, not deleted"))
            }
            lifecycle.shutdown()
        }
    }
}

private final class CommitCancellationSource: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelledCommit: Int
    private var sampleCount = 0
    private var commitCount = 0
    private var previous: [String] = []
    init(cancelledCommit: Int) { self.cancelledCommit = cancelledCommit }
    var previousSnapshotIDs: [String] { lock.withLock { previous } }

    func sample(after old: StorageSnapshot?) -> (StorageSnapshot, VolumeGrowthSample) {
        let count = lock.withLock {
            previous.append(old?.snapshotID ?? "none")
            sampleCount += 1
            return sampleCount
        }
        let current = StorageSnapshot(snapshotID: "volume-\(count)", observedAt: "2026-09-17T00:00:00.000Z", volumes: [.init(mountPath: "/fixture", totalBytes: 10_000, availableBytes: 10_000 - Int64(count * 100), isInternal: true, isReadOnly: false)])
        return (current, VolumeGrowthSample(observedAt: current.observedAt, usedByteDeltas: ["/fixture": current.volumes[0].usedBytes - (old?.volumes.first?.usedBytes ?? current.volumes[0].usedBytes)], limitations: []))
    }

    func afterCommit() {
        let cancel = lock.withLock {
            commitCount += 1
            return commitCount == cancelledCommit
        }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

private final class CancellingResourceSource: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let cancelUnderLoad: Bool
    init(cancelUnderLoad: Bool) { self.cancelUnderLoad = cancelUnderLoad }
    var calls: Int { lock.withLock { count } }
    func measure(_ databaseURL: URL, _ underLoad: Bool) -> ResourceMeasurement {
        lock.withLock { count += 1 }
        if underLoad && cancelUnderLoad { withUnsafeCurrentTask { $0?.cancel() } }
        return ResourceMeasurement(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: underLoad)
    }
}

private struct ProbeCancellationFixture {
    let directory: URL
    let database: URL
    let settings: MonitoringSettings

    init(fileCount: Int = 2) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "probe-cancel-\(UUID().uuidString)", directoryHint: .isDirectory)
        database = directory.appending(path: "store/evidence.sqlite")
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        for index in 0 ..< fileCount { try Data([1]).write(to: watched.appending(path: "file-\(index)")) }
        var value = MonitoringSettings.defaults
        value.watchedRoots = [watched.path]
        value.excludedRoots = []
        settings = value
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
