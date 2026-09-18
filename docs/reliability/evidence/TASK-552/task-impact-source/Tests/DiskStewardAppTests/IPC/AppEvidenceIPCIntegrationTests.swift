import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

final class AppEvidenceIPCIntegrationTests: XCTestCase {
    func testPrivateUnixSocketServesRealSummarySessionAndExportQueries() async throws {
        let root = shortTemporaryRoot(prefix: "ds-ipc")
        let database = root.appending(path: "evidence.sqlite")
        let socket = root.appending(path: "private/service.sock")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: backend)
        try server.start()
        defer { server.stop() }

        let client = UnixSocketDiskStewardIPCClient(socketPath: socket.path)
        let summary = try client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })
        XCTAssertEqual(summary.objectValue?["schema"], .string("storage-summary-v1"))
        guard case let .array(volumes)? = summary.objectValue?["volumes"] else {
            return XCTFail("missing live volume summary")
        }
        XCTAssertFalse(volumes.isEmpty)

        let registered = try client.send(
            method: "sessions/register",
            payload: .object([
                "client": .string("codex"),
                "session_id": .string("integration-task"),
                "workspace_roots": .array([.string(root.path)]),
                "lease_seconds": .integer(600),
            ]),
            isCancelled: { false }
        )
        XCTAssertEqual(registered.objectValue?["session_id"], .string("integration-task"))
        XCTAssertEqual(registered.objectValue?["confidence"], .string("tool-linked"))
        let registrationID = try XCTUnwrap(registered.objectValue?["registration_id"]?.stringValue)

        let active = try client.call(tool: "list_active_writers", arguments: [:], isCancelled: { false })
        guard case let .array(writers)? = active.objectValue?["writers"] else {
            return XCTFail("missing active process trees")
        }
        XCTAssertEqual(writers.first?.objectValue?["session_id"], .string("integration-task"))
        XCTAssertEqual(writers.first?.objectValue?["confidence"], .string("tool-linked"))

        let eventTime = Date()
        let writer = try EvidenceStore(url: database)
        try await writer.insert(EvidenceStoreEvent(
            eventID: "ipc-event",
            observedAt: eventTime,
            operation: .writeSummary,
            path: root.appending(path: "artifact.zip").path,
            logicalDelta: 2_048,
            allocatedDelta: 4_096,
            consumerCategory: "agent-artifact",
            confidence: .inferred
        ))
        let formatter = ISO8601DateFormatter()
        let exported = try client.call(
            tool: "export_evidence",
            arguments: [
                "from": .string(formatter.string(from: eventTime.addingTimeInterval(-10))),
                "through": .string(formatter.string(from: eventTime.addingTimeInterval(10))),
                "path_detail": .string("basename"),
                "max_events": .integer(100),
            ],
            isCancelled: { false }
        )
        XCTAssertEqual(exported.objectValue?["schema"], .string("inline-evidence-bundle-v1"))
        XCTAssertEqual(exported.objectValue?["manifest"]?.objectValue?["schema"], .string("export-manifest-v2"))
        guard case let .array(events)? = exported.objectValue?["events"] else {
            return XCTFail("missing inline event detail")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.objectValue?["path"], .string("artifact.zip"))
        let exportRecords = try await writer.exportRecords()
        XCTAssertEqual(exportRecords.count, 1)
        XCTAssertEqual(exportRecords.first?.kind, .temporary)
        XCTAssertEqual(exportRecords.first?.status, .destroyed)
        XCTAssertNil(exportRecords.first?.path)
        let inlineExportRoot = root.appending(path: "temporary-exports")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: inlineExportRoot.path).isEmpty,
                      "No nested request workspace or payload may survive a served inline export")

        let impact = try client.call(
            tool: "get_task_impact",
            arguments: ["session_id": .string("integration-task"), "limit": .integer(100)],
            isCancelled: { false }
        )
        // A raw observation has no measured occurrence lower bound. Merely
        // noticing it after registration cannot establish task causation.
        XCTAssertEqual(impact.objectValue?["confidence"], .string("unknown"))
        XCTAssertEqual(impact.objectValue?["allocated_delta"], .integer(0))

        let ended = try client.send(
            method: "sessions/end",
            payload: .object(["registration_id": .string(registrationID)]),
            isCancelled: { false }
        )
        XCTAssertEqual(ended.objectValue?["lifecycle"], .string("ended"))
    }

    func testServerRemovesOwnedSocketAndClientReportsUnavailableAfterStop() async throws {
        let root = shortTemporaryRoot(prefix: "ds-stop")
        let socket = root.appending(path: "private/service.sock")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try AppEvidenceQueryBackend(databaseURL: root.appending(path: "evidence.sqlite"))
        let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: backend)
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))

        let client = UnixSocketDiskStewardIPCClient(socketPath: socket.path)
        XCTAssertThrowsError(try client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false })) { error in
            XCTAssertEqual(error as? DiskStewardIPCError, .appUnavailable)
        }
    }

    func testEndedSessionHeartbeatAndHistoricalImpactSurviveBackendRestart() async throws {
        let root = shortTemporaryRoot(prefix: "ds-session-restart")
        let database = root.appending(path: "evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = IPCPeerIdentity(uid: getuid(), gid: getgid(), pid: getpid())
        var backend: AppEvidenceQueryBackend? = try AppEvidenceQueryBackend(databaseURL: database)
        let registered = try await backend!.handleIPC(
            method: "sessions/register",
            payload: .object([
                "client": .string("codex"),
                "session_id": .string("historical-task"),
                "workspace_roots": .array([.string(root.path)]),
                "task_context": .string("Codex task retained across app restart"),
                "lease_seconds": .integer(600),
            ]),
            peer: peer
        )
        let registrationID = try XCTUnwrap(registered.objectValue?["registration_id"]?.stringValue)
        let heartbeat = try await backend!.handleIPC(
            method: "sessions/heartbeat",
            payload: .object(["registration_id": .string(registrationID), "lease_seconds": .integer(900)]),
            peer: peer
        )
        XCTAssertEqual(heartbeat.objectValue?["lifecycle"], .string("active"))

        let eventTime = Date()
        let writer = try EvidenceStore(url: database)
        try await writer.insert(.init(
            eventID: "historical-impact-event",
            observedAt: eventTime,
            operation: .create,
            path: root.appending(path: "artifact.zip").path,
            logicalDelta: 2_048,
            allocatedDelta: 4_096,
            consumerCategory: "agent-artifact",
            confidence: .inferred
        ))
        let ended = try await backend!.handleIPC(
            method: "sessions/end",
            payload: .object(["registration_id": .string(registrationID)]),
            peer: peer
        )
        XCTAssertEqual(ended.objectValue?["lifecycle"], .string("ended"))
        backend = nil

        let restarted = try AppEvidenceQueryBackend(databaseURL: database)
        let impact = try await restarted.handleIPC(
            method: "tools/call",
            payload: .object([
                "name": .string("get_task_impact"),
                "arguments": .object([
                    "session_id": .string("historical-task"),
                    "from": .string(ISO8601DateFormatter().string(from: eventTime.addingTimeInterval(-10))),
                    "through": .string(ISO8601DateFormatter().string(from: eventTime.addingTimeInterval(10))),
                    "limit": .integer(100),
                ]),
            ]),
            peer: peer
        )
        XCTAssertEqual(impact.objectValue?["allocated_delta"], .integer(0))
        XCTAssertEqual(impact.objectValue?["confidence"], .string("unknown"))
        XCTAssertEqual(impact.objectValue?["method"], .string("retained-session-temporal-and-workspace-correlation"))
        XCTAssertEqual(impact.objectValue?["session_lifecycle"], .array([.string("ended")]))
    }

    private func shortTemporaryRoot(prefix: String) -> URL {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return URL(fileURLWithPath: "/tmp/\(prefix)-\(suffix)", isDirectory: true)
    }
}
