@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

/// TASK-653: with file scanning retired the MCP backend never opens or
/// creates `evidence.sqlite`. File-level tools say why they cannot answer,
/// capacity and journal answers continue, sessions still register, and
/// `export_evidence` reads a clone of the legacy set without changing it.
final class RetiredDetailBackendTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: "/tmp/ds-retired-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: support) }

    private func makeLegacy(now: Date) async throws -> LegacyEvidenceManifest {
        let watched = support.appending(path: "watched", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: watched.appending(path: "legacy-artifact.bin"))
        let store = try EvidenceStore(url: support.appending(path: "evidence.sqlite"))
        try await store.insert(.init(eventID: "legacy-1", observedAt: now.addingTimeInterval(-3_600), operation: .create,
                                     path: watched.appending(path: "legacy-artifact.bin").path, logicalDelta: 4_096, allocatedDelta: 4_096,
                                     consumerCategory: "watched-root", confidence: .unknown))
        await store.close()
        return try XCTUnwrap(try LegacyEvidence.migrate(supportDirectory: support, at: now, migratedBy: "test"))
    }

    private func client(_ backend: AppEvidenceQueryBackend) throws -> (UnixSocketEvidenceServer, UnixSocketDiskStewardIPCClient) {
        let socket = support.appending(path: "s.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        return (server, UnixSocketDiskStewardIPCClient(socketPath: socket))
    }

    func testFileLevelToolsSayScanningIsRetiredAndNothingCreatesTheOldStore() async throws {
        let now = Date()
        let manifest = try await makeLegacy(now: now)
        let legacyMain = LegacyEvidence.databaseURL(of: manifest, in: support)
        let digest = try LegacyEvidence.hash(legacyMain).1
        let backend = try AppEvidenceQueryBackend(databaseURL: support.appending(path: "evidence.sqlite"),
                                                  fileDetail: .retired(supportDirectory: support))
        let (server, client) = try client(backend)
        defer { server.stop() }

        let summary = try XCTUnwrap(try client.call(tool: "get_storage_summary", arguments: [:], isCancelled: { false }).objectValue)
        XCTAssertEqual(summary["detail_status"], .string("unavailable"))
        guard case let .array(reasons)? = summary["detail_reasons"] else { return XCTFail("no reasons") }
        XCTAssertFalse(reasons.isEmpty)
        XCTAssertTrue(reasons.allSatisfy { $0.stringValue?.hasSuffix(": file-level scanning is retired") == true }, "\(reasons)")

        for tool in ["list_current_consumers", "get_evidence_lifecycle", "find_cleanup_candidates"] {
            do { _ = try client.call(tool: tool, arguments: [:], isCancelled: { false }); XCTFail("\(tool) answered from a retired store") }
            catch DiskStewardIPCError.remote(let code, let message, let retryable) {
                XCTAssertEqual(code, "detail_unavailable", tool)
                XCTAssertEqual(message, AppEvidenceQueryBackend.retiredDetailMessage, tool)
                XCTAssertFalse(retryable, "retrying cannot help")
            }
        }
        let formatter = ISO8601DateFormatter()
        let window: [String: JSONValue] = ["from": .string(formatter.string(from: now.addingTimeInterval(-7_200))), "through": .string(formatter.string(from: now))]
        let growth = try XCTUnwrap(try client.call(tool: "explain_growth", arguments: window, isCancelled: { false }).objectValue)
        XCTAssertEqual(growth["detail_reasons"], .array([.string("file-level scanning is retired")]))

        _ = try client.send(method: "sessions/register", payload: .object([
            "client": .string("codex"), "session_id": .string("retired-task"),
            "workspace_roots": .array([.string(support.path)]), "lease_seconds": .integer(600),
        ]), isCancelled: { false })
        let sessions = try XCTUnwrap(try client.call(tool: "list_active_agent_sessions", arguments: [:], isCancelled: { false }).objectValue)
        guard case let .array(listed)? = sessions["sessions"] else { return XCTFail("no sessions") }
        XCTAssertEqual(listed.count, 1, "sessions are kept in memory")

        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path + "/evidence.sqlite"), "the old store path is never recreated")
        XCTAssertEqual(try LegacyEvidence.hash(legacyMain).1, digest)
    }

    func testExportReadsALegacyCloneAndLeavesTheSetUnchanged() async throws {
        let now = Date()
        let manifest = try await makeLegacy(now: now)
        let legacy = LegacyEvidence.directory(in: support)
        let legacyMain = LegacyEvidence.databaseURL(of: manifest, in: support)
        let digest = try LegacyEvidence.hash(legacyMain).1
        let listing = try FileManager.default.contentsOfDirectory(atPath: legacy.path).sorted()
        let backend = try AppEvidenceQueryBackend(databaseURL: support.appending(path: "evidence.sqlite"),
                                                  fileDetail: .retired(supportDirectory: support))
        let (server, client) = try client(backend)
        defer { server.stop() }
        let formatter = ISO8601DateFormatter()
        let bundle = try XCTUnwrap(try client.call(tool: "export_evidence", arguments: [
            "from": .string(formatter.string(from: now.addingTimeInterval(-86_400))), "through": .string(formatter.string(from: now)),
            "path_detail": .string("basename"),
        ], isCancelled: { false }).objectValue)
        XCTAssertEqual(bundle["schema"], .string("inline-evidence-bundle-v1"))
        guard case let .array(events)? = bundle["events"] else { return XCTFail("no events") }
        XCTAssertEqual(events.first?.objectValue?["path"], .string("legacy-artifact.bin"), "the export carries the legacy evidence")

        XCTAssertEqual(try LegacyEvidence.hash(legacyMain).1, digest, "the legacy set is unchanged")
        let after = try FileManager.default.contentsOfDirectory(atPath: legacy.path).sorted().filter { !$0.hasPrefix(".export-clone-") }
        XCTAssertEqual(after, listing, "no sidecar appeared beside the legacy set")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path + "/evidence.sqlite"))
    }

    func testExportWithoutLegacyEvidenceSaysSo() async throws {
        let backend = try AppEvidenceQueryBackend(databaseURL: support.appending(path: "evidence.sqlite"),
                                                  fileDetail: .retired(supportDirectory: support))
        let (server, client) = try client(backend)
        defer { server.stop() }
        do {
            _ = try client.call(tool: "export_evidence", arguments: ["from": .string("2026-01-01T00:00:00Z"), "through": .string("2026-01-02T00:00:00Z")], isCancelled: { false })
            XCTFail("an export with nothing to export")
        } catch DiskStewardIPCError.remote(let code, _, _) {
            XCTAssertEqual(code, "no_legacy_evidence")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path + "/evidence.sqlite"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LegacyEvidence.directory(in: support).path))
    }
}
