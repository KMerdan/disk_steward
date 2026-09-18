import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

final class BackendIsolationTests: XCTestCase {
    func testOverlappingInlineExportsUseSeparateWorkspacesAndCleanTheirPayloads() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ds-overlapping-exports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appending(path: "evidence.sqlite")
        let backend = try AppEvidenceQueryBackend(databaseURL: database)
        let peer = IPCPeerIdentity(uid: getuid(), gid: getgid(), pid: getpid())
        let request = JSONValue.object([
            "name": .string("export_evidence"),
            "arguments": .object([
                "from": .string("2026-09-16T00:00:00Z"),
                "through": .string("2026-09-17T00:00:00Z"),
                "path_detail": .string("basename"),
            ]),
        ])
        async let first = backend.handleIPC(method: "tools/call", payload: request, peer: peer)
        async let second = backend.handleIPC(method: "tools/call", payload: request, peer: peer)
        let results = try await [first, second]
        XCTAssertTrue(results.allSatisfy { $0.objectValue?["schema"] == .string("inline-evidence-bundle-v1") })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "temporary-exports").path).isEmpty)
        let store = try EvidenceStore(url: database)
        let records = try await store.exportRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.status == .destroyed && $0.path == nil })
        await store.close()
    }

    func testRequestCleanupPreservesSiblingAndReplacementDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ds-workspaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try InlineExportWorkspace(parent: root)
        let second = try InlineExportWorkspace(parent: root)
        let bytes = Data("other-request".utf8)
        let sentinel = second.directory.appending(path: "sentinel")
        try bytes.write(to: sentinel)
        first.removeIfOwned()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)

        let original = root.appending(path: "original-held-inode")
        try FileManager.default.moveItem(at: second.directory, to: original)
        try FileManager.default.createDirectory(at: second.directory, withIntermediateDirectories: false)
        let replacement = second.directory.appending(path: "foreign-sentinel")
        try bytes.write(to: replacement)
        second.removeIfOwned()
        XCTAssertEqual(try Data(contentsOf: replacement), bytes)
        XCTAssertEqual(try Data(contentsOf: original.appending(path: "sentinel")), bytes)
    }

    func testWorkspaceRefusesSymlinkOrNonprivateParentBeforeCreatingChildren() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ds-workspaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try InlineExportWorkspace(parent: link))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        XCTAssertThrowsError(try InlineExportWorkspace(parent: target))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testBackendInitializationNeverSweepsAnotherInstancesTemporaryExports() async throws {
        try await checkForeignExportPreserved(failDatabaseOpen: false)
    }

    func testFailedBackendInitializationNeverSweepsAnotherInstancesTemporaryExports() async throws {
        try await checkForeignExportPreserved(failDatabaseOpen: true)
    }

    private func checkForeignExportPreserved(failDatabaseOpen: Bool) async throws {
        let temp = FileManager.default.temporaryDirectory.appending(path: "ds-backend-isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let exportBase = temp.appending(path: "explicit-exports", directoryHint: .isDirectory)
        let foreign = exportBase.appending(path: "foreign-instance", directoryHint: .isDirectory)
        let fixture = temp.appending(path: "database-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temp)
        }
        let sentinel = foreign.appending(path: "still-in-use.json")
        let bytes = Data("another-instance-owned-export".utf8)
        try bytes.write(to: sentinel)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7 * 60 * 60)], ofItemAtPath: foreign.path)
        if failDatabaseOpen {
            let blocker = fixture.appending(path: "not-a-directory")
            try Data("sentinel".utf8).write(to: blocker)
            XCTAssertThrowsError(try AppEvidenceQueryBackend(databaseURL: blocker.appending(path: "evidence.sqlite"), temporaryExportDirectory: exportBase))
        } else {
            let backend = try AppEvidenceQueryBackend(databaseURL: fixture.appending(path: "evidence.sqlite"), temporaryExportDirectory: exportBase)
            _ = backend // Initialization alone must be side-effect-free outside its database.
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    }
}
