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

    /// The menu as built, not just its labels: Review Storage… comes first,
    /// on ⌘R, and opens the review window.
    @MainActor
    func testTheUtilityMenuOpensTheReviewWindowFirst() {
        let entries = StatusItemController.menuEntries.compactMap { $0 }
        XCTAssertEqual(entries.map(\.title), ["Review Storage…", "Export Legacy Evidence", "Settings…", "About Disk Steward", "Quit Disk Steward"])
        XCTAssertEqual(entries.first.map { NSStringFromSelector($0.action) }, "showReview")
        XCTAssertEqual(entries.first?.key, "r")
        for entry in entries { XCTAssertTrue(StatusItemController.instancesRespond(to: entry.action), entry.title) }
        XCTAssertEqual(StatusItemController.menuEntries.map { $0 == nil }, [false, false, true, false, false, true, false], "separators stay in place")
    }

    func testRequiredUtilityMenuLabelsRemainStable() {
        XCTAssertEqual(
            [AppMenuLabels.review, AppMenuLabels.generalExport, AppMenuLabels.settings, AppMenuLabels.about, AppMenuLabels.quit],
            ["Review Storage…", "Export Legacy Evidence", "Settings…", "About Disk Steward", "Quit Disk Steward"]
        )
    }
}
