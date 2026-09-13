import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

final class AuthoritativeMCPReadModelTests: XCTestCase, @unchecked Sendable {
    func testCleanupCandidateIsWithdrawnIfFileGainsHardLinkAfterObservation() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-mcp-hardlink-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        let candidate = root.appending(path: "candidate.bin")
        let secondLink = root.appending(path: "same-object.bin")
        let database = root.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4_096).write(to: candidate)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let policy = MonitoringPolicy(watchedRoots: [root], excludedRoots: [database])
        let metadata = DirectoryMetadataScanner().scan(policy: policy, at: now)
        let writer = try EvidenceStore(url: database)
        _ = try await writer.recordObservation(
            snapshot: .init(snapshotID: "mcp-hardlink", observedAt: ISO8601DateFormatter().string(from: now), volumes: []),
            metadata: metadata,
            scope: policy.scopeVersion(at: now),
            trigger: .scheduled
        )
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let peer = IPCPeerIdentity(uid: getuid(), gid: getgid(), pid: getpid())

        let before = try await call(backend, peer: peer, tool: "find_cleanup_candidates", arguments: [
            "minimum_bytes": .integer(1), "limit": .integer(10), "path_detail": .string("full"),
        ])
        XCTAssertEqual(before.objectValue?["returned_count"], .integer(1))

        try FileManager.default.linkItem(at: candidate, to: secondLink)

        let after = try await call(backend, peer: peer, tool: "find_cleanup_candidates", arguments: [
            "minimum_bytes": .integer(1), "limit": .integer(10), "path_detail": .string("full"),
        ])
        XCTAssertEqual(after.objectValue?["returned_count"], .integer(0))
    }

    func testCleanupCandidateMustStillBeTheSameLiveFileAndLifecycleIsQueryable() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-mcp-read-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
        let candidate = downloads.appending(path: "candidate.bin")
        let held = downloads.appending(path: "held-original.bin")
        let database = root.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4_096).write(to: candidate)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let policy = MonitoringPolicy(watchedRoots: [downloads])
        let metadata = DirectoryMetadataScanner().scan(policy: policy, at: now)
        let writer = try EvidenceStore(url: database)
        _ = try await writer.recordObservation(
            snapshot: .init(snapshotID: "mcp-current", observedAt: ISO8601DateFormatter().string(from: now), volumes: []),
            metadata: metadata,
            scope: policy.scopeVersion(at: now),
            trigger: .scheduled
        )
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let peer = IPCPeerIdentity(uid: getuid(), gid: getgid(), pid: getpid())

        let first = try await call(backend, peer: peer, tool: "find_cleanup_candidates", arguments: [
            "minimum_bytes": .integer(1), "limit": .integer(10), "path_detail": .string("full"),
        ])
        guard case let .array(firstItems)? = first.objectValue?["items"] else { return XCTFail("missing candidates") }
        XCTAssertEqual(firstItems.count, 1)
        XCTAssertEqual(firstItems.first?.objectValue?["path"], .string(candidate.path))
        XCTAssertEqual(firstItems.first?.objectValue?["review_required"], .bool(true))

        try FileManager.default.moveItem(at: candidate, to: held)
        try Data(repeating: 9, count: 4_096).write(to: candidate)
        let afterReuse = try await call(backend, peer: peer, tool: "find_cleanup_candidates", arguments: [
            "minimum_bytes": .integer(1), "limit": .integer(10), "path_detail": .string("full"),
        ])
        guard case let .array(reusedItems)? = afterReuse.objectValue?["items"] else { return XCTFail("missing candidates") }
        XCTAssertEqual(reusedItems, [], "A reused path must not inherit the old object's cleanup candidacy")

        let lifecycle = try await call(backend, peer: peer, tool: "get_evidence_lifecycle", arguments: [:])
        XCTAssertEqual(lifecycle.objectValue?["schema"], .string("evidence-lifecycle-v1"))
        XCTAssertNotNil(lifecycle.objectValue?["status"]?.objectValue?["tiers"])
        XCTAssertNotNil(lifecycle.objectValue?["status"]?.objectValue?["database_cap_bytes"])
    }

    func testTaskImpactSeparatesSurvivingBytesAndPartialCoverageExcludesCleanup() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-mcp-impact-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        let artifact = root.appending(path: "agent-artifact.bin")
        let databaseRoot = URL(fileURLWithPath: "/tmp/ds-mcp-impact-db-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        let database = databaseRoot.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: databaseRoot, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 8_192).write(to: artifact)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: databaseRoot)
        }

        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let peer = IPCPeerIdentity(uid: getuid(), gid: getgid(), pid: getpid())
        _ = try await backend.handleIPC(
            method: "sessions/register",
            payload: .object([
                "client": .string("codex"),
                "session_id": .string("surviving-task"),
                "workspace_roots": .array([.string(root.path)]),
                "lease_seconds": .integer(600),
            ]),
            peer: peer
        )
        let observedAt = Date()
        let policy = MonitoringPolicy(watchedRoots: [root])
        let metadata = DirectoryMetadataScanner().scan(policy: policy, at: observedAt)
        let writer = try EvidenceStore(url: database)
        _ = try await writer.recordObservation(
            snapshot: .init(snapshotID: "impact-current", observedAt: ISO8601DateFormatter().string(from: observedAt), volumes: []),
            metadata: metadata,
            scope: policy.scopeVersion(at: observedAt),
            trigger: .scheduled
        )
        let handle = try FileHandle(forWritingTo: artifact)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 4, count: 4_096))
        try handle.close()
        let eventAt = observedAt.addingTimeInterval(1)
        let changedMetadata = DirectoryMetadataScanner().scan(policy: policy, at: eventAt)
        let committed = try await writer.recordObservation(
            snapshot: .init(snapshotID: "impact-growth", observedAt: ISO8601DateFormatter().string(from: eventAt), volumes: []),
            metadata: changedMetadata,
            scope: policy.scopeVersion(at: eventAt),
            trigger: .scheduled
        )
        let registrations = try await writer.agentSessions(sessionID: "surviving-task")
        let registration = try XCTUnwrap(registrations.first)
        let event = try XCTUnwrap(committed.events.first { $0.path == artifact.path })
        try await writer.persistProvenanceClaim(.init(
            event: event,
            actor: nil,
            session: .init(registration: registration, relationship: "workspace-temporal"),
            confidence: .inferred,
            method: "workspace-temporal-correlation",
            support: [.init(kind: .agentSession, identifier: registration.registrationID.uuidString.lowercased(), supports: "session context")],
            limitations: ["The session overlap does not prove a writer."]
        ))

        let formatter = ISO8601DateFormatter()
        let range: [String: JSONValue] = [
            "from": .string(formatter.string(from: eventAt.addingTimeInterval(-10))),
            "through": .string(formatter.string(from: eventAt.addingTimeInterval(10))),
        ]
        let impact = try await call(backend, peer: peer, tool: "get_task_impact", arguments: range.merging([
            "session_id": .string("surviving-task"), "limit": .integer(100),
        ]) { _, new in new })
        XCTAssertGreaterThan(impact.objectValue?["historical_growth_bytes"]?.integerValue ?? 0, 0)
        XCTAssertGreaterThan(impact.objectValue?["surviving_allocated_bytes"]?.integerValue ?? 0, 0)
        XCTAssertEqual(impact.objectValue?["surviving_object_count"], .integer(1))
        XCTAssertEqual(impact.objectValue?["confidence"], .string("inferred"))

        let current = try await call(backend, peer: peer, tool: "list_current_consumers", arguments: [
            "limit": .integer(10), "path_detail": .string("hashed"),
        ])
        guard case let .array(currentItems)? = current.objectValue?["items"],
              let shapedPath = currentItems.first?.objectValue?["path"]?.stringValue
        else { return XCTFail("missing current consumers") }
        XCTAssertTrue(shapedPath.hasPrefix("sha256:"))
        XCTAssertFalse(shapedPath.contains("agent-artifact.bin"))

        let partialAt = eventAt.addingTimeInterval(1)
        let partial = MetadataSnapshot(
            observationID: "partial",
            scopeVersionID: policy.scopeVersion(at: partialAt).scopeVersionID,
            observedAt: partialAt,
            entries: [:],
            rootCoverage: [.init(rootPath: root.path, coverage: .partial, limitations: ["fixture denied one subtree"])],
            limitations: ["fixture partial"]
        )
        _ = try await writer.recordObservation(
            snapshot: .init(snapshotID: "impact-partial", observedAt: formatter.string(from: partialAt), volumes: []),
            metadata: partial,
            scope: policy.scopeVersion(at: partialAt),
            trigger: .scheduled
        )
        let candidates = try await call(backend, peer: peer, tool: "find_cleanup_candidates", arguments: ["limit": .integer(10)])
        XCTAssertEqual(candidates.objectValue?["returned_count"], .integer(0))
        let growth = try await call(backend, peer: peer, tool: "explain_growth", arguments: range)
        XCTAssertEqual(growth.objectValue?["coverage"], .string("partial"))
    }

    private func call(
        _ backend: AppEvidenceQueryBackend,
        peer: IPCPeerIdentity,
        tool: String,
        arguments: [String: JSONValue]
    ) async throws -> JSONValue {
        try await backend.handleIPC(
            method: "tools/call",
            payload: .object(["name": .string(tool), "arguments": .object(arguments)]),
            peer: peer
        )
    }
}
