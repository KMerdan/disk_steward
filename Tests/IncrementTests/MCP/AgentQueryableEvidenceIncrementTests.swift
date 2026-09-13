import AppKit
import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

@MainActor
final class AgentQueryableEvidenceIncrementTests: XCTestCase {
    func testAgentQueryableEvidenceIncrementComposesWithHumanJourneyAndFailsClosed() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-g390-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("evidence.sqlite")
        let socket = root.appendingPathComponent("private/evidence.sock")
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let service = UnixSocketEvidenceServer(socketPath: socket.path, handler: backend)
        try service.start()
        defer { service.stop() }

        let client = UnixSocketDiskStewardIPCClient(socketPath: socket.path)
        let registration = try client.send(
            method: "sessions/register",
            payload: .object([
                "client": .string("codex"),
                "session_id": .string("gate-390-task"),
                "workspace_roots": .array([.string(root.path)]),
                "lease_seconds": .integer(600),
            ]),
            isCancelled: { false }
        )
        XCTAssertEqual(registration.objectValue?["confidence"], .string("tool-linked"))

        // Keep the fixture clearly after registration even when exported timestamps
        // round to milliseconds; otherwise a same-tick event must correctly remain unknown.
        try await Task.sleep(for: .milliseconds(20))
        let observedAt = Date()
        let writer = try EvidenceStore(url: database)
        try await writer.insert(EvidenceStoreEvent(
            eventID: "gate-390-artifact",
            observedAt: observedAt,
            operation: .writeSummary,
            path: root.appendingPathComponent("codex-artifact.zip").path,
            logicalDelta: 1_024,
            allocatedDelta: 4_096,
            consumerCategory: "agent-artifact",
            confidence: .inferred
        ))
        await writer.close()

