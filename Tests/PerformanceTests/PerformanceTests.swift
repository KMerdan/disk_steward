import Foundation
import XCTest
@testable import DiskStewardCore
@testable import DiskStewardEndpoint

final class PerformanceTests: XCTestCase {
    func testSustainedEventStormRemainsBoundedAndReportsEveryDrop() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let process = ProcessIdentity(pid: 88, startTime: start.addingTimeInterval(-1), executablePath: "/bin/tool")
        var buffer = BoundedEndpointEventBuffer(maximumEvents: 512, maximumEstimatedBytes: 256 * 1_024, coalescingWindow: 0.01)
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for index in 0 ..< 100_000 {
                let path = "/Users/example/work/item-\(index).bin"
                let raw = RawPrivilegedNotification(
                    eventID: "storm-\(index)", streamID: "load", sequence: UInt64(index + 1),
                    observedAt: start.addingTimeInterval(Double(index) / 1_000), operation: .create,
                    path: path, process: process,
                    fileIdentity: .init(volumeID: "data", fileID: UInt64(index + 1)),
                    size: .init(logicalBefore: 0, logicalAfter: 1, allocatedBefore: 0, allocatedAfter: 4_096, method: "fstat")
                )
                let event = try XCTUnwrap(EndpointEventNormalizer().normalize(raw, scope: .init(watchedRoots: ["/Users/example/work"], excludedRoots: []), gapBefore: false))
                _ = buffer.append(event)
            }
        }
        XCTAssertLessThanOrEqual(buffer.count, 512)
        XCTAssertEqual(buffer.count + buffer.droppedEvents, 100_000)
        XCTAssertTrue(buffer.hasGap)
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    func testResourceHistoryAndDatabaseBudgetStayBounded() {
        var history = BoundedResourceHistory(capacity: 60)
        for index in 0 ..< 10_000 {
            history.append(.init(cpuPercent: 2, residentBytes: 50_000_000, databaseBytes: Int64(index), pendingEvents: 4, receivedEvents: index, droppedEvents: 0, underLoad: true))
        }
        XCTAssertEqual(history.samples.count, 60)
        let assessment = ResourceBudgetEvaluator().assess(history.samples.last!, against: ResourceBudget())
        XCTAssertTrue(assessment.withinBudget)
        XCTAssertFalse(assessment.backpressureRequired)
    }
}
