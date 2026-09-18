import CSQLite
import Foundation
import XCTest
@testable import DiskStewardApp
@testable import DiskStewardCore

@MainActor
final class MonitoringReceiptTests: XCTestCase {
    func testMailboxCoalescesBurstAndAcknowledgesOnlyCumulativeLatestReceipt() throws {
        let inbox = MonitoringChangeInbox(at: receiptDate)
        XCTAssertThrowsError(try inbox.publicationPermit())
        let stream = inbox.beginStream(rootPaths: ["/a", "/b"], at: receiptDate)
        XCTAssertTrue(inbox.acknowledge(try XCTUnwrap(inbox.snapshot())))
        XCTAssertTrue(inbox.releaseDrainWakeIfClean())
        let before = try inbox.publicationPermit()
        var wakes = 0
        for _ in 0..<10_000 {
            if inbox.receive(hint("/a/file"), stream: stream, at: receiptDate) { wakes += 1 }
        }
        let first = try XCTUnwrap(inbox.snapshot())
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(first.rootPaths, ["/a"])
        XCTAssertFalse(inbox.receive(hint("/b/file"), stream: stream, at: receiptDate))
        XCTAssertFalse(inbox.acknowledge(first), "Equal timestamps must not erase a newer receipt")
        XCTAssertThrowsError(try inbox.publicationPermit())
        let latest = try XCTUnwrap(inbox.snapshot())
        XCTAssertEqual(latest.rootPaths, ["/a", "/b"])
        XCTAssertTrue(inbox.acknowledge(latest))
        XCTAssertThrowsError(try before.validate())
        try inbox.publicationPermit().validate()
        XCTAssertTrue(inbox.releaseDrainWakeIfClean())
        XCTAssertTrue(inbox.receive(hint("/a/new"), stream: stream, at: receiptDate))
    }

    func testMailboxStreamIdentityAndOverflowRemainExplicitUncertainty() throws {
        let inbox = MonitoringChangeInbox(at: receiptDate)
        let old = inbox.beginStream(rootPaths: ["/a"], at: receiptDate)
        let current = inbox.beginStream(rootPaths: ["/b"], at: receiptDate)
        inbox.acknowledge(try XCTUnwrap(inbox.snapshot()))
        XCTAssertTrue(inbox.releaseDrainWakeIfClean())
        XCTAssertFalse(inbox.receive(hint("/a/file"), stream: old, at: receiptDate))
        XCTAssertFalse(inbox.hasPendingChanges)
        let burst = TargetedChangeBatch(hints: Array(repeating: hint("/b/file").hints[0], count: 257), eventGap: false, limitations: [])
        XCTAssertTrue(inbox.receive(burst, stream: current, at: receiptDate))
        XCTAssertEqual(inbox.snapshot()?.rootPaths, ["*"])
        inbox.endStream(at: receiptDate)
        let stopped = inbox.snapshot()?.revision
        XCTAssertFalse(inbox.receive(hint("/b/file"), stream: current, at: receiptDate))
        XCTAssertEqual(inbox.snapshot()?.revision, stopped)
        let many = inbox.beginStream(rootPaths: (0..<65).map { "/root-\($0)" }, at: receiptDate)
        inbox.acknowledge(try XCTUnwrap(inbox.snapshot()))
        XCTAssertTrue(inbox.releaseDrainWakeIfClean())
        XCTAssertTrue(inbox.receive(hint("/root-0/file"), stream: many, at: receiptDate))
        XCTAssertEqual(inbox.snapshot()?.rootPaths, ["*"])
    }

    func testOrdinaryControllerReceiptDuringStorePreparationRejectsStalePublication() async throws {
        try await assertOrdinaryControllerReceiptRejectsStalePublication(beforeAdmission: false)
    }

    func testOrdinaryControllerReceiptBeforeStoreAdmissionRejectsStalePublication() async throws {
        try await assertOrdinaryControllerReceiptRejectsStalePublication(beforeAdmission: true)
    }

