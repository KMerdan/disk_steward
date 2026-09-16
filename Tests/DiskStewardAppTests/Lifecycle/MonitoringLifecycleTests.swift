import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

@MainActor
final class MonitoringLifecycleTests: XCTestCase {
    func testDegradedSampleRecoversAndHistoryExplainsBothStates() async {
        let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        let probe = FailingThenHealthyProbe()
        let delivery = RecordingDelivery()
        let lifecycle = MonitoringLifecycleController(settingsStore: store, probe: probe, notificationDelivery: delivery, changeCollector: nil)

        await lifecycle.sampleNow()
        XCTAssertEqual(lifecycle.status.kind, .degraded)
        XCTAssertTrue(lifecycle.status.accessibilitySummary.contains("Sampling failed"))

        await lifecycle.sampleNow()
        XCTAssertEqual(lifecycle.status.kind, .recovered)
        XCTAssertTrue(lifecycle.status.accessibilitySummary.contains("healthy again"))
        XCTAssertEqual(lifecycle.history.map(\.kind).prefix(2), [.recovered, .degraded])
    }

    func testPauseAndResumePersistUserChoice() {
        let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        let lifecycle = MonitoringLifecycleController(settingsStore: store, probe: AlwaysHealthyProbe(), changeCollector: nil)

        lifecycle.pause()
        XCTAssertEqual(lifecycle.status.kind, .paused)
        XCTAssertTrue(store.settings.monitoringPaused)

        lifecycle.resume()
        XCTAssertFalse(store.settings.monitoringPaused)
        XCTAssertNotEqual(lifecycle.status.kind, .paused)
        lifecycle.pause()
    }

    func testSystemSleepSuspendsWithoutChangingUserChoiceAndWakeRefreshes() async throws {
        let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        let probe = SlowCountingProbe()
        let lifecycle = MonitoringLifecycleController(
            settingsStore: store,
            probe: probe,
            changeCollector: nil,
            safetyState: MonitoringSafetyStateStore(
                persistence: EphemeralSettingsPersistence(),
                key: "sleep-wake"
            )
        )

        lifecycle.prepareForSystemSleep()
        XCTAssertEqual(lifecycle.status.title, "Sleeping")
        XCTAssertFalse(store.settings.monitoringPaused)

        lifecycle.resumeAfterSystemWake()
        XCTAssertEqual(lifecycle.status.title, "Waking")
        try await Task.sleep(for: .milliseconds(180))
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(store.settings.monitoringPaused)
        lifecycle.pause()
    }

    func testInterruptedSampleStartsInSafetyPauseUntilUserResumes() {
        let persistence = EphemeralSettingsPersistence()
        let settings = MonitoringSettingsStore(persistence: persistence)
        let safety = MonitoringSafetyStateStore(persistence: persistence, key: "safety")
        safety.markSampleStarted(at: Date(timeIntervalSince1970: 100))

        let lifecycle = MonitoringLifecycleController(
            settingsStore: settings,
            probe: AlwaysHealthyProbe(),
            changeCollector: nil,
            safetyState: safety
        )

        XCTAssertEqual(lifecycle.status.kind, .degraded)
        XCTAssertTrue(lifecycle.status.detail.contains("previous detailed sample did not finish"))
        XCTAssertTrue(settings.settings.monitoringPaused)

        lifecycle.resume()
        XCTAssertFalse(settings.settings.monitoringPaused)
        XCTAssertFalse(safety.hasInterruptedSample)
        lifecycle.pause()
    }

