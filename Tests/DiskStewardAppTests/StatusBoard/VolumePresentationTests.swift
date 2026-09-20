@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

@MainActor
final class VolumePresentationTests: XCTestCase {
    func testCapacityAlertsSurvivePendingFileReconciliationWithoutDuplicates() async throws {
        let fixture = VolumeFixture(pendingChanges: true)
        defer { fixture.lifecycle.shutdown() }
        await fixture.lifecycle.sampleNow()
        await fixture.probe.set(volumeObservation(index: 1, used: 900_000_000_000))
        await fixture.lifecycle.sampleNow()
        XCTAssertEqual(fixture.lifecycle.status.title, "Reconciling")
        let pendingMessages = await fixture.delivery.values
        XCTAssertEqual(pendingMessages.count, 2, "Valid capacity alerts do not require file attribution")
        XCTAssertNotNil(fixture.lifecycle.latestGrowthAlert)
        try await fixture.probe.persistPendingChanges()
        await fixture.probe.set(volumeObservation(index: 2, used: 900_000_000_000))
        await fixture.lifecycle.sampleNow()
        XCTAssertEqual(fixture.lifecycle.status.kind, .recovered)
        let clearedMessages = await fixture.delivery.values
        XCTAssertEqual(clearedMessages.count, 2, "Clearing file hints must not replay the same threshold")
    }

    func testGrowthEventIsRetainedBeforeCapacityNotificationWaitAndPause() async throws {
        let fixture = VolumeFixture()
        defer { fixture.lifecycle.shutdown() }
        await fixture.lifecycle.sampleNow()
        await fixture.delivery.hold()
        await fixture.probe.set(volumeObservation(index: 1, used: 900_000_000_000))
        let sample = Task { await fixture.lifecycle.sampleNow() }
        try await eventually { await fixture.delivery.values.count == 1 }
        // Both capacity and growth crossed. Only the capacity notification has
        // reached delivery; retaining the growth fact must not wait behind it.
        XCTAssertEqual(fixture.lifecycle.latestGrowthAlert?.usedByteDelta, 320_000_000_000)
        fixture.lifecycle.pause()
        await sample.value
        let messages = await fixture.delivery.values
        XCTAssertEqual(messages.count, 1, "Cancellation still prevents the second external submission")
        XCTAssertEqual(fixture.lifecycle.latestGrowthAlert?.observationID, "volume-1")
    }

    func testBaselineSignedIntervalsAlertRetentionAndRestart() async throws {
        let fixture = VolumeFixture()
        defer { fixture.lifecycle.shutdown() }
        let model = StatusBoardViewModel(lifecycle: fixture.lifecycle)
        await fixture.lifecycle.sampleNow()
        XCTAssertEqual(model.growthSummary, "Awaiting growth baseline")
        XCTAssertNil(fixture.lifecycle.latestGrowthAlert)
        XCTAssertTrue(model.evidenceFreshnessSummary.contains(fixtureDetailDate))
        XCTAssertTrue(model.capacityFreshnessSummary.contains(Date(timeIntervalSince1970: 1_789_862_400).formatted(date: .abbreviated, time: .standard)))

        await fixture.probe.set(volumeObservation(index: 1, used: 585_600_000_000))
        await fixture.lifecycle.sampleNow()
        let alert = try XCTUnwrap(fixture.lifecycle.latestGrowthAlert)
        let notices = await fixture.delivery.values
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.growthComparison, alert)
        XCTAssertTrue(notices.first?.body.contains(model.growthSummary) == true)
        XCTAssertTrue(notices.first?.body.contains(model.growthDetail) == true)
        XCTAssertEqual(alert.observationID, "volume-1")
        XCTAssertEqual(alert.baselineObservationID, "volume-0")
        XCTAssertEqual(alert.volumeIdentity, "UUID-A")
        XCTAssertEqual(alert.usedByteDelta, 5_600_000_000)
        XCTAssertEqual(alert.end.timeIntervalSince(alert.start), 60)
        print("ALERT-TRACE \(alert.observationID) baseline=\(alert.baselineObservationID) volume=\(alert.volumeIdentity) bytes=\(alert.usedByteDelta) interval=\(alert.intervalText)")

