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

    func testPersistentProbeStoresScheduledSnapshotAndDetailedDelta() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        let probe = try PersistentMonitoringProbe(databaseURL: database)

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
