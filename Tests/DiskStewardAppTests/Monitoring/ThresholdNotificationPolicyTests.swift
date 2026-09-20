import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

final class ThresholdNotificationPolicyTests: XCTestCase {
    func testNotificationFiresOnCrossingButNotEveryUnchangedSample() {
        var settings = MonitoringSettings.defaults
        settings.capacityThresholdPercent = 80
        settings.growthThresholdMiB = 1_000
        var policy = ThresholdNotificationPolicy()

        XCTAssertEqual(policy.evaluate(observation: observation(percent: 81), settings: settings).count, 1)
        XCTAssertTrue(policy.evaluate(observation: observation(percent: 85), settings: settings).isEmpty)
        XCTAssertTrue(policy.evaluate(observation: observation(percent: 70), settings: settings).isEmpty)
        XCTAssertEqual(policy.evaluate(observation: observation(percent: 82), settings: settings).count, 1)
    }

    func testCapacityAndGrowthCrossingsHaveDistinctEvidenceMessages() {
        var settings = MonitoringSettings.defaults
        settings.capacityThresholdPercent = 80
        settings.growthThresholdMiB = 100
        var policy = ThresholdNotificationPolicy()

        let notifications = policy.evaluate(observation: observation(percent: 90, growthMiB: 200), settings: settings)

        XCTAssertEqual(notifications.count, 2)
        XCTAssertTrue(notifications.contains { $0.title.contains("90%") })
        XCTAssertTrue(notifications.contains { $0.body.contains("attribution confidence") })
    }

    private func observation(percent: Int, growthMiB: Int64 = 0) -> MonitoringObservation {
        let total: Int64 = 1_000_000_000_000
        let used = Int64(percent) * (total / 100)
        let snapshot = StorageSnapshot(
            snapshotID: UUID().uuidString,
            observedAt: "2026-09-13T00:00:00.000Z",
            volumes: [.init(mountPath: "/", totalBytes: total, availableBytes: total - used, isInternal: true, isReadOnly: false)]
        )
        let report = GrowthExplanationEngine().explain(
            volumeUsedDelta: growthMiB * 1_024 * 1_024,
            detailedEvents: []
        )
        let previous = MonitoringObservation(observedAt: Date(), snapshot: StorageSnapshot(
            snapshotID: "previous", observedAt: "2026-09-12T23:59:00.000Z",
            volumes: [.init(mountPath: "/", totalBytes: total,
                availableBytes: total - used + growthMiB * 1_024 * 1_024, isInternal: true, isReadOnly: false)]
        ), detailedEvents: [], growthReport: report, volumeIdentity: "fixture-volume")
        return MonitoringObservation(observedAt: Date(), snapshot: snapshot, detailedEvents: [], growthReport: report,
            volumeIdentity: "fixture-volume").comparingCapacity(after: previous)
    }
}
