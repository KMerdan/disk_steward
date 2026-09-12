import CryptoKit
import Foundation
import XCTest
@testable import DiskStewardCore

final class SnapshotExporterTests: XCTestCase {
    func testExportIsDeterministicSchemaValidAndIntegrityChecked() throws {
        let snapshot = StorageSnapshot(
            snapshotID: "snapshot-001",
            observedAt: "2026-09-12T00:00:00.000Z",
            volumes: [
                .init(mountPath: "/", totalBytes: 1_000, availableBytes: 400, isInternal: true, isReadOnly: false),
            ]
        )
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let result = try SnapshotExporter(
            productVersion: "test",
            identifierSource: { "bundle-001" }
        ).export(snapshot, to: temporary)

        XCTAssertEqual(result.bundleURL.lastPathComponent, "disk-steward-bundle-001")
        XCTAssertEqual(result.manifest.files.map(\.path), ["codex-brief.md", "storage-snapshot.json"])
        XCTAssertFalse(result.manifest.privacy.containsFileContents)
        XCTAssertFalse(result.manifest.privacy.containsEnvironment)
        XCTAssertEqual(try manifestSchemaErrors(at: result.bundleURL), [])

        for file in result.manifest.files {
            let data = try Data(contentsOf: result.bundleURL.appending(path: file.path))
            XCTAssertEqual(data.count, file.bytes)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), file.sha256)
        }

        let brief = try String(contentsOf: result.bundleURL.appending(path: "codex-brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("capacity metadata only"))
        XCTAssertFalse(brief.localizedCaseInsensitiveContains("file contents:"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.bundleURL.appending(path: "environment.json").path))
    }

    func testUnsafeBundleIdentifierCannotEscapeDestination() throws {
        let snapshot = StorageSnapshot(
            snapshotID: "snapshot-001",
            observedAt: "2026-09-12T00:00:00.000Z",
            volumes: [.init(mountPath: "/", totalBytes: 1, availableBytes: 1, isInternal: true, isReadOnly: false)]
        )
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        XCTAssertThrowsError(
            try SnapshotExporter(identifierSource: { "../escape" }).export(snapshot, to: temporary)
        ) { error in
            XCTAssertEqual(error as? SnapshotExportError, .unsafeBundleIdentifier)
        }
    }

    func testLiveCurrentDataVolumeCanBeExported() throws {
        let snapshot = try VolumeSnapshotService(
            volumeSource: VolumeSnapshotService.currentDataVolume,
            identifierSource: { "live-export-snapshot" }
        ).capture()
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let result = try SnapshotExporter(identifierSource: { "live-export" }).export(snapshot, to: temporary)

        XCTAssertEqual(try manifestSchemaErrors(at: result.bundleURL), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.appending(path: "storage-snapshot.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.bundleURL.appending(path: "codex-brief.md").path))
    }

    private func manifestSchemaErrors(at bundleURL: URL) throws -> [String] {
        let data = try Data(contentsOf: bundleURL.appending(path: "manifest.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schema = try SnapshotJSONSchemaValidator.loadSchema(named: "export-manifest-v1")
        return SnapshotJSONSchemaValidator().validate(instance: object, schema: schema)
    }
}
