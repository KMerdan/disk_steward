import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

final class TaskImpactTimingIPCIntegrationTests: XCTestCase {
    func testUnknownFirstSightingsAndUnverifiedRowsAreNotTaskCreationEvidence() async throws {
        let fixture = try await ImpactTimingFixture.make()
        defer { fixture.remove() }
        let result = try fixture.query(from: 0, through: 800)
        XCTAssertEqual(result["event_ids"], .array(fixture.changes.map(JSONValue.string)))
        XCTAssertEqual(result["allocated_delta"], .integer(2))
        XCTAssertEqual(result["confidence"], .string("inferred"))
        XCTAssertEqual(result["window_semantics"], .string("possible-occurrence-overlap"))
        XCTAssertEqual(result["attribution_semantics"], .string("occurrence-bounds-v1"))
        XCTAssertEqual(result["session_lifecycle"], .array([.string("ended")]))
    }

    func testCompetingPartialSessionCannotBeHiddenBySelectingOnlyOneSession() async throws {
        let fixture = try await ImpactTimingFixture.make(competing: true, persistOldInference: true)
        defer { fixture.remove() }
        let result = try fixture.query(from: 0, through: 800)
        XCTAssertEqual(result["event_ids"], .array([.string(fixture.changes[1])]))
        XCTAssertEqual(result["allocated_delta"], .integer(1), "Retained inference must be rechecked against all competing sessions")
    }

    func testPartialTargetRegistrationDoesNotCoverEarlierPossibleOccurrence() async throws {
        let fixture = try await ImpactTimingFixture.make(targetStart: 150)
        defer { fixture.remove() }
        let result = try fixture.query(from: 0, through: 800)
        XCTAssertEqual(result["event_ids"], .array([.string(fixture.changes[1])]))
        XCTAssertEqual(result["allocated_delta"], .integer(1))
    }

    func testWindowUsesOccurrenceOverlapNotLaterDiscoveryOrPublication() async throws {
        let fixture = try await ImpactTimingFixture.make()
        defer { fixture.remove() }
        // The change is bounded by samples at t100 and t300, published at t400.
        let earlier = try fixture.query(from: 150, through: 200)
        XCTAssertEqual(earlier["event_ids"], .array([.string(fixture.changes[0])]))
        XCTAssertEqual(earlier["allocated_delta"], .integer(1))
        let after = try fixture.query(from: 650, through: 675)
        XCTAssertEqual(after["event_ids"], .array([]), "Publication at t700 does not move the second change out of its t300–600 bounds")
        XCTAssertEqual(after["confidence"], .string("unknown"))
        XCTAssertEqual(after["allocated_delta"], .integer(0))
    }

    func testRetainedDirectProcessProofIsNotDiscardedWithUnknownLowerBound() async throws {
        let fixture = try await ImpactTimingFixture.make(competing: true, directProof: true)
        defer { fixture.remove() }
        let result = try fixture.query(from: 320, through: 340)
        // A direct operation at t350 supports the actor/session independently
        // of a metadata lower bound. This window is only a possible overlap.
        XCTAssertEqual(result["event_ids"], .array([.string("direct"), .string(fixture.changes[1])]))
        XCTAssertEqual(result["allocated_delta"], .integer(11))
        XCTAssertEqual(result["confidence"], .string("inferred"), "The weakest included claim governs the aggregate")
        XCTAssertEqual(result["method"], .string("persisted-provenance-and-session-correlation"))
    }

    func testUnrelatedRootGapDoesNotDiscardHealthyRootAttribution() async throws {
        let fixture = try await ImpactTimingFixture.make(unrelatedGap: true)
        defer { fixture.remove() }
        let result = try fixture.query(from: 0, through: 800)
        XCTAssertEqual(result["event_ids"], .array(fixture.changes.map(JSONValue.string)))
        XCTAssertEqual(result["allocated_delta"], .integer(2))
    }

    func testCorrectedCurrentClaimBoundsOverrideEarlierMetadataWindow() async throws {
        let fixture = try await ImpactTimingFixture.make(refinedClaim: true)
        defer { fixture.remove() }
        let outside = try fixture.query(from: 150, through: 175)
        XCTAssertEqual(outside["event_ids"], .array([]))
        XCTAssertEqual(outside["allocated_delta"], .integer(0))
        let inside = try fixture.query(from: 210, through: 225)
        XCTAssertEqual(inside["event_ids"], .array([.string(fixture.changes[0])]))
        XCTAssertEqual(inside["allocated_delta"], .integer(1))
    }
}

private struct ImpactTimingFixture {
    let root: URL
    let start: Date
    let changes: [String]