        for (index, used, expected) in [(2, Int64(585_602_100_000), "+2.1 MB"), (3, 582_602_100_000, "−3 GB"), (4, 582_602_100_000, "No change")] {
            await fixture.probe.set(volumeObservation(index: index, used: used))
            await fixture.lifecycle.sampleNow()
            XCTAssertEqual(model.growthSummary, expected)
            XCTAssertEqual(fixture.lifecycle.latestGrowthAlert, alert)
            XCTAssertEqual(model.observation?.snapshot.snapshotID, "volume-\(index)")
            XCTAssertTrue(model.evidenceFreshnessSummary.contains(fixtureDetailDate), "Detail freshness must not follow capacity")
        }
        let delivered = await fixture.delivery.values
        XCTAssertEqual(delivered.count, 1)

        let restarted = VolumeFixture()
        defer { restarted.lifecycle.shutdown() }
        await restarted.lifecycle.sampleNow()
        XCTAssertNil(restarted.lifecycle.latestGrowthAlert)
        XCTAssertNil(restarted.lifecycle.latestObservation?.capacity?.comparison)
    }

    func testVolumeIdentitySelectionUnknownAndNonComparableSamples() throws {
        let first = volumeObservation(index: 0)
        let same = volumeObservation(index: 1, used: 581_000_000_000).comparingCapacity(after: first)
        XCTAssertEqual(same.capacity?.comparison?.usedByteDelta, 1_000_000_000)
        XCTAssertEqual(same.capacity?.volume.mountPath, "/System/Volumes/Data")
        // Fixture includes a lexically earlier external volume with a radically
        // different usage: UI and alerts must choose the internal writable disk.
        XCTAssertEqual(same.capacity?.volume.totalBytes, 1_000_000_000_000)
        for current in [
            volumeObservation(index: 1, identity: "UUID-B"),
            volumeObservation(index: 1, identity: nil),
            volumeObservation(index: 1, total: 2_000_000_000_000),
            volumeObservation(index: 1, path: "/different"),
            volumeObservation(index: 0),
            volumeObservation(index: -1),
        ] {
            XCTAssertNil(current.comparingCapacity(after: first).capacity?.comparison)
        }
    }

    func testFailureAndPauseResumeRebaselineWithoutFresheningDetail() async throws {
        let fixture = VolumeFixture()
        defer { fixture.lifecycle.shutdown() }
        let model = StatusBoardViewModel(lifecycle: fixture.lifecycle)
        await fixture.lifecycle.sampleNow()
        await fixture.probe.set(volumeObservation(index: 1, used: 581_000_000_000))
        await fixture.lifecycle.sampleNow()
        XCTAssertEqual(model.growthSummary, "+1 GB")
        await fixture.probe.failNext()
        await fixture.lifecycle.sampleNow()
        XCTAssertEqual(fixture.lifecycle.status.kind, .degraded)
        XCTAssertTrue(model.sampleStateSummary.contains("stale"))
        XCTAssertEqual(model.observation?.snapshot.snapshotID, "volume-1")
        await fixture.probe.set(volumeObservation(index: 2, used: 582_000_000_000))
        await fixture.lifecycle.sampleNow()
        XCTAssertEqual(fixture.lifecycle.status.kind, .recovered)
        XCTAssertNil(model.growthDelta, "First sample after failure establishes a new baseline")

        fixture.lifecycle.pause()
        XCTAssertTrue(model.sampleStateSummary.contains("Paused"))
        let before = await fixture.probe.calls
        model.refresh()
        await fixture.lifecycle.sampleNow()
        let afterPaused = await fixture.probe.calls
        XCTAssertEqual(afterPaused, before)
        await fixture.probe.set(volumeObservation(index: 3, used: 583_000_000_000))
        fixture.lifecycle.resume()
        try await eventually { model.observation?.snapshot.snapshotID == "volume-3" && !fixture.lifecycle.isSampling }
        XCTAssertNil(model.growthDelta, "Resume begins a new baseline")
        XCTAssertTrue(model.evidenceFreshnessSummary.contains(fixtureDetailDate))
        let drained = await fixture.lifecycle.shutdownAndDrain()
        XCTAssertTrue(drained)
    }

    func testRefreshIsRealSingleFlightCoalescedAndFencedBySleepAndQuit() async throws {
        let fixture = VolumeFixture()
        defer { fixture.lifecycle.shutdown() }
        let model = StatusBoardViewModel(lifecycle: fixture.lifecycle)
        await fixture.probe.hold()
        model.refresh()
        XCTAssertTrue(fixture.lifecycle.isSampling)
        XCTAssertTrue(model.sampleStateSummary.contains("Sampling"))
        for _ in 0..<50 { model.refresh() }
        try await eventually { await fixture.probe.calls == 1 }
        await fixture.probe.release()
        try await eventually { await fixture.probe.calls == 2 && !fixture.lifecycle.isSampling }
        let peak = await fixture.probe.peakActive
        XCTAssertEqual(peak, 1)
        XCTAssertNotNil(model.snapshot)

        fixture.lifecycle.prepareForSystemSleep()
        for _ in 0..<10 { model.refresh() }
        await fixture.lifecycle.sampleNow()
        let sleepingCalls = await fixture.probe.calls
        XCTAssertEqual(sleepingCalls, 2)
        fixture.lifecycle.shutdown()
        model.refresh()
        await fixture.lifecycle.sampleNow()
        let stoppedCalls = await fixture.probe.calls
        XCTAssertEqual(stoppedCalls, 2)
        let drained = await fixture.lifecycle.shutdownAndDrain()
        XCTAssertTrue(drained)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Fixture did not reach the expected state within one second")
        throw VolumeFixtureError.timeout
    }

    private var fixtureDetailDate: String {
        Date(timeIntervalSince1970: 1_789_862_400 - 7 * 86_400).formatted(date: .abbreviated, time: .shortened)
    }
}

