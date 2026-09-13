import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

@MainActor
final class StatusBoardEvidenceExportTests: XCTestCase {
    func testActualViewModelPathExportsDurableBundleRevealsItAndRecordsManualOwnership() async throws {
        let fixture = try AppExportFixture()
        let store = try EvidenceStore(url: fixture.databaseURL)
        let observedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let scope = EvidenceScopeVersion(
            scopeVersionID: "view-model-scope",
            effectiveAt: observedAt,
            rootPaths: ["/watched"],
            excludedPaths: ["/watched/private"],
            maximumEntries: 1,
            maximumDepth: 8
        )
        _ = try await store.recordObservation(
            snapshot: StorageSnapshot(
                snapshotID: "view-model-capacity",
                observedAt: "2033-05-18T03:33:20.000Z",
                volumes: [.init(mountPath: "/", totalBytes: 10_000, availableBytes: 4_000, isInternal: true, isReadOnly: false)]
            ),
            metadata: MetadataSnapshot(
                observationID: "view-model-partial",
                scopeVersionID: scope.scopeVersionID,
                observedAt: observedAt,
                entries: [
                    "/watched/cache.bin": .init(
                        objectID: "cache",
                        identityMethod: .volumeFileGeneration,
                        rootPath: "/watched",
                        path: "/watched/cache.bin",
                        logicalBytes: 8_000,
                        allocatedBytes: 8_192,
                        modifiedAt: observedAt
                    ),
                ],
                rootCoverage: [.init(rootPath: "/watched", coverage: .partial, limitations: ["entry cap"])],
                limitations: ["Detailed scan stopped at the configured 1-entry limit."]
            ),
            scope: scope,
            trigger: .manual
        )

        var revealedURL: URL?
        let coreExporter = EvidenceBundleExporter(identifierSource: { "view-model-export" }, dateSource: { observedAt })
        let model = StatusBoardViewModel(
            evidenceExporter: { destination in
                try await coreExporter.export(
                    store: store,
                    options: .init(from: observedAt.addingTimeInterval(-1), through: observedAt.addingTimeInterval(1)),
                    to: destination
                )
            },
            exportParent: { fixture.exportsURL },
            exportCompletion: { revealedURL = $0 }
        )

        let maybeExportedURL = await model.exportCurrentEvidence()
        let exportedURL = try XCTUnwrap(maybeExportedURL)
        XCTAssertEqual(revealedURL, exportedURL)
        XCTAssertFalse(model.isExporting)
        XCTAssertTrue(model.exportMessage?.contains(exportedURL.path) == true)

        let manifest = try json(at: exportedURL.appending(path: "manifest.json"))
        let files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 11)
        XCTAssertTrue(files.contains { $0["role"] as? String == "current-state" })
        XCTAssertTrue(files.contains { $0["role"] as? String == "coverage" })
        XCTAssertFalse(files.contains { $0["path"] as? String == "storage-snapshot.json" })
        XCTAssertFalse((manifest["limitations"] as? [String] ?? []).isEmpty)

        let brief = try String(contentsOf: exportedURL.appending(path: "codex-brief.md"), encoding: .utf8)
        XCTAssertTrue(brief.contains("`/watched`"))
        XCTAssertTrue(brief.contains("`/watched/cache.bin`"))
        XCTAssertTrue(brief.contains("File-detail coverage: partial"))
        XCTAssertTrue(brief.contains("File-detail growth is unavailable"))

        let records = try await store.exportRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.kind, .manual)
        XCTAssertEqual(records.first?.status, .available)
        XCTAssertEqual(records.first?.path, exportedURL.path)
        await store.close()
    }

    func testUnavailableOrFailedDurableExporterReportsFailureAndResetsBusyState() async {
        var openedDirectories: [URL] = []
        let unavailable = StatusBoardViewModel(exportCompletion: { openedDirectories.append($0) })
        let unavailableResult = await unavailable.exportCurrentEvidence()
        XCTAssertNil(unavailableResult)
        XCTAssertTrue(unavailable.exportMessage?.contains("durable evidence store is not attached") == true)

        let failed = StatusBoardViewModel(evidenceExporter: { _ in
            throw CocoaError(.fileWriteUnknown)
        }, exportCompletion: { openedDirectories.append($0) })
        let failedResult = await failed.exportCurrentEvidence()
        XCTAssertNil(failedResult)
        XCTAssertFalse(failed.isExporting)
        XCTAssertTrue(failed.exportMessage?.contains("Evidence export failed") == true)
        XCTAssertTrue(openedDirectories.isEmpty)
    }

    private func json(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}

private final class AppExportFixture {
    let root: URL
    let databaseURL: URL
    let exportsURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        databaseURL = root.appending(path: "evidence.sqlite")
        exportsURL = root.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
