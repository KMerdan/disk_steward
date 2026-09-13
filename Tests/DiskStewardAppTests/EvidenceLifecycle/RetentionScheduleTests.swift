import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

final class RetentionScheduleTests: XCTestCase {
    func testStartupSixHourAndPressureSchedulingBoundaries() {
        let now = Date(timeIntervalSince1970: 2_100_000_000)
        let cap: Int64 = 512 * 1_024 * 1_024
        let schedule = RetentionSchedule()

        XCTAssertEqual(schedule.trigger(lastRunAt: nil, now: now, databaseBytes: 0, capBytes: cap), .startup)
        XCTAssertNil(schedule.trigger(lastRunAt: now.addingTimeInterval(-21_599), now: now, databaseBytes: cap / 2, capBytes: cap))
        XCTAssertEqual(schedule.trigger(lastRunAt: now.addingTimeInterval(-21_600), now: now, databaseBytes: cap / 2, capBytes: cap), .scheduled)
        XCTAssertEqual(schedule.trigger(lastRunAt: now.addingTimeInterval(-60), now: now, databaseBytes: Int64(Double(cap) * 0.9), capBytes: cap), .pressure)
    }
}
