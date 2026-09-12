import DiskStewardCore
import XCTest

final class TaskImpactCorrelationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDescendantWriterLinksOnlyToCorrectConcurrentTask() {
        let codexRoot = ProcessIdentity(pid: 100, startTime: now.addingTimeInterval(-100))
        let codexChild = ProcessIdentity(pid: 101, startTime: now.addingTimeInterval(-90))
        let claudeRoot = ProcessIdentity(pid: 200, startTime: now.addingTimeInterval(-100))
        let ancestry = ProcessAncestrySnapshot(records: [
            ProcessAncestryRecord(identity: codexRoot, parent: nil),
            ProcessAncestryRecord(identity: codexChild, parent: codexRoot),
            ProcessAncestryRecord(identity: claudeRoot, parent: nil),
        ])
        let registrations = [
            registration(sessionID: "codex-task", process: codexRoot, roots: ["/work/shared"]),
            registration(sessionID: "claude-task", process: claudeRoot, roots: ["/work/shared"]),
        ]
        let event = evidence(id: "e1", path: "/work/shared/artifact.bin", delta: 4096)

        let result = TaskImpactCorrelationEngine().correlate(
            [CorrelationObservation(event: event, writer: codexChild)],
            registrations: registrations,
            ancestry: ancestry
        )

        XCTAssertEqual(result.first?.sessionID, "codex-task")
        XCTAssertEqual(result.first?.confidence, .toolLinked)
        XCTAssertEqual(result.first?.method, "registered-process-tree")
    }

    func testOverlappingWorkspaceWithoutWriterStaysUnknownAndDoesNotLeakAcrossTasks() {
        let registrations = [
            registration(sessionID: "one", process: .init(pid: 300, startTime: now.addingTimeInterval(-20)), roots: ["/work/shared"]),
            registration(sessionID: "two", process: .init(pid: 400, startTime: now.addingTimeInterval(-20)), roots: ["/work/shared"]),
        ]
        let event = evidence(id: "e2", path: "/work/shared/output.zip", delta: 8192)
        let result = TaskImpactCorrelationEngine().correlate(
            [.init(event: event, writer: nil)],
            registrations: registrations,
            ancestry: .init(records: [])
        )

        XCTAssertNil(result.first?.sessionID)
        XCTAssertEqual(result.first?.confidence, .unknown)
        XCTAssertTrue(result.first?.limitations.first?.contains("multiple") == true)
    }

    func testUniqueWorkspaceDowngradesToInferredAndImpactSumsOnlyLinkedEvents() {
        let registration = registration(
            sessionID: "only-task",
            process: .init(pid: 500, startTime: now.addingTimeInterval(-20)),
            roots: ["/work/only"]
        )
        let engine = TaskImpactCorrelationEngine()
        let events = [
            CorrelationObservation(event: evidence(id: "a", path: "/work/only/a", delta: 100), writer: nil),
            CorrelationObservation(event: evidence(id: "b", path: "/outside/b", delta: 900), writer: nil),
        ]
        let correlated = engine.correlate(events, registrations: [registration], ancestry: .init(records: []))
        let impact = engine.impact(for: "only-task", correlated: correlated)

        XCTAssertEqual(correlated.first?.confidence, .inferred)
        XCTAssertEqual(impact.eventIDs, ["a"])
        XCTAssertEqual(impact.logicalDelta, 100)
        XCTAssertEqual(impact.allocatedDelta, 100)
        XCTAssertEqual(impact.confidence, .inferred)
    }

    func testExpiredSessionAndReusedPIDCannotClaimNewEvent() {
        let oldStart = now.addingTimeInterval(-500)
        let newStart = now.addingTimeInterval(-10)
        let old = AgentSessionRegistration(
            registrationID: UUID(),
            client: .codex,
            sessionID: "expired",
            process: .init(pid: 600, startTime: oldStart),
            workspaceRoots: [],
            registeredAt: now.addingTimeInterval(-400),
            expiresAt: now.addingTimeInterval(-100),
            endedAt: now.addingTimeInterval(-100),
            lifecycle: .expired,
            authentication: .init(challengeDigest: String(repeating: "a", count: 64))
        )
        let reused = ProcessIdentity(pid: 600, startTime: newStart)
        let event = evidence(id: "reuse", path: "/tmp/reuse", delta: 1)
        let result = TaskImpactCorrelationEngine().correlate(
            [.init(event: event, writer: reused)],
            registrations: [old],
            ancestry: .init(records: [.init(identity: reused, parent: nil)])
        )

        XCTAssertNil(result.first?.sessionID)
        XCTAssertEqual(result.first?.confidence, .unknown)
    }

    private func registration(sessionID: String, process: ProcessIdentity, roots: [String]) -> AgentSessionRegistration {
        AgentSessionRegistration(
            registrationID: UUID(),
            client: .codex,
            sessionID: sessionID,
            process: process,
            workspaceRoots: roots,
            registeredAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(60),
            endedAt: nil,
            lifecycle: .active,
            authentication: .init(challengeDigest: String(repeating: "a", count: 64))
        )
    }

    private func evidence(id: String, path: String, delta: Int64) -> EvidenceStoreEvent {
        EvidenceStoreEvent(
            eventID: id,
            observedAt: now,
            operation: .writeSummary,
            path: path,
            logicalDelta: delta,
            allocatedDelta: delta,
            consumerCategory: "agent-artifact",
            confidence: .inferred
        )
    }
}
