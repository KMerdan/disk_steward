import Foundation
import XCTest
@testable import DiskStewardCore

final class ProvenanceEngineTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 2_000_000_000)
    private let root = "/Users/example/work"

    func testGoldenCreateGrowAndRenameHaveDirectCausalSupport() throws {
        let scenarios: [(PrivilegedFileOperation, EvidenceStoreEvent.Operation, String, String?)] = [
            (.create, .create, "/Users/example/work/output.txt", nil),
            (.writeClose, .writeSummary, "/Users/example/work/output.txt", nil),
            (.rename, .rename, "/Users/example/work/old.txt", "/Users/example/work/final.txt"),
        ]

        for (privilegedOperation, operation, sourcePath, destinationPath) in scenarios {
            let path = destinationPath ?? sourcePath
            let event = makeEvent(operation: operation, path: path)
            let privileged = try makePrivileged(
                operation: privilegedOperation,
                path: sourcePath,
                destinationPath: destinationPath
            )
            let claim = ProvenanceEngine().attribute(.init(event: event, privilegedEvent: privileged))

            XCTAssertEqual(claim.confidence, .exact)
            XCTAssertEqual(claim.actor?.process, privileged.raw.process)
            XCTAssertNil(claim.session)
            XCTAssertEqual(Set(claim.support.map(\.kind)), [.endpointSecurity, .metadataSnapshot, .processAncestry])
        }
    }

    func testExactWriterLinksOnlyToCorrectAuthenticatedTaskByFullProcessIdentity() throws {
        let taskRoot = ProcessIdentity(pid: 700, startTime: instant.addingTimeInterval(-20), executablePath: "/usr/bin/codex")
        let writer = ProcessIdentity(pid: 701, startTime: instant.addingTimeInterval(-10), executablePath: "/bin/zsh")
        let reusedPID = ProcessIdentity(pid: 701, startTime: instant.addingTimeInterval(-1_000), executablePath: "/bin/zsh")
        let registration = makeRegistration(process: taskRoot, sessionID: "task-right")
        let unrelated = makeRegistration(process: reusedPID, sessionID: "task-reused-pid")
        let ancestry = ProcessAncestrySnapshot(records: [
            .init(identity: writer, parent: taskRoot),
            .init(identity: taskRoot, parent: nil),
            .init(identity: reusedPID, parent: nil),
        ])
        let event = makeEvent(operation: .create, path: root + "/artifact.json")
        let privileged = try makePrivileged(operation: .create, path: event.path, process: writer)

        let claim = ProvenanceEngine().attribute(
            .init(event: event, privilegedEvent: privileged, registrations: [unrelated, registration], ancestry: ancestry)
        )

        XCTAssertEqual(claim.confidence, .exact)
        XCTAssertEqual(claim.session?.sessionID, "task-right")
        XCTAssertEqual(claim.method, "direct-process-file-and-task-observation")
        XCTAssertFalse(claim.support.contains { $0.identifier == unrelated.registrationID.uuidString.lowercased() })
    }

    func testGapsHistoricalEvidenceAndIncompleteObserverCannotClaimExact() throws {
        let task = makeRegistration(
            process: ProcessIdentity(pid: 700, startTime: instant.addingTimeInterval(-20)),
            sessionID: "task"
        )
        let event = makeEvent(operation: .writeSummary, path: root + "/cache.bin")
        let gapped = try makePrivileged(operation: .writeClose, path: event.path, gap: true)
        let ancestry = ProcessAncestrySnapshot(records: [
            .init(identity: gapped.raw.process, parent: task.process),
            .init(identity: task.process, parent: nil),
        ])

        let gappedClaim = ProvenanceEngine().attribute(
            .init(event: event, privilegedEvent: gapped, registrations: [task], ancestry: ancestry)
        )
        XCTAssertEqual(gappedClaim.confidence, .toolLinked)
        XCTAssertTrue(gappedClaim.limitations.contains { $0.contains("prevents an exact claim") })

        let historicalClaim = ProvenanceEngine().attribute(
            .init(event: event, privilegedEvent: try makePrivileged(operation: .writeClose, path: event.path), registrations: [task], ancestry: ancestry, isHistorical: true)
        )
        XCTAssertEqual(historicalClaim.confidence, .inferred)
        XCTAssertNil(historicalClaim.session)
        XCTAssertTrue(historicalClaim.support.contains { $0.kind == .historicalRecord })
    }

    func testAmbiguousWorkspaceGapAndMismatchedPrivilegedEvidenceStayUnknown() throws {
        let event = makeEvent(operation: .create, path: root + "/artifact.json")
        let first = makeRegistration(process: .init(pid: 100, startTime: instant), sessionID: "one")
        let second = makeRegistration(process: .init(pid: 200, startTime: instant), sessionID: "two")
        let hint = TargetedChangeHint(path: event.path, eventID: 44, observedAt: instant, kind: .created, requiresRescan: true)

        let ambiguous = ProvenanceEngine().attribute(
            .init(event: event, fsevents: [hint], registrations: [first, second])
        )
        XCTAssertEqual(ambiguous.confidence, .unknown)
        XCTAssertNil(ambiguous.session)
        XCTAssertTrue(ambiguous.limitations.contains { $0.contains("Multiple active task") })

        let gapped = ProvenanceEngine().attribute(
            .init(event: event, fsevents: [hint], fseventGap: true, registrations: [first])
        )
        XCTAssertEqual(gapped.confidence, .unknown)
        XCTAssertNil(gapped.session)

        let wrongSize = try makePrivileged(operation: .create, path: event.path, logicalAfter: 9_999, allocatedAfter: 9_999)
        let mismatch = ProvenanceEngine().attribute(.init(event: event, privilegedEvent: wrongSize))
        XCTAssertEqual(mismatch.confidence, .unknown)
        XCTAssertNil(mismatch.actor)
        XCTAssertFalse(mismatch.support.contains { $0.kind == .endpointSecurity })
    }

    func testUIExportAndMCPReceiveIdenticalSupportAndFixturesAreInspectable() throws {
        let event = makeEvent(operation: .create, path: root + "/artifact.json")
        let claim = ProvenanceEngine().attribute(
            .init(event: event, privilegedEvent: try makePrivileged(operation: .create, path: event.path))
        )
        let adapter = ProvenancePresentationAdapter()
        let records = ProvenancePresentationChannel.allCases.map { adapter.record(for: claim, channel: $0) }

        XCTAssertTrue(records.dropFirst().allSatisfy { $0 == records[0] })
        XCTAssertEqual(records[0].support, claim.support)
        XCTAssertEqual(records[0].confidence, "exact")

        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Provenance")
        for name in ["golden-scenarios.json", "adversarial-scenarios.json"] {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureRoot.appendingPathComponent(name))) as? [String: Any]
            XCTAssertEqual(object?["schema"] as? String, "provenance-fixtures-v1")
            XCTAssertFalse((object?["scenarios"] as? [[String: Any]] ?? []).isEmpty)
        }
    }

    private func makeEvent(operation: EvidenceStoreEvent.Operation, path: String) -> EvidenceStoreEvent {
        EvidenceStoreEvent(
            eventID: "metadata-\(operation.rawValue)",
            observedAt: instant,
            operation: operation,
            path: path,
            logicalDelta: 100,
            allocatedDelta: 128,
            consumerCategory: "agent-artifact",
            confidence: .inferred
        )
    }

    private func makePrivileged(
        operation: PrivilegedFileOperation,
        path: String,
        destinationPath: String? = nil,
        process: ProcessIdentity? = nil,
        gap: Bool = false,
        logicalAfter: Int64 = 100,
        allocatedAfter: Int64 = 128
    ) throws -> NormalizedPrivilegedEvent {
        let notification = RawPrivilegedNotification(
            eventID: "endpoint-\(operation.rawValue)",
            streamID: "stream-1",
            sequence: 1,
            observedAt: instant,
            operation: operation,
            path: path,
            destinationPath: destinationPath,
            process: process ?? ProcessIdentity(pid: 701, startTime: instant.addingTimeInterval(-10), executablePath: "/bin/zsh"),
            fileIdentity: .init(volumeID: "data", fileID: 42, generation: 1),
            size: .init(logicalBefore: 0, logicalAfter: logicalAfter, allocatedBefore: 0, allocatedAfter: allocatedAfter, method: "fstat"),
            deadlineMet: true
        )
        return try XCTUnwrap(
            EndpointEventNormalizer().normalize(
                notification,
                scope: .init(watchedRoots: [root], excludedRoots: []),
                gapBefore: gap
            )
        )
    }

    private func makeRegistration(process: ProcessIdentity, sessionID: String) -> AgentSessionRegistration {
        AgentSessionRegistration(
            registrationID: UUID(),
            client: .codex,
            sessionID: sessionID,
            process: process,
            workspaceRoots: [root],
            registeredAt: instant.addingTimeInterval(-100),
            expiresAt: instant.addingTimeInterval(100),
            endedAt: nil,
            lifecycle: .active,
            authentication: .init(challengeDigest: String(repeating: "a", count: 64))
        )
    }
}
