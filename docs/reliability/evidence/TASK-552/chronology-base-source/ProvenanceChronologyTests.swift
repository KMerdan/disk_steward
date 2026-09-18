import Foundation
import XCTest
@testable import DiskStewardCore

final class ProvenanceChronologyTests: XCTestCase, @unchecked Sendable {
    private let instant = Date(timeIntervalSince1970: 2_100_000_000)

    func testConstructorsPreserveContradictoryBoundsForValidation() {
        let start = instant.addingTimeInterval(20)
        let end = instant.addingTimeInterval(-20)
        let input = ProvenanceInput(event: event(), occurredStart: start, occurredEnd: end)
        XCTAssertEqual(input.occurredStart, start)
        XCTAssertEqual(input.occurredEnd, end)
        let claim = makeClaim(start: start, end: end, detected: instant)
        XCTAssertEqual(claim.occurredStart, start)
        XCTAssertEqual(claim.occurredEnd, end)
    }

    func testInvalidChronologyCannotProduceAnActorOrSessionClaim() throws {
        let writer = ProcessIdentity(pid: 712, startTime: instant.addingTimeInterval(-30))
        let raw = RawPrivilegedNotification(
            eventID: "endpoint-chronology", streamID: "chronology", sequence: 1,
            observedAt: instant, operation: .create, path: event().path,
            process: writer, fileIdentity: .init(volumeID: "fixture", fileID: 1, generation: 1),
            size: .init(logicalBefore: 0, logicalAfter: 10, allocatedBefore: 0, allocatedAfter: 16, method: "fstat")
        )
        let privileged = try XCTUnwrap(EndpointEventNormalizer().normalize(
            raw, scope: .init(watchedRoots: ["/fixture"], excludedRoots: []), gapBefore: false
        ))
        let cases: [(Date, Date, Date)] = [
            (instant.addingTimeInterval(10), instant, instant),
            (instant.addingTimeInterval(-10), instant, instant.addingTimeInterval(-1)),
            (Date(timeIntervalSince1970: .infinity), instant, instant),
            (instant, Date(timeIntervalSince1970: .nan), instant),
        ]
        for (start, end, detected) in cases {
            let claim = ProvenanceEngine().attribute(.init(
                event: event(), privilegedEvent: privileged, registrations: [registration()],
                ancestry: .init(records: [.init(identity: writer, parent: registration().process)]),
                detectedAt: detected, occurredStart: start, occurredEnd: end
            ))
            XCTAssertEqual(claim.confidence, .unknown)
            XCTAssertNil(claim.actor)
            XCTAssertNil(claim.session)
            XCTAssertTrue(claim.contradictions.contains { $0.contains("chronology") })
        }
    }

    func testStoreRejectsInvalidChronologyWithoutPersistingAClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provenance-chronology-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EvidenceStore(url: root.appendingPathComponent("fixture.sqlite"))
        try await store.insert(event())
        for claim in [
            makeClaim(start: instant.addingTimeInterval(10), end: instant, detected: instant),
            makeClaim(start: instant.addingTimeInterval(-10), end: instant, detected: instant.addingTimeInterval(-1)),
        ] {
            do {
                try await store.persistProvenanceClaim(claim)
                XCTFail("Contradictory evidence must not be repaired into a persisted claim")
            } catch EvidenceStoreError.invalidEvent { }
        }
        let invalidClaims = try await store.provenanceClaims()
        XCTAssertTrue(invalidClaims.isEmpty)
        let valid = makeClaim(start: instant.addingTimeInterval(-10), end: instant, detected: instant.addingTimeInterval(10))
        try await store.persistProvenanceClaim(valid)
        let validClaims = try await store.provenanceClaims()
        XCTAssertEqual(validClaims, [valid])
        await store.close()
    }

    func testWorkspaceCorrelationRequiresTheWholeKnownInterval() {
        let claim = ProvenanceEngine().attribute(.init(
            event: event(), registrations: [registration()],
            occurredStart: instant.addingTimeInterval(-200), occurredEnd: instant
        ))
        XCTAssertNil(claim.session, "A task active only at discovery did not cover the possible occurrence interval")
        XCTAssertEqual(claim.confidence, .unknown)
        let contained = ProvenanceEngine().attribute(.init(
            event: event(), registrations: [registration()],
            occurredStart: instant.addingTimeInterval(-10), occurredEnd: instant
        ))
        XCTAssertEqual(contained.confidence, .inferred)
        XCTAssertEqual(contained.session?.sessionID, "chronology-task")
    }

    private func event() -> EvidenceStoreEvent {
        .init(eventID: "chronology-event", observedAt: instant, operation: .create,
              path: "/fixture/output", logicalDelta: 10, allocatedDelta: 16,
              consumerCategory: "agent-artifact", confidence: .inferred)
    }

    private func makeClaim(start: Date, end: Date, detected: Date) -> ProvenanceClaim {
        .init(event: event(), actor: nil, session: nil, confidence: .unknown,
              method: "metadata-only", support: [], limitations: [], claimID: UUID().uuidString, detectedAt: detected,
              occurredStart: start, occurredEnd: end)
    }

    private func registration() -> AgentSessionRegistration {
        .init(registrationID: UUID(),
              client: .codex, sessionID: "chronology-task",
              process: .init(pid: 710, startTime: instant.addingTimeInterval(-100)),
              workspaceRoots: ["/fixture"], registeredAt: instant.addingTimeInterval(-100),
              expiresAt: instant.addingTimeInterval(100), endedAt: nil, lifecycle: .active,
              authentication: .init(challengeDigest: String(repeating: "a", count: 64)))
    }
}
