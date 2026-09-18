import Foundation
import XCTest
@testable import DiskStewardCore

final class TaskImpactCandidateTests: XCTestCase, @unchecked Sendable {
    func testBudgetsRejectBeforeDecodingAndNeverReturnPartialCandidates() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "impact-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appending(path: "fixture.sqlite"))
        for id in ["a", "b"] {
            let event = event(id)
            try await store.insert(event)
            try await store.persistProvenanceClaim(claim(event, id: id, lower: 10, upper: 20, detected: 200))
        }
        for (rows, bytes) in [(1, 8192), (2, 1)] {
            do {
                _ = try await store.taskImpactCandidates(from: date(15), through: date(16), maximumRows: rows, maximumBytes: bytes)
                XCTFail("A budget ceiling must not silently return incomplete totals")
            } catch TaskImpactQueryError.budgetExceeded { }
        }
        let all = try await store.taskImpactCandidates(from: date(15), through: date(16), maximumRows: 2, maximumBytes: 8192)
        XCTAssertEqual(all.map(\.event.eventID), ["a", "b"])
        XCTAssertTrue(all.allSatisfy { $0.currentClaim != nil })
        await store.close()
    }

    func testNewestClaimIsSelectedBeforeOverlapSoOldBoundsAreNotResurrected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "impact-current-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appending(path: "fixture.sqlite"))
        let event = event("event")
        try await store.insert(event)
        try await store.persistProvenanceClaim(claim(event, id: "old", lower: 10, upper: 20, detected: 200))
        try await store.persistProvenanceClaim(claim(event, id: "new", lower: 30, upper: 40, detected: 300))
        let earlier = try await store.taskImpactCandidates(from: date(15), through: date(16))
        XCTAssertTrue(earlier.isEmpty)
        let later = try await store.taskImpactCandidates(from: date(35), through: date(36))
        XCTAssertEqual(later.count, 1)
        XCTAssertEqual(later.first?.currentClaim?.claimID, "new")
        await store.close()
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
    private func event(_ id: String) -> EvidenceStoreEvent {
        .init(eventID: id, observedAt: date(100), operation: .writeSummary, path: "/fixture/\(id)",
            logicalDelta: 1, allocatedDelta: 1, consumerCategory: "fixture", confidence: .unknown)
    }
    private func claim(_ event: EvidenceStoreEvent, id: String, lower: Double, upper: Double, detected: Double) -> ProvenanceClaim {
        .init(event: event, actor: nil, session: nil, confidence: .unknown, method: "fixture",
            support: [], limitations: [], claimID: id, detectedAt: date(detected),
            occurredStart: date(lower), occurredEnd: date(upper))
    }
}
