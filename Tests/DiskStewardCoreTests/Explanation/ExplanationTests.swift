import Foundation
import XCTest
@testable import DiskStewardCore

final class ExplanationTests: XCTestCase {
    func testExplanationSeparatesDetailedAndUnexplainedGrowth() {
        let report = GrowthExplanationEngine().explain(
            volumeUsedDelta: 1_000,
            detailedEvents: [
                event(path: "/watched/build.bin", delta: 300, category: "developer-cache", confidence: .inferred),
                event(path: "/watched/download.dmg", delta: 200, category: "downloads", confidence: .exact),
                event(path: "/watched/deleted.bin", delta: -50, category: "downloads", confidence: .exact),
            ],
            scopeLimitations: ["Only configured roots receive file detail."]
        )

        XCTAssertEqual(report.detailedPositiveDelta, 500)
        XCTAssertEqual(report.unexplainedDelta, 500)
        XCTAssertEqual(report.causes.last?.category, "unexplained")
        XCTAssertEqual(report.causes.last?.confidence, .unknown)
        XCTAssertTrue(report.limitations.contains { $0.contains("configured roots") })
        XCTAssertTrue(report.limitations.contains { $0.contains("exceeds observed") })
    }

    func testEventGapWeakensEveryDetailedCauseAndIsExplicit() {
        let report = GrowthExplanationEngine().explain(
            volumeUsedDelta: 100,
            detailedEvents: [event(path: "/watched/exact.bin", delta: 100, category: "agent-artifact", confidence: .exact)],
            eventGap: true
        )

        XCTAssertEqual(report.causes.first?.confidence, .unknown)
        XCTAssertEqual(report.causes.first?.method, "observation-gap")
        XCTAssertTrue(report.limitations.contains { $0.contains("FSEvents reported a gap") })
    }

    func testObservedDetailCannotCreateNegativeUnexplainedGrowth() {
        let report = GrowthExplanationEngine().explain(
            volumeUsedDelta: 50,
            detailedEvents: [event(path: "/watched/race.bin", delta: 75, category: "watched-root", confidence: .inferred)]
        )

        XCTAssertEqual(report.unexplainedDelta, 0)
        XCTAssertFalse(report.causes.contains { $0.category == "unexplained" })
    }

    private func event(
        path: String,
        delta: Int64,
        category: String,
        confidence: EvidenceStoreEvent.Confidence
    ) -> EvidenceStoreEvent {
        EvidenceStoreEvent(
            eventID: UUID().uuidString,
            observedAt: Date(timeIntervalSince1970: 1_000),
            operation: .snapshotDelta,
            path: path,
            logicalDelta: delta,
            allocatedDelta: delta,
            consumerCategory: category,
            confidence: confidence
        )
    }
}
