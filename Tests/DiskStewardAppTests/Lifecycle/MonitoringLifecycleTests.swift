import DiskStewardCore
import Foundation
import XCTest
@testable import DiskStewardApp

@MainActor
final class MonitoringLifecycleTests: XCTestCase {
    func testQueuedSettingsRestartUsesLatestIntentDuringPeriodicSleep() async throws {
        for next in ["pause", "sleep", "quit", "new-settings"] {
            let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
            let probe = GatedCompletionProbe()
            let clock = ManualLifecycleClock()
            let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, clock: clock.clock)
            addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
            lifecycle.start()
            try await probe.waitUntilStarted()
            await probe.finish()
            try await eventually { clock.pendingSleeps == 1 }
            settings.update { $0.monitoringPaused = true }
            settings.update { $0.monitoringPaused = false }
            // MainActor has not yielded: the queued restart must use the last
            // intent, not blindly act on that transient false value.
            switch next {
            case "pause": settings.update { $0.monitoringPaused = true }
            case "sleep": lifecycle.prepareForSystemSleep()
            case "quit": lifecycle.shutdown()
            default: settings.update { $0.sampleIntervalMinutes = 10 }
            }
            if next == "new-settings" {
                try await probe.waitUntilStarted()
                let count = await probe.callCount
                XCTAssertEqual(count, 2)
                await probe.finish()
                try await eventually { clock.pendingSleeps == 1 }
            } else {
                await lifecycle.sampleNow()
                try await eventually { clock.pendingSleeps == 0 }
                let count = await probe.callCount
                XCTAssertEqual(count, 1, next)
            }
            lifecycle.shutdown()
        }
    }

    func testZeroShutdownDeadlineAndCompletionRaceLeaveNoUnownedMarker() async throws {
        for timeout in [0.0, -1.0, 5.0] {
            let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
            let safety = MonitoringSafetyStateStore(persistence: settings.persistence)
            let probe = GatedCompletionProbe()
            let clock = ManualLifecycleClock()
            let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, safetyState: safety, clock: clock.clock)
            addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
            let sample = Task { await lifecycle.sampleNow() }
            try await probe.waitUntilStarted()
            if timeout <= 0 {
                let drained = await lifecycle.shutdownAndDrain(timeout: timeout)
                XCTAssertFalse(drained)
                XCTAssertTrue(safety.hasInterruptedSample)
                XCTAssertEqual(clock.pendingSleeps, 0)
                await probe.finish()
            } else {
                let quit = Task { await lifecycle.shutdownAndDrain(timeout: timeout) }
                try await eventually { clock.pendingSleeps == 1 }
                // Both completions are now runnable. Either may win, but the
                // continuation must resume exactly once and work must drain.
                clock.advance(by: timeout)
                await probe.finish()
                _ = await quit.value
            }
            await sample.value
            XCTAssertFalse(safety.hasInterruptedSample)
            XCTAssertNil(lifecycle.latestObservation)
        }
    }

    func testIncomingPauseSettingDoesNotLeaveCompletedLoopBlockingResume() async throws {
        for resumeThroughSettings in [false, true] {
            let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
            let safety = MonitoringSafetyStateStore(persistence: settings.persistence)
            let probe = GatedCompletionProbe()
            let clock = ManualLifecycleClock()
            let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, safetyState: safety, clock: clock.clock)
            addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
            lifecycle.start()
            try await probe.waitUntilStarted()
            settings.update { $0.monitoringPaused = true }
            await probe.finish()
            try await eventually { !safety.hasInterruptedSample }
            if resumeThroughSettings { settings.update { $0.monitoringPaused = false } }
            else { lifecycle.resume() }
            for _ in 0 ..< 10_000 {
                if await probe.callCount == 2 { break }
                await Task.yield()
            }
            let count = await probe.callCount
            XCTAssertEqual(count, 2, "A completed timer task must not block Resume")
            lifecycle.shutdown()
            await probe.finish()
            let drained = await lifecycle.shutdownAndDrain()
            XCTAssertTrue(drained)
        }
    }

    func testSettingsPublisherUsesIncomingScopeAndDoesNotRestartPausedCollector() {
        let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        settings.update { $0.watchedRoots = ["/fixture/first"] }
        let collector = RecordingChangeCollector()
        let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: AlwaysHealthyProbe(), notificationDelivery: DisabledNotificationDelivery(), changeCollector: collector)
        lifecycle.start()
        settings.addWatchedRoot(URL(fileURLWithPath: "/fixture/second"))
        XCTAssertEqual(collector.lastPolicy?.watchedRoots.map(\.path), ["/fixture/first", "/fixture/second"])
        lifecycle.pause()
        XCTAssertFalse(collector.isRunning, "@Published emits before settings are stored; Pause must not restart the old policy")
        lifecycle.shutdown()
    }

    func testShutdownDrainsBeforeDeadlineAndSharesOneWaiter() async throws {
        let persistence = EphemeralSettingsPersistence()
        let settings = MonitoringSettingsStore(persistence: persistence)
        let safety = MonitoringSafetyStateStore(persistence: persistence)
        let probe = GatedCompletionProbe()
        let clock = ManualLifecycleClock()
        let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, safetyState: safety, clock: clock.clock)
        addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
        let sample = Task { await lifecycle.sampleNow() }
        try await probe.waitUntilStarted()
        let quit = Task { await lifecycle.shutdownAndDrain(timeout: 5) }
        try await eventually { clock.pendingSleeps == 1 }
        let duplicateQuit = Task { await lifecycle.shutdownAndDrain(timeout: 5) }
        XCTAssertTrue(safety.hasInterruptedSample)
        await probe.finish()
        let drained = await quit.value
        let alsoDrained = await duplicateQuit.value
        await sample.value
        XCTAssertTrue(drained)
        XCTAssertTrue(alsoDrained)
        XCTAssertFalse(safety.hasInterruptedSample)
        try await eventually { clock.pendingSleeps == 0 }
        XCTAssertNil(lifecycle.latestObservation)
    }

    func testShutdownDeadlinePreservesUnfinishedMarkerForNextLaunch() async throws {
        let persistence = EphemeralSettingsPersistence()
        let settings = MonitoringSettingsStore(persistence: persistence)
        let safety = MonitoringSafetyStateStore(persistence: persistence)
        let probe = GatedCompletionProbe()
        let clock = ManualLifecycleClock()
        let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, safetyState: safety, clock: clock.clock)
        addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
        let sample = Task { await lifecycle.sampleNow() }
        try await probe.waitUntilStarted()
        var result: Bool?
        let quit = Task { result = await lifecycle.shutdownAndDrain(timeout: 5) }
        try await eventually { clock.pendingSleeps == 1 }
        clock.advance(by: 4)
        XCTAssertEqual(clock.pendingSleeps, 1, "The deadline must still be pending, even before resumed tasks get an executor turn")
        XCTAssertNil(result)
        XCTAssertTrue(safety.hasInterruptedSample)
        clock.advance(by: 1)
        await quit.value
        XCTAssertEqual(result, false)
        XCTAssertTrue(safety.hasInterruptedSample)
        let nextLaunch = MonitoringLifecycleController(settingsStore: MonitoringSettingsStore(persistence: persistence), probe: AlwaysHealthyProbe(), notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, safetyState: safety, clock: clock.clock)
        XCTAssertEqual(nextLaunch.status.title, "Safety Pause")
        nextLaunch.shutdown()
        // The fake ignores cancellation to model an already-submitted store
        // transaction. Explicitly finish it so this test leaves no task behind.
        await probe.finish()
        await sample.value
        XCTAssertFalse(safety.hasInterruptedSample)
        XCTAssertNil(lifecycle.latestObservation)
    }

    func testBusyFollowUpCannotRunDuringPauseOrSleep() async throws {
        for stop in ["pause", "sleep"] {
            let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
            let probe = GatedCompletionProbe()
            let clock = ManualLifecycleClock()
            let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, clock: clock.clock)
        addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
            let first = Task { await lifecycle.sampleNow() }
            try await probe.waitUntilStarted()
            await lifecycle.sampleNow()
            if stop == "pause" { lifecycle.pause() } else { lifecycle.prepareForSystemSleep() }
            await probe.finish()
            await first.value
            clock.advance(by: 3_600)
            await lifecycle.sampleNow()
            let count = await probe.callCount
            XCTAssertEqual(count, 1, stop)
            XCTAssertEqual(clock.pendingSleeps, 0)
            XCTAssertNil(lifecycle.latestObservation)
            lifecycle.shutdown()
        }
    }

    func testResumeWaitsForOldSampleThenStartsFreshOwnedWork() async throws {
        let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        let probe = GatedCompletionProbe()
        let clock = ManualLifecycleClock()
        let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, clock: clock.clock)
        addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
        let first = Task { await lifecycle.sampleNow() }
        try await probe.waitUntilStarted()
        lifecycle.pause()
        lifecycle.resume()
        // The resumed periodic loop coalesces its request behind the old work.
        try await eventually { clock.pendingSleeps == 1 }
        await probe.finish()
        await first.value
        try await probe.waitUntilStarted()
        XCTAssertNil(lifecycle.latestObservation)
        let calls = await probe.callCount
        XCTAssertEqual(calls, 2)
        await probe.finish()
        try await eventually { lifecycle.latestObservation != nil }
        let cancellations = await probe.cancelledOnCompletion
        XCTAssertEqual(cancellations, [true, false])
        lifecycle.shutdown()
        let drained = await lifecycle.shutdownAndDrain()
        XCTAssertTrue(drained)
        try await eventually { clock.pendingSleeps == 0 }
    }

    func testActiveSampleKeepsItsSafetyMarkerThroughPauseResumeAndQuit() async throws {
        let persistence = EphemeralSettingsPersistence()
        let settings = MonitoringSettingsStore(persistence: persistence)
        let safety = MonitoringSafetyStateStore(persistence: persistence)
        let probe = GatedCompletionProbe()
        let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, safetyState: safety)
        addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
        let task = Task { await lifecycle.sampleNow() }
        try await probe.waitUntilStarted()
        XCTAssertTrue(safety.hasInterruptedSample)

        lifecycle.pause()
        lifecycle.resume()
        XCTAssertTrue(safety.hasInterruptedSample, "Resume may acknowledge a previous-launch interruption, not clear a live sample's marker")
        lifecycle.shutdown()
        XCTAssertTrue(safety.hasInterruptedSample, "Quit must not pretend the pending sample has drained")

        await probe.finish()
        await task.value
        XCTAssertFalse(safety.hasInterruptedSample, "Confirmed completion releases the marker")
        XCTAssertNil(lifecycle.latestObservation)
    }

    func testShutdownIsTerminalForQueuedPowerAndUserCallbacks() async throws {
        for callback in ["wake", "resume", "sleep", "pause"] {
            let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
            let probe = SlowCountingProbe()
            let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil)
            lifecycle.shutdown()
            let status = lifecycle.status
            let history = lifecycle.history
            let paused = settings.settings.monitoringPaused
            switch callback {
            case "wake": lifecycle.resumeAfterSystemWake()
            case "resume": lifecycle.resume()
            case "sleep": lifecycle.prepareForSystemSleep()
            default: lifecycle.pause()
            }
            lifecycle.start()
            await lifecycle.sampleNow()
            XCTAssertEqual(lifecycle.status, status, callback)
            XCTAssertEqual(lifecycle.history, history, callback)
            XCTAssertEqual(settings.settings.monitoringPaused, paused, callback)
            let count = await probe.callCount
            XCTAssertEqual(count, 0, callback)
        }
    }

    func testStopCancelsTheOwnedSampleRegardlessOfItsCaller() async throws {
        for action in ["pause", "sleep", "quit"] {
            let settings = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
            let probe = GatedCompletionProbe()
            let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil)
        addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
            // A manual refresh is not the periodic loop or debounce task.
            let caller = Task { await lifecycle.sampleNow() }
            try await probe.waitUntilStarted()
            switch action {
            case "pause": lifecycle.pause()
            case "sleep": lifecycle.prepareForSystemSleep()
            default: lifecycle.shutdown()
            }
            await probe.finish()
            await caller.value
            let cancelled = await probe.cancelledOnCompletion
            XCTAssertEqual(cancelled, [true], action)
        }
    }

    func testLateCompletionCannotUndoPauseSleepOrQuit() async throws {
        for action in ["pause", "sleep", "quit"] {
            let persistence = EphemeralSettingsPersistence()
            let settings = MonitoringSettingsStore(persistence: persistence)
            let safety = MonitoringSafetyStateStore(persistence: persistence)
            let probe = GatedCompletionProbe()
            let delivery = RecordingDelivery()
            let lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: delivery, changeCollector: nil, safetyState: safety)
        addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
            let task = Task { await lifecycle.sampleNow() }
            try await probe.waitUntilStarted()
            switch action {
            case "pause": lifecycle.pause()
            case "sleep": lifecycle.prepareForSystemSleep()
            default: lifecycle.shutdown()
            }
            let status = lifecycle.status
            await probe.finish()
            await task.value
            XCTAssertEqual(lifecycle.status, status, action)
            XCTAssertNil(lifecycle.latestObservation, action)
            let delivered = await delivery.notifications
            XCTAssertTrue(delivered.isEmpty, action)
            XCTAssertFalse(safety.hasInterruptedSample, action)
            await lifecycle.sampleNow()
            let count = await probe.callCount
            XCTAssertEqual(count, 1, action)
        }
    }
    func testDegradedSampleRecoversAndHistoryExplainsBothStates() async throws {
        let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        let probe = FailingThenHealthyProbe()
        let delivery = RecordingDelivery()
        let lifecycle = MonitoringLifecycleController(settingsStore: store, probe: probe, notificationDelivery: delivery, changeCollector: nil)

        await lifecycle.sampleNow()
        XCTAssertEqual(lifecycle.status.kind, .degraded)
        XCTAssertTrue(lifecycle.status.accessibilitySummary.contains("Sampling failed"))

        await lifecycle.sampleNow()
        XCTAssertEqual(lifecycle.status.kind, .recovered)
        XCTAssertTrue(lifecycle.status.accessibilitySummary.contains("healthy again"))
        XCTAssertEqual(lifecycle.history.map(\.kind).prefix(2), [.recovered, .degraded])
    }

    func testPauseAndResumePersistUserChoice() {
        let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        let lifecycle = MonitoringLifecycleController(settingsStore: store, probe: AlwaysHealthyProbe(), notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil)

        lifecycle.pause()
        XCTAssertEqual(lifecycle.status.kind, .paused)
        XCTAssertTrue(store.settings.monitoringPaused)

        lifecycle.resume()
        XCTAssertFalse(store.settings.monitoringPaused)
        XCTAssertNotEqual(lifecycle.status.kind, .paused)
        lifecycle.pause()
    }

    func testSystemSleepSuspendsWithoutChangingUserChoiceAndWakeRefreshes() async throws {
        let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        let probe = GatedCompletionProbe()
        let clock = ManualLifecycleClock()
        let lifecycle = MonitoringLifecycleController(
            settingsStore: store,
            probe: probe,
            notificationDelivery: DisabledNotificationDelivery(),
            changeCollector: nil,
            safetyState: MonitoringSafetyStateStore(
                persistence: EphemeralSettingsPersistence(),
                key: "sleep-wake"
            ),
            clock: clock.clock
        )
        addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }

        lifecycle.prepareForSystemSleep()
        XCTAssertEqual(lifecycle.status.title, "Sleeping")
        XCTAssertFalse(store.settings.monitoringPaused)

        lifecycle.resumeAfterSystemWake()
        XCTAssertEqual(lifecycle.status.title, "Waking")
        try await probe.waitUntilStarted()
        await probe.finish()
        try await eventually { clock.pendingSleeps == 1 }
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertFalse(store.settings.monitoringPaused)
        lifecycle.pause()
        try await eventually { clock.pendingSleeps == 0 }
    }

    func testInterruptedSampleStartsInSafetyPauseUntilUserResumes() {
        let persistence = EphemeralSettingsPersistence()
        let settings = MonitoringSettingsStore(persistence: persistence)
        let safety = MonitoringSafetyStateStore(persistence: persistence, key: "safety")
        safety.markSampleStarted(at: Date(timeIntervalSince1970: 100))

        let lifecycle = MonitoringLifecycleController(
            settingsStore: settings,
            probe: AlwaysHealthyProbe(),
            notificationDelivery: DisabledNotificationDelivery(),
            changeCollector: nil,
            safetyState: safety
        )
        addTeardownBlock { @MainActor in lifecycle.shutdown() }

        XCTAssertEqual(lifecycle.status.kind, .degraded)
        XCTAssertTrue(lifecycle.status.detail.contains("previous detailed sample did not finish"))
        XCTAssertTrue(settings.settings.monitoringPaused)

        let recoveryStatus = lifecycle.status
        settings.update { $0.sampleIntervalMinutes = 10 }
        XCTAssertEqual(lifecycle.status, recoveryStatus, "An unrelated settings edit must retain the safety-pause reason")
        lifecycle.resume()
        XCTAssertFalse(settings.settings.monitoringPaused)
        XCTAssertFalse(safety.hasInterruptedSample)
        lifecycle.pause()
    }

    func testConcurrentSampleRequestsAreSingleFlightAndCoalesced() async throws {
        let persistence = EphemeralSettingsPersistence()
        let settings = MonitoringSettingsStore(persistence: persistence)
        let probe = GatedCompletionProbe()
        let safety = MonitoringSafetyStateStore(persistence: persistence, key: "single-flight")
        let lifecycle = MonitoringLifecycleController(
            settingsStore: settings,
            probe: probe,
            notificationDelivery: DisabledNotificationDelivery(),
            changeCollector: nil,
            safetyState: safety
        )

        addTeardownBlock { @MainActor in lifecycle.shutdown(); await probe.finish() }
        let first = Task { await lifecycle.sampleNow() }
        try await probe.waitUntilStarted()
        await lifecycle.sampleNow()
        await probe.finish()
        await first.value
        try await probe.waitUntilStarted()

        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 2)
        await probe.finish()
        try await eventually { !safety.hasInterruptedSample }
        lifecycle.shutdown()
    }

    func testResourceCircuitBreakerStopsBeforeFilesystemTraversalAndHistoryIsBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let budget = ResourceBudget(maximumResidentBytes: 32 * 1_024 * 1_024)
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceBudget: budget,
            resourceMeasurementSource: { _, underLoad in
                ResourceMeasurement(
                    cpuPercent: 0,
                    residentBytes: 64 * 1_024 * 1_024,
                    databaseBytes: 0,
                    pendingEvents: 0,
                    receivedEvents: 0,
                    droppedEvents: 0,
                    underLoad: underLoad
                )
            }
        )

        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [directory.appending(path: "fixture-only-root").path]
        settings.excludedRoots = []
        for _ in 0 ..< 125 {
            do {
                _ = try await probe.sample(settings: settings)
                XCTFail("Expected the safety circuit breaker to stop the sample")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("circuit breaker"))
            }
        }

        let historyCount = await probe.boundedResourceHistory().count
        XCTAssertEqual(historyCount, 120)
    }

    func testDatabasePressureRunsStartupRecoveryBeforeCircuitBreaker() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        settings.maxDatabaseMiB = 10
        let source = SequencedDatabasePressureSource(capBytes: 10 * 1_024 * 1_024)
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024),
            resourceMeasurementSource: source.measure
        )

        let observation = try await probe.sample(settings: settings)

        XCTAssertNotNil(observation.evidenceLifecycle?.lastCompaction)
        XCTAssertGreaterThanOrEqual(source.callCount, 2)
        let reader = try EvidenceStore(url: database)
        let diagnostics = try await reader.diagnostics()
        XCTAssertEqual(diagnostics.observationCount, 1)
        await reader.close()
    }

    // 1.2.0 regression: a store near its cap has a file larger than its live
    // data (reusable free pages, a write-ahead log that grows during commits).
    // Judging the database by raw file size mid-sample stopped monitoring.
    func testDatabaseNearItsCapIsJudgedOnStoreAccountingThroughoutTheSample() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 40 {
            FileManager.default.createFile(atPath: watched.appending(path: "item-\(index)").path, contents: Data())
        }
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        settings.maxDatabaseMiB = 512
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024),
            resourceMeasurementSource: { _, underLoad in
                // The raw file family is always over the cap; live data is tiny.
                ResourceMeasurement(cpuPercent: 0, residentBytes: 0, databaseBytes: 520 * 1_024 * 1_024,
                                    pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: underLoad)
            }
        )

        let observation = try await probe.sample(settings: settings)

        XCTAssertNotNil(observation.evidenceLifecycle)
        let reader = try EvidenceStore(url: database)
        let diagnostics = try await reader.diagnostics()
        XCTAssertEqual(diagnostics.observationCount, 1)
        await reader.close()
    }

    func testConfiguredDatabaseLimitIsTheMonitoringSourceOfTruth() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        settings.maxDatabaseMiB = 1_024
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceMeasurementSource: { _, underLoad in
                ResourceMeasurement(
                    cpuPercent: 0,
                    residentBytes: 0,
                    databaseBytes: 600 * 1_024 * 1_024,
                    pendingEvents: 0,
                    receivedEvents: 0,
                    droppedEvents: 0,
                    underLoad: underLoad
                )
            }
        )

        let observation = try await probe.sample(settings: settings)

        XCTAssertNotNil(observation.evidenceLifecycle)
    }

    func testPersistentProbeCapsOneSafetySliceToARepresentableBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0 ..< 600 {
            FileManager.default.createFile(atPath: watched.appending(path: "item-\(index)").path, contents: Data())
        }
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        // Zero continuation budget: this test measures exactly one safety slice.
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024),
            continuationBudget: 0
        )

        _ = try await probe.sample(settings: settings)
        let reader = try EvidenceStore(url: database)
        let coverage = try await reader.scanCoverageStatus()
        XCTAssertEqual(coverage?.activeGeneration?.processedEntryCount, PersistentMonitoringProbe.maximumEntriesPerSafetySlice)
        XCTAssertEqual(coverage?.detailCoverage, "partial")
        await reader.close()
    }

    func testPersistentProbeStoresScheduledSnapshotAndDetailedDelta() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let watched = directory.appending(path: "watched", directoryHint: .isDirectory)
        let database = directory.appending(path: "store/evidence.sqlite")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = MonitoringSettings.defaults
        settings.watchedRoots = [watched.path]
        settings.excludedRoots = []
        let probe = try PersistentMonitoringProbe(
            databaseURL: database,
            resourceBudget: ResourceBudget(maximumResidentBytes: 2 * 1_024 * 1_024 * 1_024)
        )

        _ = try await probe.sample(settings: settings)
        try Data(repeating: 4, count: 8_192).write(to: watched.appending(path: "growth.bin"))
        let second = try await probe.sample(settings: settings)

        XCTAssertEqual(second.detailedEvents.count, 1)
        XCTAssertEqual(second.detailedEvents.first?.operation, .create)
        let reader = try EvidenceStore(url: database)
        let eventCount = try await reader.eventCount()
        let diagnostics = try await reader.diagnostics()
        XCTAssertEqual(eventCount, 1)
        XCTAssertGreaterThanOrEqual(diagnostics.snapshotCount, 2)
        XCTAssertEqual(diagnostics.integrity, "ok")
        await reader.close()
    }
}