    private func assertOrdinaryControllerReceiptRejectsStalePublication(beforeAdmission: Bool) async throws {
        let fixture = try ReceiptFixture()
        let gate = ReceiptPublicationGate(point: beforeAdmission ? "before-volume" : "after-present-objects")
        let store = try EvidenceStore(url: fixture.database, reconciliationCheckpoint: gate.checkpoint)
        let probe = try fixture.probe(store: store, beforeVolumeSample: { try gate.checkpoint("before-volume") })
        let settings = fixture.settingsStore()
        let collector = ReceiptCollector()
        let clock = ManualLifecycleClock()
        let safety = MonitoringSafetyStateStore(persistence: settings.persistence)
        let controller = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: collector, safetyState: safety, clock: clock.clock)
        addTeardownBlock {
            gate.release()
            _ = await controller.shutdownAndDrain(timeout: 0)
            await store.close()
            fixture.remove()
        }
        controller.start()
        try await receiptEventually { controller.latestObservation != nil && !safety.hasInterruptedSample }
        let baseline = try await store.currentFiles(includeNonActionable: true)
        let baselineCount = try await store.diagnostics().observationCount
        gate.arm()
        let sample = Task { await controller.sampleNow() }
        try await receiptEventually { gate.entered }
        try FileManager.default.removeItem(at: fixture.root.appending(path: "A"))
        collector.emit(hint(fixture.root.appending(path: "A").path))
        XCTAssertTrue(probe.changeInbox!.hasPendingChanges)
        XCTAssertThrowsError(try probe.changeInbox!.publicationPermit())
        gate.release()
        await sample.value
        try await receiptEventually { !probe.changeInbox!.hasPendingChanges && !safety.hasInterruptedSample }
        let retained = try await store.currentFiles(includeNonActionable: true)
        XCTAssertEqual(retained, baseline, "Rejected publication cannot remove A or refresh old membership")
        let afterRejected = try await store.diagnostics().observationCount
        XCTAssertEqual(afterRejected, baselineCount)
        clock.advance(by: 1)
        try await receiptEventually {
            let present = try await store.currentFiles().filter { $0.presence == .present }.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted()
            return present == ["B", "C"] && !safety.hasInterruptedSample
        }
        let all = try await store.currentFiles(includeNonActionable: true)
        XCTAssertNil(all.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent == "A" }))
        XCTAssertEqual(controller.latestObservation?.detailedEvents.filter { $0.operation == .delete }.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["A"])
        let drained = await controller.shutdownAndDrain()
        XCTAssertTrue(drained)
    }

    func testPauseAndSleepPersistPendingReceiptsAndIgnoreOldCallbacksAfterResume() async throws {
        for action in ["pause", "sleep"] {
            let fixture = try ReceiptFixture()
            let store = try EvidenceStore(url: fixture.database)
            let probe = try fixture.probe(store: store)
            let settings = fixture.settingsStore()
            let collector = ReceiptCollector()
            let clock = ManualLifecycleClock()
            let safety = MonitoringSafetyStateStore(persistence: settings.persistence)
            let controller = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: collector, safetyState: safety, clock: clock.clock)
            addTeardownBlock {
                _ = await controller.shutdownAndDrain(timeout: 0)
                await store.close()
                fixture.remove()
            }
            controller.start()
            try await receiptEventually { controller.latestObservation != nil && !safety.hasInterruptedSample }
            let oldCallback = try XCTUnwrap(collector.callback)
            collector.emit(hint(fixture.root.appending(path: "A").path))
            if action == "pause" { controller.pause() } else { controller.prepareForSystemSleep() }
            try await receiptEventually { !probe.changeInbox!.hasPendingChanges && !safety.hasInterruptedSample }
            XCTAssertEqual(controller.status.kind, .paused)
            let pending = try await store.hasPendingReconciliation()
            XCTAssertTrue(pending, "Persistence does not falsely claim the paused scan reconciled")
            oldCallback(hint(fixture.root.appending(path: "A").path))
            XCTAssertFalse(probe.changeInbox!.hasPendingChanges)
            if action == "pause" { controller.resume() } else { controller.resumeAfterSystemWake() }
            let resumedRevision = probe.changeInbox!.snapshot()?.revision
            XCTAssertNotNil(resumedRevision)
            oldCallback(hint(fixture.root.appending(path: "A").path))
            XCTAssertEqual(probe.changeInbox!.snapshot()?.revision, resumedRevision)
            let drained = await controller.shutdownAndDrain()
            XCTAssertTrue(drained)
        }
    }

    func testPersistenceFailureFencesSamplingRetainsMarkerAndRetries() async throws {
        let fixture = try ReceiptFixture()
        let store = try EvidenceStore(url: fixture.database)
        let probe = try fixture.probe(store: store)
        let settings = fixture.settingsStore()
        let collector = ReceiptCollector()
        let clock = ManualLifecycleClock()
        let safety = MonitoringSafetyStateStore(persistence: settings.persistence)
        let controller = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: collector, safetyState: safety, clock: clock.clock)
        addTeardownBlock {
            _ = await controller.shutdownAndDrain(timeout: 0)
            await store.close()
            fixture.remove()
        }
        controller.start()
        try await receiptEventually { controller.latestObservation != nil && !safety.hasInterruptedSample }
        let before = try await store.diagnostics().observationCount
        try fixture.sql("CREATE TRIGGER fail_receipt BEFORE INSERT ON reconciliation_invalidations BEGIN SELECT RAISE(ABORT, 'fixture-write-denied'); END")
        collector.emit(hint(fixture.root.appending(path: "A").path))
        try await receiptEventually { controller.status.title == "Reconciliation pending" && clock.pendingSleeps >= 2 }
        XCTAssertTrue(probe.changeInbox!.hasPendingChanges)
        XCTAssertTrue(safety.hasInterruptedSample)
        await controller.sampleNow()
        let stillBefore = try await store.diagnostics().observationCount
        XCTAssertEqual(stillBefore, before)
        XCTAssertThrowsError(try probe.changeInbox!.publicationPermit())
        try fixture.sql("DROP TRIGGER fail_receipt")
        clock.advance(by: 1)
        try await receiptEventually { !probe.changeInbox!.hasPendingChanges && !safety.hasInterruptedSample }
        let drained = await controller.shutdownAndDrain()
        XCTAssertTrue(drained)
    }

    func testOrdinaryProbeReceiptPreservesIndependentRootProgress() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let other = fixture.directory.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        for root in [fixture.root, other] {
            for index in 0..<600 { try Data().write(to: root.appending(path: "item-\(index)")) }
        }
        let store = try EvidenceStore(url: fixture.database)
        let probe = try fixture.probe(store: store)
        var settings = fixture.settingsStore().settings
        settings.watchedRoots = [fixture.root.path, other.path]
        let inbox = try XCTUnwrap(probe.changeInbox)
        let stream = inbox.beginStream(rootPaths: settings.watchedRoots, at: receiptDate)
        _ = try await probe.sample(settings: settings)
        let beforeCoverage = try await store.scanCoverageStatus()
        let before = try XCTUnwrap(beforeCoverage?.activeGeneration)
        let independent = try XCTUnwrap(before.roots.first { $0.rootPath == other.path })
        XCTAssertGreaterThan(independent.observedFileCount, 0, "The independent root must have actual staged progress")
        XCTAssertTrue(inbox.releaseDrainWakeIfClean())
        XCTAssertTrue(inbox.receive(hint(fixture.root.appending(path: "A").path), stream: stream, at: receiptDate))
        try await probe.persistPendingChanges()
        let afterCoverage = try await store.scanCoverageStatus()
        let after = try XCTUnwrap(afterCoverage?.activeGeneration)
        XCTAssertNotEqual(after.reconciliationToken, before.reconciliationToken)
        XCTAssertEqual(after.roots.first { $0.rootPath == other.path }, independent)
        XCTAssertEqual(after.roots.first { $0.rootPath == fixture.root.path }?.observedFileCount, 0)
        XCTAssertFalse(inbox.hasPendingChanges)
        await store.close()
    }

    func testNewProbeInvalidatesStagingAfterUnpersistedReceiptAndStoreReopen() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        for index in 0..<600 { try Data().write(to: fixture.root.appending(path: "item-\(index)")) }
        let store = try EvidenceStore(url: fixture.database)
        let probe = try fixture.probe(store: store)
        let settings = fixture.settingsStore().settings
        for _ in 0..<20 {
            if try await !probe.sample(settings: settings).needsScanContinuation { break }
        }
        let before = try await store.diagnostics().observationCount
        XCTAssertEqual(before, 1)
        let inbox = try XCTUnwrap(probe.changeInbox)
        let stream = inbox.beginStream(rootPaths: settings.watchedRoots, at: receiptDate)
        _ = try await probe.sample(settings: settings)
        let stagingCoverage = try await store.scanCoverageStatus()
        let staged = try XCTUnwrap(stagingCoverage?.activeGeneration)
        XCTAssertGreaterThan(staged.stagedFileCount, 0)
        try FileManager.default.removeItem(at: fixture.root.appending(path: "A"))
        _ = inbox.receive(hint(fixture.root.appending(path: "A").path), stream: stream, at: receiptDate)
        // Deliberately do not persist/acknowledge the receipt before closing.
        await store.close()
        let reopened = try EvidenceStore(url: fixture.database)
        let next = try fixture.probe(store: reopened)
        XCTAssertThrowsError(try next.changeInbox!.publicationPermit())
        try await next.persistPendingChanges()
        let resetCoverage = try await reopened.scanCoverageStatus()
        let reset = try XCTUnwrap(resetCoverage?.activeGeneration)
        XCTAssertNotEqual(reset.reconciliationToken, staged.reconciliationToken)
        XCTAssertEqual(reset.stagedFileCount, 0)
        let pending = try await reopened.hasPendingReconciliation()
        XCTAssertTrue(pending)
        var final: MonitoringObservation?
        for _ in 0..<20 {
            let observation = try await next.sample(settings: settings)
            if !observation.needsScanContinuation { final = observation; break }
        }
        XCTAssertNotNil(final)
        XCTAssertEqual(final?.detailedEvents.filter { $0.operation == .delete }.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["A"])
        let current = try await reopened.currentFiles(includeNonActionable: true)
        XCTAssertFalse(current.contains { $0.path == fixture.root.appending(path: "A").path })
        await reopened.close()
    }

    func testQuitWithUnpersistableReceiptReportsUndrainedAndKeepsSafetyMarker() async throws {
        let fixture = try ReceiptFixture()
        let store = try EvidenceStore(url: fixture.database)
        let probe = try fixture.probe(store: store)
        let settings = fixture.settingsStore()
        let collector = ReceiptCollector()
        let safety = MonitoringSafetyStateStore(persistence: settings.persistence)
        let controller = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: collector, safetyState: safety)
        addTeardownBlock {
            _ = await controller.shutdownAndDrain(timeout: 0)
            await store.close()
            fixture.remove()
        }
        controller.start()
        try await receiptEventually { controller.latestObservation != nil && !safety.hasInterruptedSample }
        try fixture.sql("CREATE TRIGGER fail_receipt BEFORE INSERT ON reconciliation_invalidations BEGIN SELECT RAISE(ABORT, 'fixture-write-denied'); END")
        collector.emit(hint(fixture.root.appending(path: "A").path))
        let drained = await controller.shutdownAndDrain()
        XCTAssertFalse(drained)
        XCTAssertTrue(safety.hasInterruptedSample)
        XCTAssertTrue(probe.changeInbox!.hasPendingChanges)
    }

    func testReceiptDrainDoesNotAcknowledgePreviousCrashWithoutUserResume() async throws {
        let fixture = try ReceiptFixture()
        let store = try EvidenceStore(url: fixture.database)
        let probe = try fixture.probe(store: store)
        let settings = fixture.settingsStore()
        let safety = MonitoringSafetyStateStore(persistence: settings.persistence)
        safety.markSampleStarted(at: receiptDate)
        let controller = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: ReceiptCollector(), safetyState: safety)
        addTeardownBlock {
            _ = await controller.shutdownAndDrain(timeout: 0)
            await store.close()
            fixture.remove()
        }
        controller.start()
        XCTAssertEqual(controller.status.title, "Safety Pause")
        XCTAssertTrue(settings.settings.monitoringPaused)
        let drained = await controller.shutdownAndDrain()
        XCTAssertTrue(drained, "The startup uncertainty receipt can persist while monitoring remains paused")
        XCTAssertFalse(probe.changeInbox!.hasPendingChanges)
        XCTAssertTrue(safety.hasInterruptedSample, "Persisting a receipt must not acknowledge an interrupted sample from a previous launch")
        let next = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: nil, safetyState: safety)
        XCTAssertEqual(next.status.title, "Safety Pause")
        next.shutdown()
    }

    func testUserResumePreservesMarkerForReceiptPersistenceStillInFlight() async throws {
        let fixture = try ReceiptFixture()
        let gate = ReceiptPublicationGate(point: "before-invalidation")
        let store = try EvidenceStore(url: fixture.database, reconciliationCheckpoint: gate.checkpoint)
        let probe = try fixture.probe(store: store)
        let settings = fixture.settingsStore()
        let safety = MonitoringSafetyStateStore(persistence: settings.persistence)
        safety.markSampleStarted(at: receiptDate)
        let controller = MonitoringLifecycleController(settingsStore: settings, probe: probe, notificationDelivery: DisabledNotificationDelivery(), changeCollector: ReceiptCollector(), safetyState: safety)
        addTeardownBlock {
            gate.release()
            _ = await controller.shutdownAndDrain(timeout: 0)
            await store.close()
            fixture.remove()
        }
        gate.arm()
        settings.update { $0.sampleIntervalMinutes = 10 }
        try await receiptEventually { gate.entered }
        XCTAssertTrue(safety.hasInterruptedSample)
        controller.resume()
        XCTAssertTrue(safety.hasInterruptedSample, "Acknowledging the previous launch must not clear the marker owned by this launch's persistence")
        controller.pause()
        gate.release()
        try await receiptEventually { !probe.changeInbox!.hasPendingChanges && !safety.hasInterruptedSample }
        XCTAssertEqual(controller.status.kind, .paused)
        let drained = await controller.shutdownAndDrain()
        XCTAssertTrue(drained)
    }

    func testNewReceiptDuringActualPersistenceCannotBeClearedByOldCompletion() async throws {
        let fixture = try ReceiptFixture()
        let gate = ReceiptPublicationGate(point: "before-invalidation")
        let store = try EvidenceStore(url: fixture.database, reconciliationCheckpoint: gate.checkpoint)
        let probe = try fixture.probe(store: store)
        addTeardownBlock { gate.release(); await store.close(); fixture.remove() }
        let inbox = try XCTUnwrap(probe.changeInbox)
        let other = fixture.directory.appending(path: "z-other").path
        let stream = inbox.beginStream(rootPaths: [fixture.root.path, other], at: receiptDate)
        try await probe.persistPendingChanges()
        XCTAssertTrue(inbox.releaseDrainWakeIfClean())
        XCTAssertTrue(inbox.receive(hint(fixture.root.appending(path: "A").path), stream: stream, at: receiptDate))
        let oldRevision = inbox.snapshot()?.revision
        gate.arm()
        let first = Task { try await probe.persistPendingChanges() }
        try await receiptEventually { gate.entered }
        // Same timestamp, different root, while SQLite owns the old receipt.
        XCTAssertFalse(inbox.receive(hint(other + "/new"), stream: stream, at: receiptDate))
        gate.release()
        try await first.value
        let pending = try XCTUnwrap(inbox.snapshot())
        XCTAssertNotEqual(pending.revision, oldRevision)
        XCTAssertEqual(pending.rootPaths, [fixture.root.path, other].sorted())
        XCTAssertThrowsError(try inbox.publicationPermit())
        let quotedFirst = fixture.root.path.replacingOccurrences(of: "'", with: "''")
        let quotedOther = other.replacingOccurrences(of: "'", with: "''")
        try fixture.sql("CREATE TABLE fixture_receipt_attempts (root TEXT NOT NULL)")
        try fixture.sql("CREATE TRIGGER count_first_receipt BEFORE INSERT ON reconciliation_invalidations WHEN NEW.root_path = '\(quotedFirst)' BEGIN INSERT INTO fixture_receipt_attempts VALUES (NEW.root_path); END")
        try fixture.sql("CREATE TRIGGER fail_second_receipt BEFORE INSERT ON reconciliation_invalidations WHEN NEW.root_path = '\(quotedOther)' BEGIN SELECT RAISE(ABORT, 'fixture-second-root-denied'); END")
        do {
            try await probe.persistPendingChanges()
            XCTFail("The second root must fail after the first root is durable")
        } catch { }
        XCTAssertEqual(inbox.snapshot()?.revision, pending.revision)
        XCTAssertEqual(inbox.snapshot()?.rootPaths, pending.rootPaths)
        XCTAssertThrowsError(try inbox.publicationPermit())
        let partialCount = try await store.pendingReconciliationCount()
        XCTAssertEqual(partialCount, 2)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM fixture_receipt_attempts"), 1,
                       "The first root must newly commit in this failing two-root attempt, not merely exist from an older receipt")
        try fixture.sql("DROP TRIGGER fail_second_receipt")
        try await probe.persistPendingChanges()
        XCTAssertFalse(inbox.hasPendingChanges)
        try inbox.publicationPermit().validate()
        // Startup global uncertainty and both cumulative root invalidations.
        let durableCount = try await store.pendingReconciliationCount()
        XCTAssertEqual(durableCount, 3)
        XCTAssertEqual(try fixture.scalar("SELECT COUNT(*) FROM fixture_receipt_attempts"), 2,
                       "Retry conservatively persists the entire cumulative receipt again")
    }
}

