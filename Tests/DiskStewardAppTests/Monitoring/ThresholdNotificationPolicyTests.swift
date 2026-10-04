import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

final class ThresholdNotificationPolicyTests: XCTestCase {
    private let gib = MonitoringSettings.gibibyte
    private let total: Int64 = 1_000 * MonitoringSettings.gibibyte

    /// TASK-651: one alert when free space is below the reserve on two
    /// comparable samples; no repeat until it recovers above reserve plus
    /// hysteresis (max of 1 GiB and 5% of the reserve, here 5 GiB).
    func testReserveAlertNeedsTwoComparableSamplesAndRecoversWithHysteresis() {
        var settings = MonitoringSettings.defaults
        settings.comfortReserveGiB = 100
        settings.growthThresholdMiB = 1_048_576
        var policy = ThresholdNotificationPolicy()
        func alerts(free: Int64, comparable: Bool = true) -> [MonitoringNotification] {
            policy.evaluate(observation: observation(freeGiB: free, comparable: comparable), settings: settings)
                .filter { $0.title.contains("reserve") }
        }
        XCTAssertTrue(alerts(free: 90, comparable: false).isEmpty, "a first sample below the reserve is not enough")
        let fired = alerts(free: 89)
        XCTAssertEqual(fired.count, 1)
        XCTAssertTrue(fired[0].title.contains("below your"), fired[0].title)
        XCTAssertTrue(fired[0].body.contains("two samples in a row"), fired[0].body)
        XCTAssertTrue(alerts(free: 88).isEmpty, "no repeat while still below")
        XCTAssertTrue(alerts(free: 103).isEmpty, "above the reserve but inside the hysteresis band")
        XCTAssertTrue(alerts(free: 95).isEmpty)
        XCTAssertTrue(alerts(free: 94).isEmpty, "not re-armed without recovering past the band")
        XCTAssertTrue(alerts(free: 106).isEmpty, "recovery past reserve plus hysteresis re-arms silently")
        XCTAssertTrue(alerts(free: 90).isEmpty)
        XCTAssertEqual(alerts(free: 89).count, 1, "a new crossing alerts again")
    }

    func testANonComparableSampleRestartsTheCount() {
        var settings = MonitoringSettings.defaults
        settings.comfortReserveGiB = 100
        var policy = ThresholdNotificationPolicy()
        _ = policy.evaluate(observation: observation(freeGiB: 90, comparable: false), settings: settings)
        let afterBreak = policy.evaluate(observation: observation(freeGiB: 89, comparable: false), settings: settings)
        XCTAssertTrue(afterBreak.filter { $0.title.contains("reserve") }.isEmpty, "two samples must be comparable")
    }

    func testSuggestedReserveIsMigratedFromThePercentageThreshold() {
        // The maintainer's 994.7 GB disk with the old 90% threshold.
        XCTAssertEqual(MonitoringSettings.suggestedReserveGiB(totalBytes: 994_662_584_320, capacityThresholdPercent: 90), 93)
        var settings = MonitoringSettings.defaults
        XCTAssertNil(settings.comfortReserveGiB)
        XCTAssertEqual(settings.reserveBytes(totalBytes: total), 100 * gib)
        settings.comfortReserveGiB = 250
        XCTAssertEqual(settings.reserveBytes(totalBytes: total), 250 * gib)
        settings.comfortReserveGiB = 0
        settings.normalize()
        XCTAssertEqual(settings.comfortReserveGiB, 1)
    }

    func testGrowthAlertKeepsItsEvidenceMessage() {
        var settings = MonitoringSettings.defaults
        settings.comfortReserveGiB = 1
        settings.growthThresholdMiB = 100
        var policy = ThresholdNotificationPolicy()
        let notifications = policy.evaluate(observation: observation(freeGiB: 500, growthMiB: 200), settings: settings)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertTrue(notifications[0].body.contains("attribution confidence"))
    }

    private func observation(freeGiB: Int64, growthMiB: Int64 = 0, comparable: Bool = true) -> MonitoringObservation {
        let available = freeGiB * gib
        let snapshot = StorageSnapshot(
            snapshotID: UUID().uuidString, observedAt: "2026-09-13T00:00:00.000Z",
            volumes: [.init(mountPath: "/", totalBytes: total, availableBytes: available, isInternal: true, isReadOnly: false)]
        )
        let report = GrowthExplanationEngine().explain(volumeUsedDelta: growthMiB * 1_024 * 1_024, detailedEvents: [])
        let current = MonitoringObservation(observedAt: Date(), snapshot: snapshot, detailedEvents: [], growthReport: report,
                                            volumeIdentity: "fixture-volume")
        guard comparable else { return current }
        let previous = MonitoringObservation(observedAt: Date(), snapshot: StorageSnapshot(
            snapshotID: "previous", observedAt: "2026-09-12T23:59:00.000Z",
            volumes: [.init(mountPath: "/", totalBytes: total, availableBytes: available + growthMiB * 1_024 * 1_024,
                            isInternal: true, isReadOnly: false)]
        ), detailedEvents: [], growthReport: report, volumeIdentity: "fixture-volume")
        return current.comparingCapacity(after: previous)
    }
}
