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
        XCTAssertEqual(exported.objectValue?["manifest"]?.objectValue?["schema"], .string("export-manifest-v1"))
        guard case let .array(events)? = exported.objectValue?["events"] else {
            return XCTFail("missing inline event detail")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.objectValue?["path"], .string("artifact.zip"))

        let impact = try client.call(
            tool: "get_task_impact",
            arguments: ["session_id": .string("integration-task"), "limit": .integer(100)],
            isCancelled: { false }
        )
        XCTAssertEqual(impact.objectValue?["confidence"], .string("inferred"))
        XCTAssertEqual(impact.objectValue?["allocated_delta"], .integer(4_096))

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

    private func shortTemporaryRoot(prefix: String) -> URL {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return URL(fileURLWithPath: "/tmp/\(prefix)-\(suffix)", isDirectory: true)
    }
}
