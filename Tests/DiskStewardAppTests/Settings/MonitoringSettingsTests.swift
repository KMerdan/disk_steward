import Foundation
import XCTest
@testable import DiskStewardApp

@MainActor
final class MonitoringSettingsTests: XCTestCase {
    func testSettingsNormalizeAndRoundTripEveryUserControl() throws {
        let persistence = EphemeralSettingsPersistence()
        let first = MonitoringSettingsStore(persistence: persistence, key: "fixture")
        let root = URL(fileURLWithPath: "/tmp/../tmp/watched")
        let excluded = URL(fileURLWithPath: "/tmp/watched/private")
        let future = Date().addingTimeInterval(7_200)

        first.update {
            $0.launchAtLogin = true
            $0.watchedRoots = [root.path, root.path]
            $0.excludedRoots = [excluded.path]
            $0.rawEventDays = 999
            $0.maxDatabaseMiB = 1
            $0.capacityThresholdPercent = 10
            $0.growthThresholdMiB = 0
            $0.sampleIntervalMinutes = 0
            $0.monitoringPaused = true
            $0.investigationRoot = root.path
            $0.investigationExpiresAt = future
        }
        let reloaded = MonitoringSettingsStore(persistence: persistence, key: "fixture")

        XCTAssertTrue(reloaded.settings.launchAtLogin)
        XCTAssertEqual(reloaded.settings.watchedRoots, ["/tmp/watched"])
        XCTAssertEqual(reloaded.settings.excludedRoots, ["/tmp/watched/private"])
        XCTAssertEqual(reloaded.settings.rawEventDays, 30)
        XCTAssertEqual(reloaded.settings.maxDatabaseMiB, 10)
        XCTAssertEqual(reloaded.settings.capacityThresholdPercent, 50)
        XCTAssertEqual(reloaded.settings.growthThresholdMiB, 1)
        XCTAssertEqual(reloaded.settings.sampleIntervalMinutes, 1)
        XCTAssertTrue(reloaded.settings.monitoringPaused)
        XCTAssertEqual(reloaded.settings.investigationExpiresAt, future)
        XCTAssertNoThrow(try reloaded.settings.retentionPolicy())
    }

    func testInvestigationWindowCanStartAndEnd() {
        let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        store.beginInvestigation(root: "/tmp/investigate", hours: 2, now: now)

        let roots = store.settings.monitoringPolicy(at: now).activeRoots(at: now).map(\.path)
        XCTAssertTrue(roots.contains("/tmp/investigate"))
        XCTAssertEqual(store.settings.investigationExpiresAt, now.addingTimeInterval(7_200))

        store.endInvestigation()
        XCTAssertNil(store.settings.investigationRoot)
        XCTAssertNil(store.settings.investigationExpiresAt)
    }

    func testFolderSelectionNavigatesDirectoriesAndRejectsInvalidPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let alpha = root.appending(path: "Alpha", directoryHint: .isDirectory)
        let beta = root.appending(path: "Beta", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: root.appending(path: "note.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let model = FolderSelectionModel(initialURL: root, homeURL: root)
        XCTAssertEqual(model.currentURL, root.standardizedFileURL)
        XCTAssertEqual(model.directories.map(\.lastPathComponent), ["Alpha", "Beta"])
        XCTAssertEqual(model.selectedURL, root.standardizedFileURL)

        model.navigate(to: alpha)
        XCTAssertEqual(model.currentURL, alpha.standardizedFileURL)
        model.goUp()
        XCTAssertEqual(model.currentURL, root.standardizedFileURL)

        model.pathText = root.appending(path: "missing").path
        model.goToTypedPath()
        XCTAssertEqual(model.currentURL, root.standardizedFileURL)
        XCTAssertNotNil(model.errorMessage)
    }

    func testChosenWatchedFolderIsStandardizedPersistedAndDeduplicated() {
        let persistence = EphemeralSettingsPersistence()
        let store = MonitoringSettingsStore(persistence: persistence, key: "folder-selection")
        let selected = URL(fileURLWithPath: "/tmp/../tmp/non-default", isDirectory: true)

        store.addWatchedRoot(selected.standardizedFileURL)
        store.addWatchedRoot(selected.standardizedFileURL)

        let reloaded = MonitoringSettingsStore(persistence: persistence, key: "folder-selection")
        XCTAssertEqual(reloaded.settings.watchedRoots.filter { $0 == "/tmp/non-default" }, ["/tmp/non-default"])
    }
}
