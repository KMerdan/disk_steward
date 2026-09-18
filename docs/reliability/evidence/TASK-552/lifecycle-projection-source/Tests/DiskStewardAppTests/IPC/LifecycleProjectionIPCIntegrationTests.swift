@testable import DiskStewardCore
@testable import DiskStewardApp
import Foundation
import XCTest

final class LifecycleProjectionIPCIntegrationTests: XCTestCase {
    func testOversizedLifecycleMetadataReturnsTypedNonretryableErrorThroughIPC() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-summary-budget-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        _ = try await store.applyRetention(try .init(), trigger: .manual)
        await store.close()
        let fixture = try SQLiteConnection(url: database)
        try fixture.execute("UPDATE retention_runs SET limitations = zeroblob(600000)")
        fixture.close()
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        for name in ["get_evidence_lifecycle", "get_storage_summary", "explain_growth"] {
            let arguments: [String: JSONValue] = name == "explain_growth" ? [
                "from": .string("2026-01-01T00:00:00Z"), "through": .string("2026-01-02T00:00:00Z")
            ] : [:]
            do { _ = try client.call(tool: name, arguments: arguments, isCancelled: { false }); XCTFail("Expected budget refusal") }
            catch DiskStewardIPCError.remote(let code, _, let retryable) {
                XCTAssertEqual(code, "query_budget_exceeded")
                XCTAssertFalse(retryable)
            }
        }
    }

    func testLifecycleDoesNotDecodeThePrivateTraversalCheckpoint() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-summary-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let watch = root.appending(path: "watch").path
        let now = Date()
        let scope = EvidenceScopeVersion(scopeVersionID: "summary-scope", effectiveAt: now,
            rootPaths: [watch], excludedPaths: [], maximumEntries: 100_000, maximumDepth: 20)
        let store = try EvidenceStore(url: database)
        let initial = try await store.beginOrResumeScanGeneration(scope: scope, at: now)
        let generation = MetadataScanGeneration(generationID: initial.generationID,
            scopeVersionID: scope.scopeVersionID, rootPaths: scope.rootPaths, excludedPaths: [], status: .active,
            roots: [.init(rootPath: watch, status: .pending,
                frontier: (0..<4_000).map { .init(directoryPath: watch + "/private-frontier-\($0)", depth: 1) })],
            processedEntryCount: 123, stagedFileCount: 0, startedAt: now, updatedAt: now,
            reconciliationToken: initial.reconciliationToken)
        _ = try await store.recordScanSlice(snapshot: .init(snapshotID: "summary", observedAt: EvidenceTimestamp.format(now), volumes: []),
            slice: .init(generation: generation, entries: []), scope: scope, trigger: .scheduled)
        await store.close()
        // This intentionally undecodable checkpoint is an access sentinel: a
        // public summary must use its independently persisted scalar projection.
        // It is not a claim that the scanner can resume corrupt private state.
        let connection = try SQLiteConnection(url: database)
        try connection.execute("UPDATE scan_generations SET progress = zeroblob(1048576)")
        connection.close()
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let client = UnixSocketDiskStewardIPCClient(socketPath: socket)
        let response = try client.call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
        let status = try XCTUnwrap(response.objectValue?["status"]?.objectValue)
        let coverage = try XCTUnwrap(status["scan_coverage"]?.objectValue)
        let active = try XCTUnwrap(coverage["active_generation"]?.objectValue)
        XCTAssertEqual(active["processed_entry_count"], .integer(123))
        XCTAssertEqual(active["pending_directory_count"], .integer(4_000))
        XCTAssertEqual(active["frontier_omitted"], .bool(true))
        XCTAssertEqual(coverage["latest_generation"], .null)
        XCTAssertEqual(coverage["detail_coverage"], .string("partial"))
        XCTAssertEqual(response.objectValue?["coverage"], .string("partial"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let bytes = try encoder.encode(response)
        XCTAssertLessThan(bytes.count, 16_384)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-frontier"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(root.path))
    }

    func testEmptyLifecycleDoesNotClaimCompleteCoverageOrRefreshUserExportInventory() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-summary-empty-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let now = Date()
        let store = try EvidenceStore(url: database)
        for status in [EvidenceExportStatus.creating, .available] {
        try await store.persistExportRecord(.init(exportID: "user-owned", kind: .manual,
            requestedFrom: now, requestedThrough: now, actualFrom: nil, actualThrough: nil,
            precision: "unknown", pathDetail: .basename, path: root.appending(path: "private-export").path,
            bytes: 0, manifestSHA256: nil, createdAt: now, updatedAt: now, status: status, failure: nil))
        }
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let socket = root.appending(path: "ipc/service.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        defer { server.stop() }
        let response = try UnixSocketDiskStewardIPCClient(socketPath: socket).call(tool: "get_evidence_lifecycle", arguments: [:], isCancelled: { false })
        XCTAssertEqual(response.objectValue?["coverage"], .string("unknown"))
        let exports = try await store.exportRecords()
        XCTAssertEqual(exports.first?.status, .available, "A read-only MCP status request must not stat or mutate user export inventory")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        XCTAssertFalse(String(decoding: try encoder.encode(response), as: UTF8.self).contains(root.path))
        await store.close()
    }
}
