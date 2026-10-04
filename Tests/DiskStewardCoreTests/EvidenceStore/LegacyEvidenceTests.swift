@testable import DiskStewardCore
import Foundation
import XCTest

/// TASK-653 AC-02: the retired store is renamed unmodified into `legacy/`,
/// exported only from a clone, deleted only when confirmed, and renamed back
/// for a rollback with its bytes intact.
final class LegacyEvidenceTests: XCTestCase {
    private var support: URL!
    private let date = Date(timeIntervalSince1970: 1_791_100_000)  // 2026-10-04

    override func setUpWithError() throws {
        support = URL(fileURLWithPath: "/private/tmp/ds-legacy-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: support) }

    /// A real WAL-mode store with uncheckpointed pages left in `-wal`, as a
    /// running or crashed 1.3.0 leaves it.
    private func makeStore() async throws -> [String: String] {
        let database = support.appending(path: "evidence.sqlite")
        let store = try EvidenceStore(url: database)
        _ = try await store.applyRetention(try .init(), trigger: .manual)
        await store.close()
        let writer = try SQLiteConnection(url: database)
        try writer.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE IF NOT EXISTS legacy_probe (v TEXT); INSERT INTO legacy_probe VALUES ('kept-in-wal');")
        // Copy the files while the writer holds the WAL open, as a crash would leave them.
        let frozen = support.appending(path: "frozen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: frozen, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: database.path + suffix) {
            try FileManager.default.copyItem(atPath: database.path + suffix, toPath: frozen.path + "/evidence.sqlite" + suffix)
        }
        writer.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: frozen.path + "/evidence.sqlite" + suffix) {
                try FileManager.default.moveItem(atPath: frozen.path + "/evidence.sqlite" + suffix, toPath: database.path + suffix)
            }
        }
        try FileManager.default.removeItem(at: frozen)
        try Data("{}".utf8).write(to: support.appending(path: "scan-convergence.json"))
        var hashes: [String: String] = [:]
        for suffix in [".sqlite", ".sqlite-wal"] {
            let url = support.appending(path: "evidence" + suffix)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "fixture has \(suffix)")
            hashes[suffix] = try LegacyEvidence.hash(url).1
        }
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: support.path + "/evidence.sqlite-wal")[.size] as? Int ?? 0, 0)
        return hashes
    }

    private func legacyFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: LegacyEvidence.directory(in: support).path).sorted()
    }

    func testMigrationRenamesTheStoreAndItsLogByteForByte() async throws {
        let before = try await makeStore()
        let manifest = try XCTUnwrap(try LegacyEvidence.migrate(supportDirectory: support, at: date, migratedBy: "test"))
        XCTAssertEqual(manifest.name, "evidence-2026-10-04")
        XCTAssertEqual(manifest.status, .migrated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path + "/evidence.sqlite"), "nothing is left at the old path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path + "/evidence.sqlite-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path + "/scan-convergence.json"))
        for (suffix, digest) in before {
            let moved = LegacyEvidence.directory(in: support).appending(path: manifest.name + suffix)
            XCTAssertEqual(try LegacyEvidence.hash(moved).1, digest, "\(suffix) is unchanged")
            XCTAssertEqual(manifest.files.first { $0.suffix == suffix }?.sha256, digest, "the manifest records the pre-move hash")
        }
        XCTAssertTrue(try legacyFiles().contains("evidence-2026-10-04-scan-convergence.json"))
        XCTAssertEqual(try LegacyEvidence.sets(in: support).map(\.name), ["evidence-2026-10-04"])
        // A later launch has nothing to move.
        XCTAssertNil(try LegacyEvidence.migrate(supportDirectory: support, at: date, migratedBy: "test"))
    }

    func testNothingToMoveCreatesNoLegacyDirectory() throws {
        XCTAssertNil(try LegacyEvidence.migrate(supportDirectory: support, at: date, migratedBy: "test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LegacyEvidence.directory(in: support).path))
    }

    func testAnInterruptedMoveResumesUnderTheSameName() async throws {
        let before = try await makeStore()
        // Simulate a crash after the manifest and the log moved, before the main file.
        let first = try XCTUnwrap(try LegacyEvidence.migrate(supportDirectory: support, at: date, migratedBy: "test"))
        let legacy = LegacyEvidence.directory(in: support)
        try FileManager.default.moveItem(at: legacy.appending(path: first.name + ".sqlite"), to: support.appending(path: "evidence.sqlite"))
        var pending = first
        pending.status = .moving
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(pending).write(to: legacy.appending(path: first.name + ".json"))

        let resumed = try XCTUnwrap(try LegacyEvidence.migrate(supportDirectory: support, at: date.addingTimeInterval(86_400), migratedBy: "test"))
        XCTAssertEqual(resumed.name, first.name, "the interrupted set is completed, not duplicated")
        XCTAssertEqual(resumed.status, .migrated)
        XCTAssertEqual(try LegacyEvidence.hash(legacy.appending(path: first.name + ".sqlite")).1, before[".sqlite"])
        XCTAssertEqual(try LegacyEvidence.sets(in: support).count, 1)
    }

    func testASecondStoreTheSameDayGetsItsOwnName() async throws {
        _ = try await makeStore()
        _ = try LegacyEvidence.migrate(supportDirectory: support, at: date, migratedBy: "test")
        _ = try await makeStore()
        let second = try XCTUnwrap(try LegacyEvidence.migrate(supportDirectory: support, at: date, migratedBy: "test"))
        XCTAssertEqual(second.name, "evidence-2026-10-04-2")
        XCTAssertEqual(try LegacyEvidence.sets(in: support).count, 2)
    }

    func testExportReadsAClonedCopyAndLeavesTheLegacyFilesUntouched() async throws {
        _ = try await makeStore()
        let manifest = try XCTUnwrap(try LegacyEvidence.migrate(supportDirectory: support, at: date, migratedBy: "test"))
        let legacy = LegacyEvidence.directory(in: support)
        let listing = try legacyFiles()
        var stamps: [String: Date] = [:]
        for name in listing { stamps[name] = try FileManager.default.attributesOfItem(atPath: legacy.path + "/" + name)[.modificationDate] as? Date }
        let digest = try LegacyEvidence.hash(legacy.appending(path: manifest.name + ".sqlite")).1

        let clone = try LegacyEvidence.clone(manifest, supportDirectory: support)
        let store = try EvidenceStore(url: clone)
        let exports = support.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let result = try await EvidenceBundleExporter().export(
            store: store, options: .init(from: date.addingTimeInterval(-365 * 86_400), through: date), to: exports)
        await store.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.path))
        let probe = try SQLiteConnection(url: clone)
        let kept = try probe.scalarInt("SELECT COUNT(*) FROM legacy_probe")
        probe.close()
        XCTAssertEqual(kept, 1, "the clone carries the pages that were only in -wal")
        try FileManager.default.removeItem(at: clone.deletingLastPathComponent())

        XCTAssertEqual(try legacyFiles(), listing, "SQLite never opened the legacy files: no new sidecars")
        XCTAssertEqual(try LegacyEvidence.hash(legacy.appending(path: manifest.name + ".sqlite")).1, digest)
        for name in listing {
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: legacy.path + "/" + name)[.modificationDate] as? Date, stamps[name], name)
        }
    }

    func testDeleteRequiresConfirmation() async throws {
        _ = try await makeStore()
        let manifest = try XCTUnwrap(try LegacyEvidence.migrate(supportDirectory: support, at: date, migratedBy: "test"))
        var removed: [String] = []
        XCTAssertThrowsError(try LegacyEvidence.delete(manifest, supportDirectory: support, confirmed: false) { removed.append($0.lastPathComponent) }) {
            XCTAssertEqual($0 as? LegacyEvidenceError, .confirmationRequired)
        }
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(try LegacyEvidence.sets(in: support).count, 1)
        try LegacyEvidence.delete(manifest, supportDirectory: support, confirmed: true) { url in
            removed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertTrue(removed.contains("evidence-2026-10-04.sqlite"))
        XCTAssertTrue(removed.contains("evidence-2026-10-04.json"))
        XCTAssertEqual(try LegacyEvidence.sets(in: support).count, 0)
    }

    /// The rollback: the shipped script renames the set back, checking the
    /// recorded hashes, and the previous version's store opens with the data.
    func testRestoreScriptRenamesTheSetBackWithItsBytesIntact() async throws {
        let before = try await makeStore()
        let manifest = try XCTUnwrap(try LegacyEvidence.migrate(supportDirectory: support, at: date, migratedBy: "test"))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Scripts/Distribution/restore-legacy-evidence")
        func run(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path, "--support-directory", support.path] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        // A tampered set is refused.
        let main = LegacyEvidence.directory(in: support).appending(path: manifest.name + ".sqlite")
        let original = try Data(contentsOf: main)
        var tampered = original
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: main)
        XCTAssertEqual(try run([]).0, 65)
        try original.write(to: main)

        let (status, output) = try run([])
        XCTAssertEqual(status, 0, output)
        for (suffix, digest) in before {
            XCTAssertEqual(try LegacyEvidence.hash(support.appending(path: "evidence" + suffix)).1, digest, "\(suffix) restored byte for byte")
        }
        XCTAssertTrue(try LegacyEvidence.sets(in: support).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.path + "/scan-convergence.json"))
        XCTAssertEqual(try run([]).0, 73, "an existing store is never overwritten")

        let reopened = try EvidenceStore(url: support.appending(path: "evidence.sqlite"))
        _ = try await reopened.diagnostics()
        await reopened.close()
        let probe = try SQLiteConnection(url: support.appending(path: "evidence.sqlite"))
        let kept = try probe.scalarText("SELECT v FROM legacy_probe")
        probe.close()
        XCTAssertEqual(kept, "kept-in-wal", "evidence written only to the log survives the round trip")
    }
}
