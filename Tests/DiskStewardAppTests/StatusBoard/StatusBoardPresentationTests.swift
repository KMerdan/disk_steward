import AppKit
@testable import DiskStewardCore
import Foundation
import SwiftUI
import XCTest
@testable import DiskStewardApp

@MainActor
final class StatusBoardPresentationTests: XCTestCase {
    func testStateMatrixHasDeterministicCopyActionsAndTextualAccessibility() {
        let date = Date(timeIntervalSince1970: 1_789_257_600)
        let active = MonitoringStatus(kind: .active, title: "Active", detail: "Evidence is current.", changedAt: date)
        let paused = MonitoringStatus(kind: .paused, title: "Paused", detail: "Paused by user.", changedAt: date)
        let degraded = MonitoringStatus(kind: .degraded, title: "Degraded", detail: "Downloads could not be read.", changedAt: date)

        let states = [
            StatusBoardPresentation.derive(hasSnapshot: true, snapshotError: nil, monitoring: active, hasGrowthBaseline: true),
            StatusBoardPresentation.derive(hasSnapshot: true, snapshotError: nil, monitoring: paused, hasGrowthBaseline: true),
            StatusBoardPresentation.derive(hasSnapshot: true, snapshotError: nil, monitoring: degraded, hasGrowthBaseline: true),
            StatusBoardPresentation.derive(hasSnapshot: true, snapshotError: nil, monitoring: active, hasGrowthBaseline: false),
            StatusBoardPresentation.derive(hasSnapshot: false, snapshotError: "Volume read failed.", monitoring: active, hasGrowthBaseline: false),
        ]

        XCTAssertEqual(states.map(\.state), [.active, .paused, .degraded, .noBaseline, .error])
        XCTAssertEqual(states.map(\.action), [.pause, .resume, .settings, .refresh, .retry])
        XCTAssertEqual(Set(states.map(\.title)).count, states.count)
        for state in states {
            XCTAssertFalse(state.detail.isEmpty)
            XCTAssertTrue(state.accessibilitySummary.contains(state.title))
            XCTAssertTrue(state.accessibilitySummary.contains(state.actionTitle))
        }
    }

    func testCapacityHealthAndGrowthUseUnambiguousText() async {
        let fixture = fixtureObservation(growth: -1_500_000_000)
        let lifecycle = MonitoringLifecycleController(
            settingsStore: MonitoringSettingsStore(persistence: EphemeralSettingsPersistence()),
            probe: StaticStatusBoardProbe(observation: fixture),
            changeCollector: nil
        )
        await lifecycle.sampleNow()
        let model = StatusBoardViewModel(snapshotLoader: { fixture.snapshot }, lifecycle: lifecycle)
        model.refresh()

        XCTAssertEqual(model.capacityHealth, .healthy)
        XCTAssertTrue(model.availableSummary.hasSuffix("free"))
        XCTAssertTrue(model.capacitySummary.contains("used of"))
        XCTAssertTrue(model.growthSummary.hasPrefix("−"))
        XCTAssertEqual(model.growthDetail, "Since the previous sample")
        XCTAssertTrue(model.evidenceFreshnessSummary.hasPrefix("Evidence "))
        XCTAssertTrue(model.evidenceStorageSummary.hasPrefix("Database "))
    }

    func testLightAndDarkStatusBoardRenderAtCompactWidth() async throws {
        let fixture = fixtureObservation(growth: 2_400_000_000)
        let lifecycle = MonitoringLifecycleController(
            settingsStore: MonitoringSettingsStore(persistence: EphemeralSettingsPersistence()),
            probe: StaticStatusBoardProbe(observation: fixture),
            changeCollector: nil
        )
        await lifecycle.sampleNow()
        let model = StatusBoardViewModel(snapshotLoader: { fixture.snapshot }, lifecycle: lifecycle)
        model.refresh()

        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stateFile = AgentAccessStateFile(url: temporary.appending(path: "agent-access.json"))
        let access = MCPAccessController(settingsStore: AgentAccessSettingsStore(stateFile: stateFile)) {
            UnusedStatusBoardServer()
        }
        let view = StatusBoardView(viewModel: model, lifecycle: lifecycle, agentAccess: access)

        let light = try render(view: view, appearance: .aqua)
        let dark = try render(view: view, appearance: .darkAqua)
        XCTAssertEqual(light.size.width, 352, accuracy: 1)
        XCTAssertEqual(dark.size.width, 352, accuracy: 1)
        XCTAssertGreaterThan(light.size.height, 300)
        XCTAssertLessThan(light.size.height, 700)
        XCTAssertEqual(light.size, dark.size)

        if let destination = ProcessInfo.processInfo.environment["DISK_STEWARD_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pngData(light).write(to: directory.appending(path: "status-board-light.png"), options: .atomic)
            try pngData(dark).write(to: directory.appending(path: "status-board-dark.png"), options: .atomic)
        }
    }

    private func render(appearance: NSAppearance.Name, view: StatusBoardView) throws -> NSImage {
        try render(view: view, appearance: appearance)
    }

    private func render<V: View>(view: V, appearance: NSAppearance.Name) throws -> NSImage {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 352, height: 600))
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: 352, height: ceil(fitting.height)))
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw StatusBoardRenderError.bitmapUnavailable
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let image = NSImage(size: hosting.bounds.size)
        image.addRepresentation(representation)
        return image
    }

    private func pngData(_ image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else { throw StatusBoardRenderError.bitmapUnavailable }
        return data
    }
}

private enum StatusBoardRenderError: Error { case bitmapUnavailable }

private struct StaticStatusBoardProbe: MonitoringProbing {
    let observation: MonitoringObservation
    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation { observation }
}

private final class UnusedStatusBoardServer: MCPAccessServing {
    func start() throws {}
    func stop() {}
}

private func fixtureObservation(growth: Int64) -> MonitoringObservation {
    let observed = Date(timeIntervalSince1970: 1_789_257_600)
    let snapshot = StorageSnapshot(
        snapshotID: "status-board-fixture",
        observedAt: "2026-09-13T01:00:00.000Z",
        volumes: [
            .init(
                mountPath: "/",
                totalBytes: 1_000_000_000_000,
                availableBytes: 420_000_000_000,
                isInternal: true,
                isReadOnly: false
            ),
        ]
    )
    let evidence = EvidenceLifecycleStatus(
        observedAt: observed,
        tiers: [],
        databaseBytes: 18_000_000,
        databaseCapBytes: 536_870_912,
        lastCompaction: nil,
        totalForcedEvictions: 0,
        currentStateCount: 42,
        currentStateAllocatedBytes: 16_000_000_000,
        exportInventory: [],
        observationGaps: [],
        retentionGaps: []
    )
    return MonitoringObservation(
        observedAt: observed,
        snapshot: snapshot,
        detailedEvents: [],
        growthReport: GrowthExplanationEngine().explain(volumeUsedDelta: growth, detailedEvents: []),
        evidenceLifecycle: evidence
    )
}
