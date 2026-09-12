import AppKit
import DiskStewardCore
import XCTest
@testable import DiskStewardApp

@MainActor
final class DiskStewardAppTests: XCTestCase {
    func testClickRoutesAreDistinct() {
        XCTAssertEqual(StatusItemSurface.route(for: .leftMouseUp), .statusBoard)
        XCTAssertEqual(StatusItemSurface.route(for: .rightMouseUp), .utilityMenu)
    }

    func testApplicationUsesAccessoryPolicyWithoutDockPresence() {
        XCTAssertEqual(AppConfiguration.activationPolicy, .accessory)
    }

    func testViewModelShowsRealSnapshotValuesAndExports() throws {
        let snapshot = StorageSnapshot(
            snapshotID: "ui-fixture",
            observedAt: "2026-09-12T00:00:00.000Z",
            volumes: [
                .init(mountPath: "/fixture", totalBytes: 1_000, availableBytes: 250, isInternal: true, isReadOnly: false),
            ]
        )
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let model = StatusBoardViewModel(
            snapshotLoader: { snapshot },
            exporter: { try SnapshotExporter(identifierSource: { "ui-export" }).export($0, to: $1) },
            exportParent: { temporary }
        )

        model.refresh()

        XCTAssertEqual(model.primaryVolume?.mountPath, "/fixture")
        XCTAssertEqual(model.usedFraction, 0.75, accuracy: 0.0001)
        let exported = try XCTUnwrap(model.exportCurrentSnapshot())
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appending(path: "manifest.json").path))
        XCTAssertTrue(model.exportMessage?.contains(exported.path) == true)
    }

    func testRequiredUtilityMenuLabelsRemainStable() {
        XCTAssertEqual(
            [AppMenuLabels.generalExport, AppMenuLabels.settings, AppMenuLabels.about, AppMenuLabels.quit],
            ["Export Current Evidence", "Settings…", "About Disk Steward", "Quit Disk Steward"]
        )
    }
}
