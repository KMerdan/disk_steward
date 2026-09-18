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
