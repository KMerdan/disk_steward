import Foundation
import XCTest
@testable import DiskStewardCore

final class UnknownOccurrenceTests: XCTestCase, @unchecked Sendable {
    func testExportChoosesNewestClaimByDetectionNotByOccurrenceUpperBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("evidence.sqlite"))
        let event = makeEvent()
        try await store.insert(event)
        for (id, end, detected) in [("older-claim", 150.0, 200.0), ("newer-claim", 100.0, 300.0)] {
            try await store.persistProvenanceClaim(.init(
                event: event, actor: nil, session: nil, confidence: .unknown,
                method: id, support: [], limitations: [], claimID: id,
                detectedAt: date(detected), occurredEnd: date(end)))
        }
        let exported = try await EvidenceBundleExporter(identifierSource: { "claim-choice" }).export(
            store: store, options: .init(from: date(0), through: date(500), pathDetail: .basename),
            to: root.appendingPathComponent("exports"))
        let bytes = try ZlibCodec.decompress(Data(contentsOf: exported.bundleURL.appendingPathComponent("events.jsonl.zlib")))
        let line = try XCTUnwrap(String(decoding: bytes, as: UTF8.self).split(separator: "\n").first)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(value.objectValue?["attribution"]?.objectValue?["method"], .string("newer-claim"))
        await store.close()
    }

    func testMissingLowerBoundDoesNotTurnDiscoveryIntoCreationOrTaskAttribution() {
        let event = makeEvent()
        let input = ProvenanceInput(event: event, registrations: [task()])
        XCTAssertNil(input.occurredStart)
        let claim = ProvenanceEngine().attribute(input)
        XCTAssertNil(claim.occurredStart)
        XCTAssertNil(claim.session)
        XCTAssertEqual(claim.confidence, .unknown)
    }

    func testMeasuredBoundsAndPublicationTimeFlowIntoAttributionByDefault() {
        let event = makeEvent().withTiming(.init(occurredStart: nil, occurredEnd: date(100), detectedAt: date(200)))
        let input = ProvenanceInput(event: event, registrations: [task()])
        XCTAssertNil(input.occurredStart)
        XCTAssertEqual(input.occurredEnd, date(100))
        XCTAssertEqual(input.detectedAt, date(200))
        let claim = ProvenanceEngine().attribute(input)
        XCTAssertNil(claim.occurredStart)
        XCTAssertEqual(claim.detectedAt, date(200))
        XCTAssertNil(claim.session)
        let known = makeEvent().withTiming(.init(occurredStart: date(10), occurredEnd: date(100), detectedAt: date(200)))
        let prior = ProvenanceEngine().attribute(.init(event: known, registrations: [task()]))
        XCTAssertEqual(prior.occurredStart, date(10))
        XCTAssertNil(prior.session, "The task started after the possible occurrence interval began")
    }

    func testUnknownBoundsSurvivePersistenceReopenPresentationAndWindowExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("evidence.sqlite")
        let store = try EvidenceStore(url: url)
        try await store.insert(makeEvent())
        let claim = ProvenanceEngine().attribute(.init(event: makeEvent()))
        try await store.persistProvenanceClaim(claim)
        await store.close()
        let reopened = try EvidenceStore(url: url)
        let claims = try await reopened.provenanceClaims()
        XCTAssertEqual(claims, [claim])
        XCTAssertNil(claims.first?.occurredStart)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let value = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(ProvenancePresentationRecord(claim: claim)))
        XCTAssertEqual(value.objectValue?["occurred_start"], .null)
        XCTAssertEqual(value.objectValue?["schema"], .string("provenance-presentation-v3"))
        XCTAssertEqual(SnapshotJSONSchemaValidator().validate(
            instance: try JSONSerialization.jsonObject(with: encoder.encode(ProvenancePresentationRecord(claim: claim))),
            schema: try SnapshotJSONSchemaValidator.loadSchema(named: "provenance-presentation-v3")), [])

        // Discovery at t100 does not exclude a possible occurrence at t20.
        for (lower, upper, count) in [(20.0, 30.0, 1), (101.0, 110.0, 0)] {
            let exported = try await EvidenceBundleExporter(identifierSource: { "window-\(Int(lower))" }).export(
                store: reopened, options: .init(from: date(lower), through: date(upper), pathDetail: .basename),
                to: root.appendingPathComponent("exports"))
            let object = try JSONDecoder().decode(JSONValue.self,
                from: Data(contentsOf: exported.bundleURL.appendingPathComponent("provenance.json")))
            guard case let .array(items)? = object.objectValue?["claims"] else { return XCTFail("Missing claims") }
            XCTAssertEqual(SnapshotJSONSchemaValidator().validate(
                instance: try JSONSerialization.jsonObject(with: JSONEncoder().encode(object)),
                schema: try SnapshotJSONSchemaValidator.loadSchema(named: "provenance-chain-v3")), [])
            XCTAssertEqual(items.count, count)
            if let item = items.first {
                XCTAssertEqual(item.objectValue?["occurred_start"], .null)
                XCTAssertEqual(item.objectValue?["timing_basis"], .string("observation-bounds"))
            }
        }
        await reopened.close()
    }

    func testLegacyPresentationIsReadableAndReencodesAsExplicitlyUnverifiedV3() throws {
        let claim = ProvenanceEngine().attribute(.init(event: makeEvent(), occurredStart: date(100)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(ProvenancePresentationRecord(claim: claim))) as? [String: Any])
        legacy["schema"] = "provenance-presentation-v2"
        legacy.removeValue(forKey: "timing_basis")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProvenancePresentationRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.occurredStart)
        XCTAssertEqual(decoded.timingBasis, "legacy-unverified")
        XCTAssertTrue(decoded.limitations.contains { $0.contains("Legacy occurrence") })
        XCTAssertEqual(decoded.schema, "provenance-presentation-v3")
        XCTAssertEqual(SnapshotJSONSchemaValidator().validate(
            instance: try JSONSerialization.jsonObject(with: encoder.encode(decoded)),
            schema: try SnapshotJSONSchemaValidator.loadSchema(named: "provenance-presentation-v3")), [])
    }

    func testLegacyClaimMigrationPreservesBytesAndSupersessionWithoutPromotingBounds() async throws {
        for version in [5, 6] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("legacy.sqlite")
            let old = try SQLiteConnection(url: url)
            try old.execute(HistoricalEvidenceSchema.v5)
            if version == 6 { try old.execute(HistoricalEvidenceSchema.v6Additions) }
            let event = makeEvent()
            try old.execute("INSERT INTO events VALUES ('unknown-first-sighting', 2000000100, 'create', '/fixture/output', 10, 16, 'test', 'unknown', 0, 0)")
            var originals: [String: Data] = [:]
            for index in 1...2 {
                let claim = ProvenanceClaim(event: event, actor: nil, session: nil, confidence: .unknown,
                    method: "legacy-test", support: [], limitations: [], claimID: "old-\(index)",
                    occurredStart: date(100), supersedesClaimID: index == 2 ? "old-1" : nil)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(claim)) as? [String: Any])
                json.removeValue(forKey: "timingVersion")
                let payload = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                originals[claim.claimID] = payload
                let decoded = try JSONDecoder().decode(ProvenanceClaim.self, from: payload)
                XCTAssertNil(decoded.occurredStart)
                XCTAssertEqual(decoded.timingBasis, "legacy-unverified")
                try old.withStatement("INSERT INTO provenance_claims VALUES (?, 'unknown-first-sighting', 'legacy-test', 'unknown', 2000000100, 2000000100, 2000000100, NULL, ?, NULL, ?)") { statement in
                    try old.bind(claim.claimID, at: 1, in: statement)
                    try old.bind(claim.supersedesClaimID, at: 2, in: statement)
                    try old.bind(payload, at: 3, in: statement)
                    try old.stepDone(statement)
                }
            }
            try old.execute("UPDATE provenance_claims SET superseded_by_claim_id = 'old-2' WHERE claim_id = 'old-1'")
            old.close()
            let store = try EvidenceStore(url: url, availableCapacitySource: { _ in Int64.max })
            let claims = try await store.provenanceClaims()
            XCTAssertEqual(claims.count, 2)
            XCTAssertTrue(claims.allSatisfy { $0.occurredStart == nil && $0.timingBasis == "legacy-unverified" })
            XCTAssertEqual(claims.first?.supersededByClaimID, "old-2", "Overlaying supersession must not upgrade timing")
            let db = try SQLiteConnection(url: url)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM provenance_claims WHERE occurred_start IS NULL AND legacy_occurred_start = 2000000100 AND timing_version = 0"), 2)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM pragma_foreign_key_check"), 0)
            for (id, payload) in originals {
                XCTAssertEqual(try db.scalarText("SELECT hex(payload) FROM provenance_claims WHERE claim_id = '\(id)'"), payload.map { String(format: "%02X", $0) }.joined())
            }
            db.close()
            await store.close()
        }
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 2_000_000_000 + seconds) }
    private func makeEvent() -> EvidenceStoreEvent {
        .init(eventID: "unknown-first-sighting", observedAt: date(100), operation: .create,
              path: "/fixture/output", logicalDelta: 10, allocatedDelta: 16,
              consumerCategory: "test", confidence: .unknown)
    }
    private func task() -> AgentSessionRegistration {
        .init(registrationID: UUID(), client: .codex, sessionID: "discovery-task",
              process: .init(pid: 701, startTime: date(40)), workspaceRoots: ["/fixture"],
              registeredAt: date(50), expiresAt: date(300), endedAt: nil, lifecycle: .active,
              authentication: .init(challengeDigest: String(repeating: "a", count: 64)))
    }
}