private let receiptDate = Date(timeIntervalSince1970: 2_100_100_000)

private func hint(_ path: String) -> TargetedChangeBatch {
    .init(hints: [.init(path: path, eventID: 7, observedAt: receiptDate, kind: .modified, requiresRescan: true)], eventGap: false, limitations: [])
}

@MainActor
private func receiptEventually(_ predicate: () async throws -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while ProcessInfo.processInfo.systemUptime < deadline {
        if try await predicate() { return }
        await Task.yield()
    }
    XCTFail("Receipt fixture did not reach its bounded checkpoint")
    throw ReceiptTestError.timeout
}

private final class ReceiptCollector: MonitoringChangeCollecting, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: TargetedFSEventsCollector.Handler?
    var callback: TargetedFSEventsCollector.Handler? { lock.withLock { handler } }
    func restart(policy: MonitoringPolicy, at date: Date, latency: TimeInterval, handler: @escaping TargetedFSEventsCollector.Handler) throws {
        lock.withLock { self.handler = handler }
    }
    func stop() { lock.withLock { handler = nil } }
    func emit(_ batch: TargetedChangeBatch) { callback?(batch) }
}

private final class ReceiptPublicationGate: @unchecked Sendable {
    private let point: String
    private let lock = NSLock()
    private let resumed = DispatchSemaphore(value: 0)
    private var armed = false
    private var waiting = false
    init(point: String = "after-present-objects") { self.point = point }
    var entered: Bool { lock.withLock { waiting } }
    func arm() { lock.withLock { armed = true } }
    func release() { resumed.signal() }
    func checkpoint(_ point: String) throws {
        let wait = lock.withLock {
            guard point == self.point, armed else { return false }
            armed = false
            waiting = true
            return true
        }
        if wait, resumed.wait(timeout: .now() + 5) != .success { throw ReceiptTestError.timeout }
    }
}