@MainActor
private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0 ..< 10_000 {
        if predicate() { return }
        await Task.yield()
    }
    XCTFail("Expected deterministic task boundary was not reached", file: file, line: line)
    throw FixtureError()
}

/// Continuations are registered, advanced and cancelled under one lock, with
/// resumption outside the lock. Cancellation before registration is retained.
final class ManualLifecycleClock: @unchecked Sendable {
    // All fields are protected by the enclosing clock's lock.
    private final class Sleeper: @unchecked Sendable {
        let id = UUID()
        var deadline: TimeInterval = 0
        var cancelled = false
        var continuation: CheckedContinuation<Void, Error>?
    }
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var sleepers: [UUID: Sleeper] = [:]

    var clock: MonitoringLifecycleClock {
        MonitoringLifecycleClock(
            now: { self.lock.withLock { Date(timeIntervalSince1970: 1_800_000_000 + self.elapsed) } },
            uptime: { self.lock.withLock { self.elapsed } },
            sleep: { try await self.sleep($0) }
        )
    }

    var pendingSleeps: Int { lock.withLock { sleepers.count } }

    func advance(by seconds: TimeInterval) {
        let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
            elapsed += seconds
            let ready = sleepers.values.filter { $0.deadline <= elapsed }
            return ready.compactMap { sleeper in
                sleepers.removeValue(forKey: sleeper.id)
                defer { sleeper.continuation = nil }
                return sleeper.continuation
            }
        }
        ready.forEach { $0.resume() }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        if seconds <= 0 { try Task.checkCancellation(); return }
        let sleeper = Sleeper()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock {
                    if sleeper.cancelled { return true }
                    sleeper.deadline = elapsed + seconds
                    sleeper.continuation = continuation
                    sleepers[sleeper.id] = sleeper
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                sleeper.cancelled = true
                self.sleepers.removeValue(forKey: sleeper.id)
                defer { sleeper.continuation = nil }
                return sleeper.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private struct FixtureError: Error {}

private final class RecordingChangeCollector: MonitoringChangeCollecting, @unchecked Sendable {
    private let lock = NSLock()
    private var policy: MonitoringPolicy?
    private var running = false
    var lastPolicy: MonitoringPolicy? { lock.withLock { policy } }
    var isRunning: Bool { lock.withLock { running } }

    func restart(policy: MonitoringPolicy, at date: Date, latency: TimeInterval, handler: @escaping TargetedFSEventsCollector.Handler) throws {
        lock.withLock {
            self.policy = policy
            running = true
        }
    }
    func stop() { lock.withLock { running = false } }
}

private actor GatedCompletionProbe: MonitoringProbing {
    private var continuation: CheckedContinuation<MonitoringObservation, Never>?
    private(set) var callCount = 0
    private(set) var cancelledOnCompletion: [Bool] = []
    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        callCount += 1
        let observation = await withCheckedContinuation { continuation = $0 }
        cancelledOnCompletion.append(Task.isCancelled)
        return observation
    }
    func waitUntilStarted() async throws {
        for _ in 0 ..< 10_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        throw FixtureError()
    }
    func finish() {
        continuation?.resume(returning: fixtureObservation(used: 999, total: 1_000, growth: 100))
        continuation = nil
    }
}

private final class SequencedDatabasePressureSource: @unchecked Sendable {
    private let lock = NSLock()
    private let capBytes: Int64
    private var calls = 0

