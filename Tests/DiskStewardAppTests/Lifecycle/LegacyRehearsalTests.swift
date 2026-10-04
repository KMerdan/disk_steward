@testable import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

/// TASK-653 EVREQ-01, opt-in: a captured copy of the real evidence store,
/// placed at `.captured/evidence.sqlite` inside an isolated snapshot (never a
/// live store), is moved to legacy/, exported through both export paths, and
/// rolled back by the shipped script with every byte intact.
@MainActor
final class LegacyRehearsalTests: XCTestCase {
    private func hash(_ url: URL) throws -> String { try LegacyEvidence.hash(url).1 }

    /// Row counts read from a clone, so the measured file is never opened.
    private func counts(_ database: URL, tables: [String]) throws -> [String: Int64] {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "rehearsal-count-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for suffix in ["", "-wal"] where FileManager.default.fileExists(atPath: database.path + suffix) {
            try FileManager.default.copyItem(atPath: database.path + suffix, toPath: scratch.path + "/evidence.sqlite" + suffix)
        }
        let connection = try SQLiteConnection(url: scratch.appending(path: "evidence.sqlite"))
        defer { connection.close() }
        var result: [String: Int64] = [:]
        for table in tables { result[table] = try connection.scalarInt("SELECT COUNT(*) FROM \(table)") }
        return result
    }

    func testCapturedStoreMovesExportsAndRollsBackByteForByte() async throws {
        let captured = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".captured/evidence.sqlite")
        guard FileManager.default.fileExists(atPath: captured.path) else { throw XCTSkip("No captured store in this snapshot") }
        let support = URL(fileURLWithPath: "/private/tmp/ds-rehearsal-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let database = support.appending(path: "evidence.sqlite")
        try FileManager.default.copyItem(at: captured, to: database)

        // Leave committed pages only in -wal, as the running 1.3.0 leaves them:
        // copy the files while a writer still holds the log open.
        let writer = try SQLiteConnection(url: database)
        try writer.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE rehearsal_probe (v TEXT); INSERT INTO rehearsal_probe VALUES ('only-in-wal');")
        let frozen = support.appending(path: "frozen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: frozen, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] { try FileManager.default.copyItem(atPath: database.path + suffix, toPath: frozen.path + "/evidence.sqlite" + suffix) }
        writer.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
            try FileManager.default.moveItem(atPath: frozen.path + "/evidence.sqlite" + suffix, toPath: database.path + suffix)
        }
        try FileManager.default.removeItem(at: frozen)

        let tables = ["file_objects", "current_file_state", "path_bindings", "file_state_observations", "retention_runs", "retention_coverage_gaps", "observation_runs", "coverage_gaps", "rehearsal_probe"]
        let before = try counts(database, tables: tables)
        let main = try hash(database)
        let wal = try hash(URL(fileURLWithPath: database.path + "-wal"))
        let bytes = try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? Int64 ?? 0
        let walBytes = try FileManager.default.attributesOfItem(atPath: database.path + "-wal")[.size] as? Int64 ?? 0
        XCTAssertEqual(before["rehearsal_probe"], 1)

        // 1. The first launch's move.
        var started = Date()
        let manifest = try XCTUnwrap(try LegacyEvidence.migrate(supportDirectory: support, at: Date(), migratedBy: "rehearsal"))
        let moveSeconds = Date().timeIntervalSince(started)
        let legacyMain = LegacyEvidence.databaseURL(of: manifest, in: support)
        XCTAssertEqual(try hash(legacyMain), main, "main file moved byte for byte")
        XCTAssertEqual(try hash(URL(fileURLWithPath: legacyMain.path + "-wal")), wal, "log moved byte for byte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        let legacy = LegacyEvidence.directory(in: support)
        let listing = try FileManager.default.contentsOfDirectory(atPath: legacy.path).sorted()
        let stamp = try FileManager.default.attributesOfItem(atPath: legacyMain.path)[.modificationDate] as? Date

        // 2. Export from the board or menu.
        let exports = support.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        started = Date()
        let bundle = try await LegacyEvidenceController.export(manifest, supportDirectory: support, to: exports)
        let uiExportSeconds = Date().timeIntervalSince(started)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.bundleURL.path))

        // 3. Export through MCP.
        let backend = try AppEvidenceQueryBackend(databaseURL: database, fileDetail: .retired(supportDirectory: support))
        let socket = support.appending(path: "s.sock").path
        let server = UnixSocketEvidenceServer(socketPath: socket, handler: backend)
        try server.start()
        let formatter = ISO8601DateFormatter()
        started = Date()
        // The real store's current state (about 100,000 files) is far above
        // the 2 MiB inline budget: the answer says so and points to the file
        // export, instead of a retryable size error.
        // TASK-671: export_evidence answers with the steward evidence and
        // says whether the legacy evidence fit; when it does not, it points
        // to the file export instead of failing.
        let inline = try UnixSocketDiskStewardIPCClient(socketPath: socket).call(tool: "export_evidence", arguments: [
            "from": .string(formatter.string(from: manifest.migratedAt.addingTimeInterval(-60 * 86_400))),
            "through": .string(formatter.string(from: manifest.migratedAt)), "max_events": .integer(50),
        ], isCancelled: { false })
        XCTAssertEqual(inline.objectValue?["schema"], .string("evidence-export-v2"))
        let legacyPart = try XCTUnwrap(inline.objectValue?["legacy"]?.objectValue)
        let mcpExport = legacyPart["status"]?.stringValue ?? "missing"
        if mcpExport == "too_large" {
            XCTAssertEqual(legacyPart["message"], .string(AppEvidenceQueryBackend.legacyExportTooLargeMessage))
        } else {
            XCTAssertEqual(mcpExport, "included")
        }
        let mcpExportSeconds = Date().timeIntervalSince(started)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path), "exports never recreate the old store")
        XCTAssertEqual(try hash(legacyMain), main, "exports leave the legacy set unchanged")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: legacy.path).sorted().filter { !$0.hasPrefix(".export-clone-") }, listing)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: legacyMain.path)[.modificationDate] as? Date, stamp)

        // 4. Rollback with the shipped script, then open with the store code 1.3.0 ships.
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Scripts/Distribution/restore-legacy-evidence")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, "--support-directory", support.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        started = Date()
        try process.run()
        process.waitUntilExit()
        let restoreSeconds = Date().timeIntervalSince(started)
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(try hash(database), main, "rolled back byte for byte")
        XCTAssertEqual(try hash(URL(fileURLWithPath: database.path + "-wal")), wal)
        XCTAssertEqual(try counts(database, tables: tables), before, "every table holds what it held before the move")
        let reopened = try EvidenceStore(url: database)
        let diagnostics = try await reopened.diagnostics()
        await reopened.close()
        XCTAssertEqual(diagnostics.integrity, "ok")

        let report: [String: Any] = [
            "database_bytes": bytes, "wal_bytes": walBytes, "counts": before, "move_seconds": moveSeconds,
            "ui_export_seconds": uiExportSeconds, "ui_bundle": bundle.bundleURL.lastPathComponent,
            "mcp_export_seconds": mcpExportSeconds, "mcp_export": mcpExport, "restore_seconds": restoreSeconds,
            "reopened_schema_version": diagnostics.schemaVersion, "reopened_integrity": diagnostics.integrity, "manifest": manifest.name,
        ]
        print("LEGACY-REHEARSAL", String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
