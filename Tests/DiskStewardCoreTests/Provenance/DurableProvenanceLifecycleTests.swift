import CoreServices
import Darwin
import Foundation
import XCTest
@testable import DiskStewardCore

final class DurableProvenanceLifecycleTests: XCTestCase, @unchecked Sendable {
    private let instant = Date(timeIntervalSince1970: 2_050_000_000)
    private let digest = String(repeating: "b", count: 64)

    func testFSEventFlagsAndEndpointEvidenceRemainDistinctAndLinkedAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var store: EvidenceStore? = try EvidenceStore(url: fixture.databaseURL)
        try await makeObservation(in: store!, id: "observation-fsevent")
        let rawFlags = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagKernelDropped)
        let hint = TargetedChangeHint(
            path: "/fixture/new-name.txt",
            eventID: 4_294_967_400,
            observedAt: instant,
            kind: .renamed,
            requiresRescan: true,
            rawFlags: rawFlags,
            signals: ["item-renamed", "kernel-dropped"]
        )
        try await store!.recordFSEvents(
            .init(hints: [hint], eventGap: true, limitations: ["kernel delivery gap requires reconciliation"]),
            observationID: "observation-fsevent"
        )

        let evidenceEvent = makeEvent(id: "event-endpoint", operation: .rename, path: hint.path)
        try await store!.insert(evidenceEvent)
        let endpoint = try makeEndpoint(eventID: "endpoint-rename", destination: hint.path)
        try await store!.recordEndpointObservation(
            endpoint,
            observationID: "observation-fsevent",
            evidenceEventID: evidenceEvent.eventID
        )
        await store!.close()
        store = nil

        let reopened = try EvidenceStore(url: fixture.databaseURL)
        let hints = try await reopened.fseventHints(observationID: "observation-fsevent")
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints[0].hint.eventID, 4_294_967_400)
        XCTAssertEqual(hints[0].hint.rawFlags, rawFlags)
        XCTAssertEqual(hints[0].hint.signals, ["item-renamed", "kernel-dropped"])
        XCTAssertTrue(hints[0].limitations.contains { $0.contains("gap") })
        let endpoints = try await reopened.endpointObservations(evidenceEventID: evidenceEvent.eventID)
        XCTAssertEqual(endpoints, [.init(observationID: "observation-fsevent", evidenceEventID: evidenceEvent.eventID, event: endpoint)])
    }

    func testClaimsPersistIntervalsContradictionsAncestryUnknownAndSupersession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try EvidenceStore(url: fixture.databaseURL)
        let event = makeEvent(id: "event-claim", operation: .create, path: "/fixture/artifact.json")
        try await store.insert(event)
        let unknown = ProvenanceEngine().attribute(.init(
            event: event,
            fseventGap: true,
            detectedAt: instant.addingTimeInterval(10),
            occurredStart: instant.addingTimeInterval(-60),
            occurredEnd: instant,
            contradictions: ["one active workspace overlapped but the stream was incomplete"],
            claimID: "claim-unknown"
        ))
        XCTAssertEqual(unknown.confidence, .unknown)
        XCTAssertNil(unknown.actor)
        try await store.persistProvenanceClaim(unknown)

        let task = registration(id: UUID(), sessionID: "codex-task", lifecycle: .ended)
        try await store.persistAgentSession(task)
        let writer = ProcessIdentity(pid: 702, startTime: instant.addingTimeInterval(-10), executablePath: "/bin/zsh")
        let ancestry = ProcessAncestrySnapshot(records: [
            .init(identity: writer, parent: task.process),
            .init(identity: task.process, parent: nil),
        ])
        let endpoint = try makeEndpoint(eventID: "endpoint-create", process: writer)
        let exact = ProvenanceEngine().attribute(.init(
            event: event,
            privilegedEvent: endpoint,
            registrations: [task],
            ancestry: ancestry,
            detectedAt: instant.addingTimeInterval(20),
            occurredStart: instant,
            occurredEnd: instant,
            supersedesClaimID: unknown.claimID,
            claimID: "claim-exact"
        ))
        XCTAssertEqual(exact.confidence, .exact)
        XCTAssertEqual(exact.session?.sessionID, "codex-task")
        try await store.recordEndpointObservation(endpoint, evidenceEventID: event.eventID)
        try await store.persistProvenanceClaim(exact)

        let chain = try await store.provenanceClaims(eventID: event.eventID)
        XCTAssertEqual(chain.map(\.claimID), ["claim-unknown", "claim-exact"])
        XCTAssertEqual(chain[0].supersededByClaimID, "claim-exact")
        XCTAssertEqual(chain[0].contradictions, ["one active workspace overlapped but the stream was incomplete"])
        XCTAssertEqual(chain[0].occurredStart, instant.addingTimeInterval(-60))
        XCTAssertEqual(chain[1].observedAncestry.count, 2)
        let currentClaims = try await store.provenanceClaims(eventID: event.eventID, includeSuperseded: false)
        XCTAssertEqual(currentClaims, [chain[1]])
    }

    func testSessionHeartbeatEndExpiryAndHistoricalContextSurviveRegistryRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try EvidenceStore(url: fixture.databaseURL)
        let proof = SessionAuthenticationProof(peerUID: getuid(), socketMode: 0o600, challengeDigest: digest)
        var registry: AgentSessionRegistry? = AgentSessionRegistry(
            expectedPeerUID: getuid(),
            expectedChallengeDigest: digest,
            evidenceStore: store
        )
        let request = SessionRegistrationRequest(
            client: .codex,
            sessionID: "durable-task",
            process: ProcessIdentity(pid: 800, startTime: instant.addingTimeInterval(-30), executablePath: "/usr/bin/codex"),
            workspaceRoots: ["/fixture/project"],
            registeredAt: instant,
            expiresAt: instant.addingTimeInterval(120),
            taskContext: "Codex task: investigate disk growth"
        )
        let active = try await registry!.register(request, proof: proof, now: instant)
        let shortHeartbeat = try await registry!.heartbeat(
            registrationID: active.registrationID,
            extendBy: 60,
            proof: proof,
            now: instant.addingTimeInterval(10)
        )
        XCTAssertEqual(shortHeartbeat.expiresAt, instant.addingTimeInterval(120), "A heartbeat must never shorten an existing lease")
        let heartbeat = try await registry!.heartbeat(
            registrationID: active.registrationID,
            extendBy: 300,
            proof: proof,
            now: instant.addingTimeInterval(60)
        )
        XCTAssertEqual(heartbeat.lastHeartbeatAt, instant.addingTimeInterval(60))
        let ended = try await registry!.end(
            registrationID: active.registrationID,
            proof: proof,
            now: instant.addingTimeInterval(90)
        )
        XCTAssertEqual(ended.lifecycle, .ended)
        do {
            try await store.persistAgentSession(.init(
                registrationID: ended.registrationID,
                client: ended.client,
                sessionID: ended.sessionID,
                process: ended.process,
                workspaceRoots: ended.workspaceRoots,
                registeredAt: ended.registeredAt,
                expiresAt: ended.expiresAt,
                endedAt: ended.endedAt?.addingTimeInterval(1),
                lifecycle: ended.lifecycle,
                authentication: ended.authentication,
                lastHeartbeatAt: ended.lastHeartbeatAt,
                taskContext: ended.taskContext
            ))
            XCTFail("Terminal session history must be immutable")
        } catch {
            guard case EvidenceStoreError.invalidObservation = error else {
                return XCTFail("Unexpected terminal-mutation error: \(error)")
            }
        }
        registry = nil

        let restarted = AgentSessionRegistry(
            expectedPeerUID: getuid(),
            expectedChallengeDigest: digest,
            evidenceStore: store
        )
        let restartedActive = try await restarted.activeRegistrations(proof: proof, now: instant.addingTimeInterval(100))
        XCTAssertEqual(restartedActive, [])
        let history = try await restarted.historicalRegistrations(sessionID: "durable-task", proof: proof, now: instant.addingTimeInterval(100))
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].lifecycle, .ended)
        XCTAssertEqual(history[0].taskContext, "Codex task: investigate disk growth")
        XCTAssertTrue(history[0].covers(instant.addingTimeInterval(80)))

        let expiring = try await restarted.register(
            .init(
                client: .claude,
                sessionID: "expires",
                process: .init(pid: 801, startTime: instant),
                workspaceRoots: ["/fixture/project"],
                registeredAt: instant.addingTimeInterval(100),
                expiresAt: instant.addingTimeInterval(170),
                taskContext: "Claude session"
            ),
            proof: proof,
            now: instant.addingTimeInterval(100)
        )
        let expiredCount = try await restarted.expireStale(at: instant.addingTimeInterval(171))
        XCTAssertEqual(expiredCount, 1)
        let afterExpiry = try await store.agentSession(id: expiring.registrationID)
        XCTAssertEqual(afterExpiry?.lifecycle, .expired)
        XCTAssertEqual(afterExpiry?.endedAt, instant.addingTimeInterval(170))
    }

    func testOverlappingSessionsGapsDeleteAndPathReuseNeverInventAuthorship() throws {
        let old = registration(id: UUID(), sessionID: "one")
        let overlapping = AgentSessionRegistration(
            registrationID: UUID(),
            client: .claude,
            sessionID: "two",
            process: .init(pid: 901, startTime: instant.addingTimeInterval(-40)),
            workspaceRoots: old.workspaceRoots,
            registeredAt: old.registeredAt,
            expiresAt: old.expiresAt,
            endedAt: nil,
            lifecycle: .active,
            authentication: .init(challengeDigest: digest)
        )
        for operation in [EvidenceStoreEvent.Operation.rename, .delete, .replace] {
            let event = makeEvent(id: "event-\(operation.rawValue)", operation: operation, path: "/fixture/project/reused.txt")
            let claim = ProvenanceEngine().attribute(.init(
                event: event,
                fsevents: [.init(path: event.path, eventID: 77, observedAt: instant, kind: .renamed, requiresRescan: true)],
                fseventGap: true,
                registrations: [old, overlapping],
                occurredStart: instant.addingTimeInterval(-300),
                occurredEnd: instant
            ))
            XCTAssertEqual(claim.confidence, .unknown)
            XCTAssertNil(claim.actor)
            XCTAssertNil(claim.session)
            XCTAssertTrue(claim.limitations.contains { $0.contains("gap") || $0.contains("Multiple") })
        }
    }

    func testEvidenceBundleExportsPersistedActorSessionMethodAndSupportWithoutSynthesis() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try EvidenceStore(url: fixture.databaseURL)
        let event = makeEvent(id: "event-export-provenance", operation: .create, path: "/fixture/project/output.json")
        try await store.insert(event)
        let task = registration(id: UUID(), sessionID: "exported-task")
        try await store.persistAgentSession(task)
        let writer = ProcessIdentity(pid: 950, startTime: instant.addingTimeInterval(-10), executablePath: "/bin/zsh")
        let endpoint = try makeEndpoint(eventID: "endpoint-export", path: event.path, process: writer)
        let claim = ProvenanceEngine().attribute(.init(
            event: event,
            privilegedEvent: endpoint,
            registrations: [task],
            ancestry: .init(records: [
                .init(identity: writer, parent: task.process),
                .init(identity: task.process, parent: nil),
            ]),
            contradictions: ["fixture contradiction retained for review"],
            claimID: "claim-export"
        ))
        try await store.recordEndpointObservation(endpoint, evidenceEventID: event.eventID)
        try await store.persistProvenanceClaim(claim)
        let exported = try await EvidenceBundleExporter(identifierSource: { "provenance-fixture" }).export(
            store: store,
            options: .init(from: instant.addingTimeInterval(-1), through: instant.addingTimeInterval(1), pathDetail: .full),
            to: fixture.root.appending(path: "exports")
        )
        let compressed = try Data(contentsOf: exported.bundleURL.appending(path: "events.jsonl.zlib"))
        let lines = String(decoding: try ZlibCodec.decompress(compressed), as: UTF8.self).split(separator: "\n")
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(lines.first).utf8))
        let object = try XCTUnwrap(value.objectValue)

        XCTAssertEqual(object["actor"]?.objectValue?["process_id"], .integer(950))
        XCTAssertEqual(object["actor"]?.objectValue?["executable"], .string("/bin/zsh"))
        XCTAssertEqual(object["session"]?.objectValue?["provider"], .string("codex"))
        XCTAssertEqual(object["session"]?.objectValue?["session_id"], .string("exported-task"))
        XCTAssertEqual(object["attribution"]?.objectValue?["method"], .string("direct-process-file-and-task-observation"))
        XCTAssertEqual(object["attribution"]?.objectValue?["confidence"], .string("exact"))
        guard case let .array(references)? = object["evidence"] else { return XCTFail("missing support references") }
        XCTAssertTrue(references.contains { $0.objectValue?["kind"] == .string("endpoint-security") })
        guard case let .array(limitations)? = object["attribution"]?.objectValue?["limitations"] else {
            return XCTFail("missing limitations")
        }
        XCTAssertTrue(limitations.contains { $0.stringValue?.contains("Contradiction") == true })
    }

    private func makeObservation(in store: EvidenceStore, id: String) async throws {
        let snapshot = StorageSnapshot(
            snapshotID: "snapshot-\(id)",
            observedAt: ISO8601DateFormatter().string(from: instant),
            volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 500, isInternal: true, isReadOnly: false)]
        )
        let metadata = MetadataSnapshot(
            observationID: id,
            scopeVersionID: "scope-v1",
            observedAt: instant,
            entries: [:],
            rootCoverage: [.init(rootPath: "/fixture", coverage: .complete)],
            limitations: []
        )
        _ = try await store.recordObservation(
            snapshot: snapshot,
            metadata: metadata,
            scope: .init(scopeVersionID: "scope-v1", effectiveAt: instant, rootPaths: ["/fixture"], excludedPaths: [], maximumEntries: 100, maximumDepth: 5),
            trigger: .fsevent,
            eventGap: true
        )
    }

    private func makeEvent(id: String, operation: EvidenceStoreEvent.Operation, path: String) -> EvidenceStoreEvent {
        .init(eventID: id, observedAt: instant, operation: operation, path: path, logicalDelta: 100, allocatedDelta: 128, consumerCategory: "agent-artifact", confidence: .inferred)
    }

    private func makeEndpoint(
        eventID: String,
        destination: String? = nil,
        path: String = "/fixture/artifact.json",
        process: ProcessIdentity? = nil
    ) throws -> NormalizedPrivilegedEvent {
        let raw = RawPrivilegedNotification(
            eventID: eventID,
            streamID: "endpoint-stream",
            sequence: 42,
            observedAt: instant,
            operation: destination == nil ? .create : .rename,
            path: path,
            destinationPath: destination,
            process: process ?? .init(pid: 702, startTime: instant.addingTimeInterval(-10), executablePath: "/bin/zsh"),
            fileIdentity: .init(volumeID: "data", fileID: 44, generation: 2),
            size: .init(logicalBefore: 0, logicalAfter: 100, allocatedBefore: 0, allocatedAfter: 128, method: "fstat")
        )
        return try XCTUnwrap(EndpointEventNormalizer().normalize(raw, scope: .init(watchedRoots: ["/fixture"], excludedRoots: []), gapBefore: false))
    }

    private func registration(
        id: UUID,
        sessionID: String,
        lifecycle: AgentSessionLifecycle = .active
    ) -> AgentSessionRegistration {
        .init(
            registrationID: id,
            client: .codex,
            sessionID: sessionID,
            process: .init(pid: 900, startTime: instant.addingTimeInterval(-50), executablePath: "/usr/bin/codex"),
            workspaceRoots: ["/fixture/project"],
            registeredAt: instant.addingTimeInterval(-100),
            expiresAt: instant.addingTimeInterval(100),
            endedAt: lifecycle == .active ? nil : instant.addingTimeInterval(50),
            lifecycle: lifecycle,
            authentication: .init(challengeDigest: digest),
            taskContext: "task context"
        )
    }
}

private struct Fixture {
    let root: URL
    let databaseURL: URL

    init() throws {
        root = URL(fileURLWithPath: "/tmp/ds-provenance-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        databaseURL = root.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