    static func make(targetStart: Double = 50, competing: Bool = false, persistOldInference: Bool = false, directProof: Bool = false, unrelatedGap: Bool = false, refinedClaim: Bool = false) async throws -> Self {
        let root = URL(fileURLWithPath: "/tmp/ds-impact-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Deliberately fractional: claims encode reference-date seconds while
        // the event table stores Unix seconds. Identity must survive both.
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000_000.1234567)
        let database = root.appending(path: "evidence.sqlite")
        let watch = root.appending(path: "watched").path
        let path = watch + "/artifact"
        let scope = EvidenceScopeVersion(scopeVersionID: "impact-scope", effectiveAt: start,
            rootPaths: unrelatedGap ? [watch, watch + "-other"] : [watch], excludedPaths: [], maximumEntries: 10, maximumDepth: 2)
        func registration(_ id: String, lower: Double, upper: Double, pid: Int32) -> AgentSessionRegistration {
            .init(registrationID: UUID(), client: .codex, sessionID: id,
                process: .init(pid: pid, startTime: start), workspaceRoots: [watch],
                registeredAt: start.addingTimeInterval(lower), expiresAt: start.addingTimeInterval(800),
                endedAt: start.addingTimeInterval(upper), lifecycle: .ended,
                authentication: .init(challengeDigest: String(repeating: "a", count: 64)))
        }
        let target = registration("target", lower: targetStart, upper: 750, pid: 701)
        let store = try EvidenceStore(url: database)
        try await store.persistAgentSession(target)
        var changes: [String] = []
        for (index, sample) in [100.0, 300.0, 600.0].enumerated() {
            let publication = start.addingTimeInterval(sample + 100)
            let file = FileMetadata(objectID: "artifact", rootPath: watch, path: path,
                logicalBytes: Int64(100 + index), allocatedBytes: Int64(100 + index), modifiedAt: nil,
                observedAt: start.addingTimeInterval(sample))
            let commit = try await store.recordObservation(
                snapshot: .init(snapshotID: "impact-\(index)", observedAt: EvidenceTimestamp.format(publication), volumes: []),
                metadata: .init(observationID: "impact-\(index)", scopeVersionID: scope.scopeVersionID,
                    observedAt: publication, entries: [path: file], rootCoverage: [.init(rootPath: watch, coverage: .complete)]
                        + (unrelatedGap ? [.init(rootPath: watch + "-other", coverage: .partial)] : []), limitations: []),
                scope: scope, trigger: .scheduled)
            let event = try XCTUnwrap(commit.events.first)
            if index > 0 { changes.append(event.eventID) }
            if persistOldInference && index == 1 {
                let claim = ProvenanceEngine().attribute(.init(event: event, registrations: [target]))
                XCTAssertEqual(claim.session?.sessionID, "target")
                try await store.persistProvenanceClaim(claim)
            }
            if refinedClaim && index == 1 {
                // The public retained-claim contract permits explicit bounds
                // supplied by a later evidence source. Query-time inference
                // must not silently replace them with the wider event bounds.
                try await store.persistProvenanceClaim(.init(event: event, actor: nil,
                    session: .init(registration: target, relationship: "unique-workspace-and-time-overlap"),
                    confidence: .inferred, method: "workspace-temporal-correlation", support: [], limitations: [],
                    occurredStart: start.addingTimeInterval(200), occurredEnd: start.addingTimeInterval(250)))
            }
        }
        try await store.insert(.init(eventID: "unverified", observedAt: start.addingTimeInterval(350),
            operation: .writeSummary, path: path, logicalDelta: 777, allocatedDelta: 777,
            consumerCategory: "test", confidence: .inferred))
        if competing { try await store.persistAgentSession(registration("competitor", lower: 250, upper: 275, pid: 702)) }
        if directProof {
            let date = start.addingTimeInterval(350)
            let event = EvidenceStoreEvent(eventID: "direct", observedAt: date, operation: .writeSummary,
                path: path, logicalDelta: 10, allocatedDelta: 10, consumerCategory: "test", confidence: .unknown)
            let process = ProcessIdentity(pid: 703, startTime: start)
            let raw = RawPrivilegedNotification(eventID: "endpoint-direct", streamID: "fixture", sequence: 1,
                observedAt: date, operation: .writeSummary, path: path, process: process,
                fileIdentity: .init(volumeID: "fixture", fileID: 1, generation: 1),
                size: .init(logicalBefore: 0, logicalAfter: 10, allocatedBefore: 0, allocatedAfter: 10, method: "fstat"))
            let notification = try XCTUnwrap(EndpointEventNormalizer().normalize(raw,
                scope: .init(watchedRoots: [watch], excludedRoots: []), gapBefore: false))
            let claim = ProvenanceEngine().attribute(.init(event: event, privilegedEvent: notification,
                registrations: [target], ancestry: .init(records: [.init(identity: process, parent: target.process)])))
            XCTAssertEqual(claim.session?.sessionID, "target")
            XCTAssertNotNil(claim.actor)
            XCTAssertNil(claim.occurredStart)
            try await store.insert(event)
            try await store.persistProvenanceClaim(claim)
        }
        await store.close()
        return Self(root: root, start: start, changes: changes)
    }

    func query(from: Double, through: Double) throws -> [String: JSONValue] {
        let backend = try AppEvidenceQueryBackend(databaseURL: root.appending(path: "evidence.sqlite"))
        let socket = root.appending(path: "private/service.sock")
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: backend)
        try server.start()
        defer { server.stop() }
        let response = try UnixSocketDiskStewardIPCClient(socketPath: socket.path).call(tool: "get_task_impact", arguments: [
            "session_id": .string("target"), "limit": .integer(10),
            "from": .string(EvidenceTimestamp.format(start.addingTimeInterval(from))),
            "through": .string(EvidenceTimestamp.format(start.addingTimeInterval(through)))
        ], isCancelled: { false })
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(response), as: UTF8.self).contains(root.path))
        return try XCTUnwrap(response.objectValue)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