        let formatter = ISO8601DateFormatter()
        let from = formatter.string(from: observedAt.addingTimeInterval(-30))
        let through = formatter.string(from: observedAt.addingTimeInterval(30))
        let transcript = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"gate-390","version":"1"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"explain_growth","arguments":{"from":"\(from)","through":"\(through)","limit":100}}}
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_task_impact","arguments":{"session_id":"gate-390-task","limit":100}}}
        {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"export_evidence","arguments":{"from":"\(from)","through":"\(through)","path_detail":"basename","max_events":100}}}
        {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"find_cleanup_candidates","arguments":{"minimum_bytes":1,"older_than_days":0,"limit":100}}}
        {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"delete_file","arguments":{"path":"/tmp/never"}}}

        """
        let query = try runConnector(input: transcript, socket: socket.path)
        XCTAssertEqual(query.status, 0, query.stderr)
        XCTAssertLessThan(Data(query.stdout.utf8).count, 4 * 1_024 * 1_024)
        let responses = try responseMap(query.stdout)
        XCTAssertFalse(containsForbiddenKey(in: responses, names: ["file_contents", "environment", "environment_variables", "token", "secret", "credential", "password"]))

        let tools = try XCTUnwrap(responses[2]?["result"] as? [String: Any])
        let inventory = try XCTUnwrap(tools["tools"] as? [[String: Any]])
        XCTAssertEqual(inventory.count, 10)
        XCTAssertTrue(inventory.allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true })
        XCTAssertFalse(inventory.contains { ($0["name"] as? String)?.contains("delete") == true })

        XCTAssertEqual(try structured(responses, id: 3)["schema"] as? String, "evidence-query-page-v1")
        let impact = try structured(responses, id: 4)
        XCTAssertEqual(impact["schema"] as? String, "task-impact-v1")
        XCTAssertEqual(impact["confidence"] as? String, "inferred")
        XCTAssertEqual((impact["allocated_delta"] as? NSNumber)?.int64Value, 4_096)

        let exported = try structured(responses, id: 5)
        XCTAssertEqual(exported["schema"] as? String, "inline-evidence-bundle-v1")
        XCTAssertEqual((exported["events"] as? [[String: Any]])?.first?["path"] as? String, "codex-artifact.zip")
        let direct = try client.call(
            tool: "export_evidence",
            arguments: [
                "from": .string(from),
                "through": .string(through),
                "path_detail": .string("basename"),
                "max_events": .integer(100),
            ],
            isCancelled: { false }
        )
        XCTAssertEqual(exported["summary"] as? NSDictionary, jsonObject(direct)?["summary"] as? NSDictionary)
        XCTAssertEqual(exported["events"] as? NSArray, jsonObject(direct)?["events"] as? NSArray)

        let candidates = try structured(responses, id: 6)
        XCTAssertEqual(candidates["safety"] as? String, "review-required-never-safe-to-delete-claim")
        XCTAssertNotNil(responses[7]?["error"])

        let fixtureSnapshot = StorageSnapshot(
            snapshotID: "gate-390-human",
            observedAt: "2026-09-13T00:00:00.000Z",
            volumes: [.init(mountPath: "/fixture", totalBytes: 1_000, availableBytes: 400, isInternal: true, isReadOnly: false)],
            limitations: ["Increment audit fixture."]
        )
        let humanExportRoot = root.appendingPathComponent("human-export")
        let model = StatusBoardViewModel(snapshotLoader: { fixtureSnapshot }, exportParent: { humanExportRoot })
        model.refresh()
        XCTAssertEqual(model.usedFraction, 0.6, accuracy: 0.001)
        XCTAssertNotNil(model.exportCurrentSnapshot())
        XCTAssertEqual(StatusItemSurface.route(for: .leftMouseUp), .statusBoard)
        XCTAssertEqual(StatusItemSurface.route(for: .rightMouseUp), .utilityMenu)
        XCTAssertEqual([AppMenuLabels.generalExport, AppMenuLabels.settings, AppMenuLabels.about, AppMenuLabels.quit], ["Export Current Evidence", "Settings…", "About Disk Steward", "Quit Disk Steward"])

        service.stop()
        let unavailableTranscript = """
        {"jsonrpc":"2.0","id":8,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"gate-390","version":"1"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        {"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_storage_summary","arguments":{}}}

        """
        let unavailable = try runConnector(input: unavailableTranscript, socket: socket.path)
        XCTAssertEqual(unavailable.status, 0)
        let unavailableResponses = try responseMap(unavailable.stdout)
        let degraded = try structured(unavailableResponses, id: 9)
        XCTAssertEqual(degraded["code"] as? String, "app_unavailable")
        XCTAssertTrue((degraded["recovery"] as? String)?.contains("Open Disk Steward") == true)
    }

    private func runConnector(input: String, socket: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            repository.appendingPathComponent(".build/debug/disk-witness-mcp"),
            repository.appendingPathComponent(".build/arm64-apple-macosx/debug/disk-witness-mcp"),
        ]
        let executable = try XCTUnwrap(candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }))
        let process = Process()
        process.executableURL = executable
        process.environment = ProcessInfo.processInfo.environment.merging(["DISK_STEWARD_SOCKET_PATH": socket]) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func responseMap(_ transcript: String) throws -> [Int: [String: Any]] {
        var result: [Int: [String: Any]] = [:]
        for line in transcript.split(separator: "\n") {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if let id = (object["id"] as? NSNumber)?.intValue { result[id] = object }
        }
        return result
    }

    private func structured(_ responses: [Int: [String: Any]], id: Int) throws -> [String: Any] {
        let result = try XCTUnwrap(responses[id]?["result"] as? [String: Any])
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    private func jsonObject(_ value: JSONValue) -> [String: Any]? {
        guard let data = try? JSONEncoder.diskSteward.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func containsForbiddenKey(in value: Any, names: Set<String>) -> Bool {
        if let object = value as? [AnyHashable: Any] {
            for (key, child) in object {
                if let string = key as? String, names.contains(string.lowercased()) { return true }
                if containsForbiddenKey(in: child, names: names) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains { containsForbiddenKey(in: $0, names: names) }
        }
        return false
    }
}
