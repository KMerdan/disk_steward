import Foundation
import XCTest
@testable import DiskStewardCore

final class TaskAttributionClaimTests: XCTestCase {
    func testRetainedUnknownLowerBoundDoesNotFallBackToEventLowerBound() throws {
        let target = registration
        let claim = ProvenanceEngine().attribute(.init(event: event, registrations: [target]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(claim)) as? [String: Any])
        json.removeValue(forKey: "occurredStart")
        let unknown = try JSONDecoder().decode(ProvenanceClaim.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(unknown.occurredStart)
        XCTAssertNotNil(unknown.event.timing?.occurredStart)
        XCTAssertNil(ProvenanceEngine().taskAttribution(for: event, currentClaim: unknown,
            registrations: [target], hasObservationGap: false))
    }

    func testVerifiedExplicitClaimBoundsRemainUsableWithoutEventTiming() {
        let target = registration
        let unmeasured = event.withTiming(nil)
        let claim = ProvenanceClaim(event: unmeasured, actor: nil,
            session: .init(registration: target, relationship: "unique-workspace-and-time-overlap"),
            confidence: .inferred, method: "workspace-temporal-correlation", support: [], limitations: [],
            detectedAt: date(30), occurredStart: date(10), occurredEnd: date(20))
        let result = ProvenanceEngine().taskAttribution(for: unmeasured, currentClaim: claim,
            registrations: [target], hasObservationGap: false)
        XCTAssertEqual(result?.session?.sessionID, "target")
        XCTAssertEqual(result?.occurredStart, date(10))
        XCTAssertEqual(result?.occurredEnd, date(20))
        XCTAssertEqual(result?.detectedAt, date(30))
    }

    func testKnownWriterWithoutTaskLinkCannotBeOverriddenByWorkspaceInference() {
        let claim = ProvenanceClaim(event: event, actor: .init(process: .init(pid: 22, startTime: date(0)), relationship: "observed-file-operator"),
            session: nil, confidence: .exact, method: "direct-process-file-observation",
            support: [.init(kind: .endpointSecurity, identifier: "ep", supports: "observed writer"),
                      .init(kind: .processAncestry, identifier: "ancestry", supports: "no task link")], limitations: [])
        XCTAssertNil(ProvenanceEngine().taskAttribution(for: event, currentClaim: claim,
            registrations: [registration], hasObservationGap: false))
    }

    func testPersistedUnknownMustNotBecomeUniqueWhenCompetingHistoryIsNoLongerRetained() {
        let claim = ProvenanceClaim(event: event, actor: nil, session: nil, confidence: .unknown,
            method: "insufficient-causal-evidence", support: [], limitations: ["Multiple task workspaces matched."])
        XCTAssertNil(ProvenanceEngine().taskAttribution(for: event, currentClaim: claim,
            registrations: [registration], hasObservationGap: false))
    }

    func testRetainedInferenceIsRevalidatedButNotReassignedToAnotherTask() {
        let previous = AgentSessionRegistration(registrationID: UUID(), client: .claude, sessionID: "prior",
            process: .init(pid: 33, startTime: date(0)), workspaceRoots: ["/fixture"],
            registeredAt: date(0), expiresAt: date(100), endedAt: nil, lifecycle: .active,
            authentication: .init(challengeDigest: String(repeating: "a", count: 64)))
        let claim = ProvenanceEngine().attribute(.init(event: event, registrations: [previous]))
        XCTAssertEqual(claim.session?.sessionID, "prior")
        XCTAssertNil(ProvenanceEngine().taskAttribution(for: event, currentClaim: claim,
            registrations: [registration], hasObservationGap: false))
    }

    func testRetainedClaimSurvivesTimeBaseRoundTripOfObservedAt() throws {
        // A claim payload keeps its event dates as reference-date seconds; the
        // store returns the same instant from Unix seconds. Rounding between
        // the two bases moves roughly a quarter of wall-clock values up by one
        // binary digit. Find such an instant deterministically.
        let base = Date().timeIntervalSinceReferenceDate
        var original: Date?
        var storeRead: Date?
        for step in 0..<1_000_000 {
            let candidate = Date(timeIntervalSinceReferenceDate: base + Double(step) * 0.000_137)
            let read = Date(timeIntervalSince1970: candidate.timeIntervalSince1970)
            if read > candidate { original = candidate; storeRead = read; break }
        }
        let claimInstant = try XCTUnwrap(original)
        let storedInstant = try XCTUnwrap(storeRead)
        XCTAssertLessThan(storedInstant.timeIntervalSince(claimInstant), 1e-6)
        func event(at instant: Date) -> EvidenceStoreEvent {
            // In production the modification's observed, occurred-end and
            // detected instants are the same sample; keep them equal here.
            EvidenceStoreEvent(eventID: "round-trip", observedAt: instant, operation: .modify, path: "/fixture/output",
                logicalDelta: 1, allocatedDelta: 1, consumerCategory: "test", confidence: .unknown)
                .withTiming(.init(occurredStart: date(10), occurredEnd: instant, detectedAt: instant))
        }
        let session = AgentSessionRegistration(registrationID: UUID(), client: .codex, sessionID: "target",
            process: .init(pid: 11, startTime: date(0)), workspaceRoots: ["/fixture"],
            registeredAt: date(0), expiresAt: claimInstant.addingTimeInterval(100), endedAt: nil, lifecycle: .active,
            authentication: .init(challengeDigest: String(repeating: "a", count: 64)))
        let retained = ProvenanceEngine().attribute(.init(event: event(at: claimInstant), registrations: [session]))
        XCTAssertEqual(retained.session?.registrationID, session.registrationID)
        let payload = try JSONEncoder().encode(retained)
        let persisted = try JSONDecoder().decode(ProvenanceClaim.self, from: payload)
        XCTAssertEqual(persisted.event.observedAt, claimInstant, "The payload round trip itself is exact")
        let result = ProvenanceEngine().taskAttribution(for: event(at: storedInstant), currentClaim: persisted,
            registrations: [session], hasObservationGap: false)
        XCTAssertEqual(result?.session?.registrationID, session.registrationID,
            "A representation-only difference between the payload and the store must not silently drop the attribution")
        // A genuinely different observation is still rejected.
        let shifted = ProvenanceEngine().taskAttribution(for: event(at: storedInstant.addingTimeInterval(0.01)), currentClaim: persisted,
            registrations: [session], hasObservationGap: false)
        XCTAssertNil(shifted)
    }

    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private var event: EvidenceStoreEvent {
        .init(eventID: "measured", observedAt: date(20), operation: .modify, path: "/fixture/output",
            logicalDelta: 1, allocatedDelta: 1, consumerCategory: "test", confidence: .unknown)
            .withTiming(.init(occurredStart: date(10), occurredEnd: date(20), detectedAt: date(30)))
    }
    private var registration: AgentSessionRegistration {
        .init(registrationID: UUID(), client: .codex, sessionID: "target",
            process: .init(pid: 11, startTime: date(0)), workspaceRoots: ["/fixture"],
            registeredAt: date(0), expiresAt: date(100), endedAt: nil, lifecycle: .active,
            authentication: .init(challengeDigest: String(repeating: "a", count: 64)))
    }
}