@MainActor
private final class VolumeFixture {
    let probe: VolumeSequenceProbe
    let delivery = VolumeRecordingDelivery()
    let lifecycle: MonitoringLifecycleController
    init(pendingChanges: Bool = false) {
        probe = VolumeSequenceProbe(pendingChanges: pendingChanges)
        let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        settings.update { $0.growthThresholdMiB = 2_000 }
        lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: delivery, changeCollector: nil)
    }
}

private actor VolumeRecordingDelivery: MonitoringNotificationDelivering {
    var values: [MonitoringNotification] = []
    private var held = false
    func hold() { held = true }
    func deliver(_ notification: MonitoringNotification) async {
        values.append(notification)
        for _ in 0..<200 {
            if !held || Task.isCancelled { return }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
    }
}

private enum VolumeFixtureError: Error { case sample, timeout }

private actor VolumeSequenceProbe: MonitoringProbing {
    nonisolated let changeInbox: MonitoringChangeInbox?
    var calls = 0
    var peakActive = 0
    private var active = 0
    private var held = false
    private var shouldFail = false
    private var observation = volumeObservation(index: 0)
    init(pendingChanges: Bool) { changeInbox = pendingChanges ? MonitoringChangeInbox() : nil }
    func persistPendingChanges() async throws {
        if let receipt = changeInbox?.snapshot() { changeInbox?.acknowledge(receipt) }
    }
    func set(_ value: MonitoringObservation) { observation = value }
    func hold() { held = true }
    func release() { held = false }
    func failNext() { shouldFail = true }
    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        calls += 1
        active += 1
        peakActive = max(peakActive, active)
        defer { active -= 1 }
        for _ in 0..<200 {
            if !held { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        if held { throw VolumeFixtureError.timeout }
        if shouldFail { shouldFail = false; throw VolumeFixtureError.sample }
        return observation
    }
}

private func volumeObservation(index: Int, used: Int64 = 580_000_000_000, identity: String? = "UUID-A", total: Int64 = 1_000_000_000_000, path: String = "/System/Volumes/Data") -> MonitoringObservation {
    let date = Date(timeIntervalSince1970: 1_789_862_400 + Double(index) * 60)
    var evidence = EvidenceLifecycleStatus(observedAt: date, tiers: [], databaseBytes: 1, databaseCapBytes: 10,
        lastCompaction: nil, totalForcedEvictions: 0, currentStateCount: 3, currentStateAllocatedBytes: 10,
        exportInventory: [], observationGaps: [], retentionGaps: [])
    evidence.scanCoverage = .init(configuredRoots: [], excludedPaths: [], detailCoverage: "partial",
        activeGeneration: nil, latestGeneration: nil, lastCompleteGenerationAt: date.addingTimeInterval(-7 * 86_400 - Double(index) * 60))
    return MonitoringObservation(observedAt: date, snapshot: StorageSnapshot(snapshotID: "volume-\(index)",
        observedAt: VolumeSnapshotService.timestamp(date), volumes: [
            .init(mountPath: "/External", totalBytes: 100_000_000_000, availableBytes: 1, isInternal: false, isReadOnly: false),
            .init(mountPath: path, totalBytes: total, availableBytes: total - used, isInternal: true, isReadOnly: false),
        ]), detailedEvents: [], growthReport: GrowthExplanationEngine().explain(volumeUsedDelta: 999, detailedEvents: []),
        evidenceLifecycle: evidence, needsScanContinuation: true, volumeIdentity: identity)
}
