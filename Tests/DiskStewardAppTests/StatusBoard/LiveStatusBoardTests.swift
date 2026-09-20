import AppKit
import DiskStewardCore
import SwiftUI
import Vision
import XCTest
@testable import DiskStewardApp

/// Inspect text recognized from actual hosted pixels, not view-model getters.
@MainActor
final class LiveStatusBoardTests: XCTestCase {
    func testPausedAndSafetyPausedFirstLaunchDoNotClaimActiveReading() async throws {
        for safetyPaused in [false, true] {
            let persistence = EphemeralSettingsPersistence()
            let settings = MonitoringSettingsStore(persistence: persistence)
            let safety = MonitoringSafetyStateStore(persistence: persistence)
            if safetyPaused { safety.markSampleStarted() }
            else { settings.update { $0.monitoringPaused = true } }
            let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: BoardSequenceProbe(),
                notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, safetyState: safety)
            defer { lifecycle.shutdown() }
            let model = StatusBoardViewModel(lifecycle: lifecycle)
            _ = NSApplication.shared
            let hosting = NSHostingView(rootView: StatusBoardView(viewModel: model))
            hosting.appearance = NSAppearance(named: .aqua)
            hosting.frame = NSRect(x: 0, y: 0, width: 352, height: 700)
            let text = try await renderedText(hosting, name: safetyPaused ? "safety-pause" : "initial-pause")
            XCTAssertTrue(text.contains("No capacity sample yet"), text)
            XCTAssertFalse(text.contains("Reading volume capacity"), text)
            XCTAssertEqual(model.presentation.action, safetyPaused ? .settings : .resume)
            XCTAssertFalse(lifecycle.canRequestSample)
            lifecycle.resume()
            let recovered = try await renderedText(hosting, name: safetyPaused ? "safety-resumed" : "initial-resumed")
            XCTAssertTrue(recovered.contains("420 GB free"), recovered)
            let drained = await lifecycle.shutdownAndDrain()
            XCTAssertTrue(drained)
        }
    }

    func testFailedFirstSampleRendersErrorAndRetryRecovers() async throws {
        let probe = BoardSequenceProbe()
        await probe.failOnce()
        let lifecycle = MonitoringLifecycleController(
            settingsStore: MonitoringSettingsStore(persistence: EphemeralSettingsPersistence()),
            probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil)
        defer { lifecycle.shutdown() }
        await lifecycle.sampleNow()
        let model = StatusBoardViewModel(lifecycle: lifecycle)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: StatusBoardView(viewModel: model))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 352, height: 700)
        let failed = try await renderedText(hosting, name: "first-failure")
        XCTAssertTrue(failed.contains("Capacity unavailable"), failed)
        XCTAssertTrue(failed.contains("Storage unavailable"), failed)
        XCTAssertTrue(failed.contains("Retry"), failed)
        XCTAssertFalse(failed.contains("Reading volume capacity"), failed)
        model.refresh()
        let recovered = try await renderedText(hosting, name: "retry-recovered")
        XCTAssertTrue(recovered.contains("420 GB free"), recovered)
        XCTAssertFalse(recovered.contains("Storage unavailable"), recovered)
    }

    func testOpenBoardRendersSuccessiveObservationsWithoutRefresh() async throws {
        let probe = BoardSequenceProbe()
        let lifecycle = MonitoringLifecycleController(
            settingsStore: MonitoringSettingsStore(persistence: EphemeralSettingsPersistence()),
            probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil
        )
        defer { lifecycle.shutdown() }
        await lifecycle.sampleNow()
        let initial = await probe.value
        let model = StatusBoardViewModel(snapshotLoader: { initial.snapshot }, lifecycle: lifecycle)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: StatusBoardView(viewModel: model))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = NSRect(x: 0, y: 0, width: 352, height: 700)
        let first = try await renderedText(hosting, name: "initial")
        XCTAssertTrue(first.contains("420 GB free"), first)
        XCTAssertTrue(first.contains("Awaiting growth baseline"), first)

        await probe.set(available: 414_400_000_000, delta: 5_600_000_000, index: 1)
        await lifecycle.sampleNow()
        let second = try await renderedText(hosting, name: "growth")
        XCTAssertTrue(second.contains("414.4 GB free"), second)
        XCTAssertTrue(second.contains("+5.6 GB"), second)
        XCTAssertTrue(second.contains("Capacity sampled"), second)
        XCTAssertTrue(second.contains(fixtureTime(index: 1)), second)

        await probe.set(available: 414_397_900_000, delta: 2_100_000, index: 2)
        await lifecycle.sampleNow()
        let third = try await renderedText(hosting, name: "small")
        XCTAssertTrue(third.contains("+2.1 MB"), third)
        XCTAssertTrue(third.contains("+5.6 GB"), "The original alert must remain: \(third)")
        XCTAssertTrue(third.contains(fixtureTime(index: 2)), third)

        await probe.set(available: 417_397_900_000, delta: -3_000_000_000, index: 3)
        await lifecycle.sampleNow()
        let decrease = try await renderedText(hosting, name: "decrease")
        XCTAssertTrue(decrease.contains("417.4 GB free"), decrease)
        XCTAssertTrue(decrease.contains("−3 GB") || decrease.contains("-3 GB"), decrease)
        XCTAssertFalse(decrease.contains("+2.1 MB"), decrease)
        XCTAssertTrue(decrease.contains("+5.6 GB"), decrease)

        let reopened = NSHostingView(rootView: StatusBoardView(viewModel: model))
        reopened.appearance = NSAppearance(named: .darkAqua)
        reopened.frame = hosting.frame
        let reopenedText = try await renderedText(reopened, name: "reopened-dark")
        XCTAssertTrue(reopenedText.contains("417.4 GB free"), reopenedText)
        XCTAssertTrue(reopenedText.contains("−3 GB") || reopenedText.contains("-3 GB"), reopenedText)
        XCTAssertTrue(reopenedText.contains(fixtureTime(index: 3)), reopenedText)

        lifecycle.pause()
        let paused = try await renderedText(hosting, name: "paused")
        XCTAssertTrue(paused.contains("Monitoring paused"), paused)
        XCTAssertTrue(paused.contains("417.4 GB free"), paused)
    }

    private func renderedText(_ hosting: NSHostingView<StatusBoardView>, name: String) async throws -> String {
        // Give SwiftUI's invalidation and the initial .task time to commit.
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        hosting.frame.size.height = ceil(hosting.fittingSize.height)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let cgImage = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let directory = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let path = directory.appending(path: "task617-\(name).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        print("HOSTED-RENDER \(name): \(text.replacingOccurrences(of: "\n", with: " | "))")
        return text
    }

    private func fixtureTime(index: Int) -> String {
        Date(timeIntervalSince1970: 1_789_862_400 + Double(index) * 60).formatted(date: .omitted, time: .standard)
    }
}

private actor BoardSequenceProbe: MonitoringProbing {
    var value = BoardSequenceProbe.observation(available: 420_000_000_000, delta: 0, index: 0)

    func set(available: Int64, delta: Int64, index: Int) {
        value = Self.observation(available: available, delta: delta, index: index)
    }

    private var fail = false
    func failOnce() { fail = true }
    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        if fail { fail = false; throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic sample failed"]) }
        return value
    }

    private static func observation(available: Int64, delta: Int64, index: Int) -> MonitoringObservation {
        let date = Date(timeIntervalSince1970: 1_789_862_400 + Double(index) * 60)
        return MonitoringObservation(
            observedAt: date,
            snapshot: StorageSnapshot(snapshotID: "render-\(index)", observedAt: VolumeSnapshotService.timestamp(date),
                volumes: [.init(mountPath: "/", totalBytes: 1_000_000_000_000, availableBytes: available, isInternal: true, isReadOnly: false)]),
            detailedEvents: [], growthReport: GrowthExplanationEngine().explain(volumeUsedDelta: delta, detailedEvents: []),
            needsScanContinuation: true,
            volumeIdentity: "fixture-volume-uuid"
        )
    }
}
