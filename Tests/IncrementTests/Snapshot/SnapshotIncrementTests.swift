import AppKit
import CryptoKit
import DiskStewardCore
import SwiftUI
import XCTest
@testable import DiskStewardApp

@MainActor
final class SnapshotIncrementTests: XCTestCase {
    func testLiveSnapshotRendersAndDeterministicExportIsInspectable() throws {
        let liveSnapshot = try VolumeSnapshotService(
            volumeSource: VolumeSnapshotService.currentDataVolume,
            identifierSource: { "gate-190-live" }
        ).capture()
        XCTAssertFalse(liveSnapshot.volumes.isEmpty)

        let model = StatusBoardViewModel(snapshotLoader: { liveSnapshot })
        model.refresh()
        XCTAssertNotNil(model.primaryVolume)

        let fixtureSnapshot = StorageSnapshot(
            snapshotID: "gate-190-fixture",
            observedAt: "2026-09-12T00:00:00.000Z",
            volumes: [
                .init(
                    mountPath: "/fixture-data",
                    totalBytes: 1_000_000_000,
                    availableBytes: 350_000_000,
                    isInternal: true,
                    isReadOnly: false
                ),
            ],
            limitations: ["Deterministic audit fixture; not a historical observation."]
        )
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let exported = try SnapshotExporter(
            productVersion: "0.1.0-gate",
            identifierSource: { "gate-190-fixture" }
        ).export(fixtureSnapshot, to: temporary)
        try inspectExport(exported)

        if let evidencePath = ProcessInfo.processInfo.environment["DISK_STEWARD_GATE_EVIDENCE"] {
            let evidenceURL = try AppConfiguration.createVerificationArtifactDirectory(evidencePath)
            try render(model: model, to: evidenceURL.appending(path: "rendered-status-board.png"))
            let fixtureURL = evidenceURL.appending(path: "export-fixture", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: exported.bundleURL, to: fixtureURL)
        }
    }

    private func inspectExport(_ result: SnapshotExportResult) throws {
        let expectedPayloads = Set(["codex-brief.md", "storage-snapshot.json"])
        XCTAssertEqual(Set(result.manifest.files.map(\.path)), expectedPayloads)
        XCTAssertFalse(result.manifest.privacy.containsFileContents)
        XCTAssertFalse(result.manifest.privacy.containsEnvironment)

        for file in result.manifest.files {
            let data = try Data(contentsOf: result.bundleURL.appending(path: file.path))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(data.count, file.bytes)
            XCTAssertEqual(digest, file.sha256)
        }

        let snapshotData = try Data(contentsOf: result.bundleURL.appending(path: "storage-snapshot.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, "storage-snapshot-v1")
        XCTAssertNil(object["file_contents"])
        XCTAssertNil(object["environment"])
    }

    private func render(model: StatusBoardViewModel, to destination: URL) throws {
        let renderedView = ZStack {
            Color(nsColor: .windowBackgroundColor)
            StatusBoardView(viewModel: model)
        }
        let hostingView = NSHostingView(rootView: renderedView)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 330, height: 270)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw RenderError.bitmapUnavailable
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngUnavailable
        }
        try png.write(to: destination, options: .atomic)
    }
}

private enum RenderError: Error {
    case bitmapUnavailable
    case pngUnavailable
}
