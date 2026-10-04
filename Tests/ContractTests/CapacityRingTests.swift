@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-651: capacity history in its own bounded file.
final class CapacityRingTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appending(path: "capacity.sqlite") }
    private let gib: Int64 = 1_073_741_824

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ring-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testSamplesAreKeptPerIntervalAndSurviveRelaunch() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let ring = try CapacityRing(url: url)
        var fineWrites = 0
        // Every 5 minutes for 3 hours, plus an on-demand sample 1 minute after each.
        for step in 0..<36 {
            let at = start.addingTimeInterval(Double(step) * CapacityRing.fineInterval)
            if try await ring.record(volumeUUID: "UUID-A", mountPath: "/", totalBytes: 1_000 * gib, availableBytes: (500 - Int64(step)) * gib, at: at) { fineWrites += 1 }
            _ = try await ring.record(volumeUUID: "UUID-A", mountPath: "/", totalBytes: 1_000 * gib, availableBytes: 1, at: at.addingTimeInterval(60))
        }
        let recent = try await ring.recent(volumeUUID: "UUID-A", limit: 1_000)
        XCTAssertEqual(recent.total, 36, "on-demand samples inside a fine interval do not add rows")
        XCTAssertEqual(recent.items.first?.availableBytes, (500 - 35) * gib, "newest first")
        let summary = try await ring.summary(volumeUUID: "UUID-A", now: start.addingTimeInterval(3 * 3_600))
        let hours = Set((0..<36).map { Int((start.timeIntervalSince1970 + Double($0) * CapacityRing.fineInterval) / CapacityRing.hourlyInterval) }).count
        XCTAssertEqual(summary.sampleCount, 36 + hours, "36 fine rows plus one per clock hour")
        let mounted = try await ring.volumeUUID(mountPath: "/")
        XCTAssertEqual(mounted, "UUID-A")
        await ring.close()

        let reopened = try CapacityRing(url: url)
        let afterRelaunch = try await reopened.summary(volumeUUID: "UUID-A", now: start.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(afterRelaunch.sampleCount, summary.sampleCount, "history survives relaunch")
        XCTAssertEqual(afterRelaunch.newest?.availableBytes, (500 - 35) * gib)
        await reopened.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"), "the ring uses a rollback journal")
    }

    func testOneVolumeKeepsAWeekOfFineAndAYearOfHourlyUnderOneMiB() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let ring = try CapacityRing(url: url)
        // A year and a day of hourly samples, then two weeks of 5-minute samples.
        let hours = 366 * 24
        for hour in 0..<hours {
            _ = try await ring.record(volumeUUID: "UUID-A", mountPath: "/", totalBytes: 1_000 * gib,
                                      availableBytes: Int64(hour) * 1_000, at: start.addingTimeInterval(Double(hour) * 3_600))
        }
        let fineStart = start.addingTimeInterval(Double(hours) * 3_600)
        for step in 0..<(14 * 288) {
            _ = try await ring.record(volumeUUID: "UUID-A", mountPath: "/", totalBytes: 1_000 * gib,
                                      availableBytes: Int64(step), at: fineStart.addingTimeInterval(Double(step) * CapacityRing.fineInterval))
        }
        let now = fineStart.addingTimeInterval(Double(14 * 288 - 1) * CapacityRing.fineInterval)
        let recent = try await ring.recent(volumeUUID: "UUID-A", limit: 10_000)
        XCTAssertLessThanOrEqual(recent.total, 2_017, "7 days of 5-minute samples")
        XCTAssertGreaterThanOrEqual(recent.total, 2_015)
        let summary = try await ring.summary(volumeUUID: "UUID-A", now: now)
        XCTAssertLessThanOrEqual(summary.sampleCount - recent.total, 8_761, "one year of hourly samples")
        XCTAssertGreaterThan(summary.sampleCount - recent.total, 8_700)
        await ring.close()
        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        print("CAPACITY-RING-ONE-VOLUME-BYTES", bytes)
        XCTAssertLessThan(bytes, 1_024 * 1_024, "one volume's year fits in under 1 MiB")
    }
}