private struct ReceiptFixture: Sendable {
    let directory: URL
    let root: URL
    let database: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ds-receipt-\(UUID().uuidString)")
        root = directory.appending(path: "watched")
        database = directory.appending(path: "store/evidence.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A", "B", "C"] { try Data([1]).write(to: root.appending(path: name)) }
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    @MainActor func settingsStore() -> MonitoringSettingsStore {
        let store = MonitoringSettingsStore(persistence: EphemeralSettingsPersistence())
        store.update {
            $0.watchedRoots = [root.path]
            $0.excludedRoots = []
            $0.monitoringPaused = false
        }
        return store
    }
    func probe(store: EvidenceStore, beforeVolumeSample: @escaping @Sendable () throws -> Void = {}) throws -> PersistentMonitoringProbe {
        try PersistentMonitoringProbe(databaseURL: database, evidenceStore: store, resourceMeasurementSource: { _, load in
            .init(cpuPercent: 0, residentBytes: 0, databaseBytes: 0, pendingEvents: 0, receivedEvents: 0, droppedEvents: 0, underLoad: load)
        }, volumeSampleSource: { _ in
            try beforeVolumeSample()
            let snapshot = StorageSnapshot(snapshotID: UUID().uuidString, observedAt: "2036-07-20T00:00:00Z", volumes: [.init(mountPath: "/fixture", totalBytes: 10_000, availableBytes: 9_000, isInternal: true, isReadOnly: false)])
            return (snapshot, .init(observedAt: snapshot.observedAt, usedByteDeltas: ["/fixture": 0], limitations: []))
        }, continuationBudget: 0) // receipt fencing is proven one slice at a time
    }
    func sql(_ sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK, let connection else { throw ReceiptTestError.sql }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw ReceiptTestError.sql }
    }
    func scalar(_ sql: String) throws -> Int {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK, let connection else { throw ReceiptTestError.sql }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ReceiptTestError.sql }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ReceiptTestError.sql }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private enum ReceiptTestError: Error { case timeout, sql }