    init(capBytes: Int64) {
        self.capBytes = capBytes
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func measure(databaseURL _: URL, underLoad: Bool) -> ResourceMeasurement {
        let databaseBytes = lock.withLock { () -> Int64 in
            calls += 1
            return calls == 1 ? capBytes + 1 : 0
        }
        return ResourceMeasurement(
            cpuPercent: 0,
            residentBytes: 0,
            databaseBytes: databaseBytes,
            pendingEvents: 0,
            receivedEvents: 0,
            droppedEvents: 0,
            underLoad: underLoad
        )
    }
}

private actor FailingThenHealthyProbe: MonitoringProbing {
    private var calls = 0

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        calls += 1
        if calls == 1 { throw FixtureError() }
        return fixtureObservation(used: 750, total: 1_000, growth: 0)
    }
}

private struct AlwaysHealthyProbe: MonitoringProbing {
    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        fixtureObservation(used: 750, total: 1_000, growth: 0)
    }
}

private actor SlowCountingProbe: MonitoringProbing {
    private(set) var callCount = 0

    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        callCount += 1
        try await Task.sleep(for: .milliseconds(100))
        return fixtureObservation(used: 750, total: 1_000, growth: 0)
    }
}

private actor RecordingDelivery: MonitoringNotificationDelivering {
    private(set) var notifications: [MonitoringNotification] = []
    func deliver(_ notification: MonitoringNotification) async { notifications.append(notification) }
}

private func fixtureObservation(used: Int64, total: Int64, growth: Int64) -> MonitoringObservation {
    let snapshot = StorageSnapshot(
        snapshotID: UUID().uuidString,
        observedAt: "2026-09-13T00:00:00.000Z",
        volumes: [.init(mountPath: "/", totalBytes: total, availableBytes: total - used, isInternal: true, isReadOnly: false)]
    )
    let report = GrowthExplanationEngine().explain(volumeUsedDelta: growth, detailedEvents: [])
    return MonitoringObservation(observedAt: Date(), snapshot: snapshot, detailedEvents: [], growthReport: report)
}