    func testConcurrentSampleRequestsAreSingleFlightAndCoalesced() async throws {
        let persistence = EphemeralSettingsPersistence()
        let settings = MonitoringSettingsStore(persistence: persistence)
        let probe = SlowCountingProbe()
        let lifecycle = MonitoringLifecycleController(
            settingsStore: settings,
            probe: probe,
            changeCollector: nil,
            safetyState: MonitoringSafetyStateStore(persistence: persistence, key: "single-flight")
        )

        let first = Task { await lifecycle.sampleNow() }
        try await Task.sleep(for: .milliseconds(20))
        await lifecycle.sampleNow()
        await first.value
        try await Task.sleep(for: .milliseconds(180))

        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testResourceCircuitBreakerStopsBeforeFilesystemTraversalAndHistoryIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = ResourceBudget(maximumResidentBytes: 32 * 1_024 * 1_024)
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceBudget: budget,
            resourceMeasurementSource: { _, underLoad in
                ResourceMeasurement(
                    cpuPercent: 0,
                    residentBytes: 64 * 1_024 * 1_024,
                    databaseBytes: 0,
                    pendingEvents: 0,
                    receivedEvents: 0,
                    droppedEvents: 0,
                    underLoad: underLoad
                )
            }
        )

        for _ in 0 ..< 125 {
            do {
                _ = try await probe.sample(settings: .defaults)
                XCTFail("Expected the safety circuit breaker to stop the sample")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("circuit breaker"))
            }
        }

        let historyCount = await probe.boundedResourceHistory().count
        XCTAssertEqual(historyCount, 120)
    }

    func testPersistentProbeCapsOneSafetySliceToARepresentableBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 600 {
            FileManager.default.createFile(atPath: watched.appending(path: "item-\(index)").path, contents: Data())
        }
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024)
        )

        _ = try await probe.sample(settings: settings)
        let reader = try EvidenceStore(url: database)
        let coverage = try await reader.scanCoverageStatus()
        XCTAssertEqual(coverage?.activeGeneration?.processedEntryCount, PersistentMonitoringProbe.maximumEntriesPerSafetySlice)
        XCTAssertEqual(coverage?.detailCoverage, "partial")
        await reader.close()
    }

    func testPersistentProbeStoresScheduledSnapshotAndDetailedDelta() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024)
        )

        _ = try await probe.sample(settings: settings)
        try Data(repeating: 4, count: 8_192).write(to: watched.appending(path: "growth.bin"))
        let second = try await probe.sample(settings: settings)

        XCTAssertEqual(second.detailedEvents.count, 1)
        XCTAssertEqual(second.detailedEvents.first?.operation, .create)
        let reader = try EvidenceStore(url: database)
        let eventCount = try await reader.eventCount()
        let diagnostics = try await reader.diagnostics()
        XCTAssertEqual(eventCount, 1)
        XCTAssertGreaterThanOrEqual(diagnostics.snapshotCount, 2)
        XCTAssertEqual(diagnostics.integrity, "ok")
        await reader.close()
    }
}

private struct FixtureError: Error {}

private actor FailingThenHealthyProbe: MonitoringProbing {
    private var calls = 0

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        calls += 1
        if calls == 1 { throw FixtureError() }
        return fixtureObservation(used: 750, total: 1_000, growth: 0)
    }
}

private struct AlwaysHealthyProbe: MonitoringProbing {
    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        fixtureObservation(used: 750, total: 1_000, growth: 0)
    }
}

private actor SlowCountingProbe: MonitoringProbing {
    private(set) var callCount = 0

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        callCount += 1
        try await Task.sleep(for: .milliseconds(100))
        return fixtureObservation(used: 750, total: 1_000, growth: 0)
    }
}

private actor RecordingDelivery: MonitoringNotificationDelivering {
    private(set) var notifications: [MonitoringNotification] = []
    func deliver(_ notification: MonitoringNotification) async { notifications.append(notification) }
}

private func fixtureObservation(used: Int64, total: Int64, growth: Int64) -> MonitoringObservation {
    let snapshot = StorageSnapshot(
        snapshotID: UUID().uuidString,
        observedAt: "2026-09-13T00:00:00.000Z",
        volumes: [.init(mountPath: "/", totalBytes: total, availableBytes: total - used, isInternal: true, isReadOnly: false)]
    )
    let report = GrowthExplanationEngine().explain(volumeUsedDelta: growth, detailedEvents: [])
    return MonitoringObservation(observedAt: Date(), snapshot: snapshot, detailedEvents: [], growthReport: report)
}
