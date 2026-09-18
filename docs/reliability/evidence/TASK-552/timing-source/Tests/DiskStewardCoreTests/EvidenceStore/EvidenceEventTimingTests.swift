import Foundation
import XCTest
@testable import DiskStewardCore

final class EvidenceEventTimingTests: XCTestCase, @unchecked Sendable {
    func testLegacyEventPayloadDecodesWithoutInventingTiming() throws {
        let data = Data(#"{"eventID":"legacy","observedAt":10,"operation":"create","path":"/synthetic/file","logicalDelta":1,"allocatedDelta":1,"consumerCategory":"test","confidence":"unknown","isAnomaly":false,"isReviewed":false}"#.utf8)
        let event = try JSONDecoder().decode(EvidenceStoreEvent.self, from: data)
        XCTAssertNil(event.timing)
        let record = EvidenceEventTimingPresentation(timing: event.timing)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(json["basis"] as? String, "unverified")
        for key in ["occurred_start", "occurred_end", "detected_at"] { XCTAssertTrue(json[key] is NSNull) }
    }

    func testStandaloneInsertCannotSilentlyDropSuppliedTiming() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appending(path: "evidence.sqlite"))
        let event = EvidenceStoreEvent(eventID: "timed", observedAt: Date(timeIntervalSince1970: 100),
            operation: .create, path: "/synthetic/file", logicalDelta: 1, allocatedDelta: 1,
            consumerCategory: "test", confidence: .unknown).withTiming(.init(
                occurredStart: nil, occurredEnd: Date(timeIntervalSince1970: 100), detectedAt: Date(timeIntervalSince1970: 200)))
        do {
            try await store.insert(event)
            XCTFail("Standalone insert has no observation evidence to support supplied timing")
        } catch EvidenceStoreError.invalidEvent { }
        let events = try await store.events(from: Date(timeIntervalSince1970: 0), through: Date(timeIntervalSince1970: 300))
        XCTAssertTrue(events.isEmpty)
        await store.close()
    }
}
