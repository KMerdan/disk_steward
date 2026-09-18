import DiskStewardCore
import Foundation
import UserNotifications
import XCTest
@testable import DiskStewardApp

@MainActor
final class NotificationDeliveryTests: XCTestCase {
    func testStopDuringSettingsReadPreventsPromptAndSubmission() async throws {
        for action in StopAction.allCases {
            for status in [UNAuthorizationStatus.authorized, .notDetermined] {
                let fixture = makeFixture(status: status)
                fixture.center.holdSettings = true
                let run = fixture.sample()
                try await eventually { fixture.center.settingsPending }
                XCTAssertTrue(fixture.safety.hasInterruptedSample)
                action.apply(to: fixture)
                let stoppedStatus = fixture.lifecycle.status
                fixture.center.releaseSettings()
                try await eventually { run.finished }
                XCTAssertEqual(fixture.center.authorizationCalls, 0, "\(action), \(status)")
                XCTAssertTrue(fixture.center.requests.isEmpty, "\(action), \(status)")
                XCTAssertEqual(fixture.lifecycle.status, stoppedStatus)
                XCTAssertFalse(fixture.safety.hasInterruptedSample)
            }
        }
    }

    func testStopDuringAuthorizationPreventsSubmission() async throws {
        for action in StopAction.allCases {
            let fixture = makeFixture(status: .notDetermined)
            fixture.center.holdAuthorization = true
            let run = fixture.sample()
            try await eventually { fixture.center.authorizationPending }
            action.apply(to: fixture)
            let stoppedStatus = fixture.lifecycle.status
            fixture.center.releaseAuthorization()
            try await eventually { run.finished }
            XCTAssertEqual(fixture.center.authorizationCalls, 1)
            XCTAssertTrue(fixture.center.requests.isEmpty, "\(action)")
            XCTAssertEqual(fixture.lifecycle.status, stoppedStatus)
            XCTAssertFalse(fixture.safety.hasInterruptedSample)
        }
    }

    func testAlreadyCancelledDeliveryDoesNotContactCenter() async {
        let center = FixtureNotificationCenter(status: .notDetermined)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await UserNotificationDelivery(center: center).deliver(Self.message)
        }
        await task.value
        XCTAssertEqual(center.settingsCalls, 0)
        XCTAssertEqual(center.authorizationCalls, 0)
        XCTAssertTrue(center.requests.isEmpty)
    }

    func testDeniedRefusedAndFailedAuthorizationDoNotSubmit() async {
        for outcome in ["denied", "refused", "error"] {
            let center = FixtureNotificationCenter(status: outcome == "denied" ? .denied : .notDetermined)
            center.authorizationGranted = false
            center.authorizationFails = outcome == "error"
            await UserNotificationDelivery(center: center).deliver(Self.message)
            XCTAssertEqual(center.authorizationCalls, outcome == "denied" ? 0 : 1)
            XCTAssertTrue(center.requests.isEmpty, outcome)
        }
    }

    func testAuthorizedProvisionalAndNewlyGrantedDeliveryPreservePayload() async {
        for status in [UNAuthorizationStatus.authorized, .provisional, .notDetermined] {
            let center = FixtureNotificationCenter(status: status)
            let delivery = UserNotificationDelivery(center: center)
            await delivery.deliver(Self.message)
            await delivery.deliver(Self.message)
            XCTAssertEqual(center.requests.count, 2)
            XCTAssertEqual(center.authorizationCalls, status == .notDetermined ? 1 : 0)
            XCTAssertEqual(Set(center.requests.map(\.identifier)).count, 2)
            for request in center.requests {
                XCTAssertEqual(request.content.title, Self.message.title)
                XCTAssertEqual(request.content.body, Self.message.body)
                XCTAssertNotNil(request.content.sound)
                XCTAssertNil(request.trigger)
            }
        }
    }

    func testSubmittedAlertCanCompleteButCancellationStopsTheNextAlert() async throws {
        for action in StopAction.allCases {
            let fixture = makeFixture(status: .authorized)
            fixture.center.holdSubmission = true
            let run = fixture.sample()
            try await eventually { fixture.center.submissionPending }
            XCTAssertEqual(fixture.center.requests.count, 1)
            action.apply(to: fixture)
            XCTAssertTrue(fixture.safety.hasInterruptedSample)
            fixture.center.releaseSubmission()
            try await eventually { run.finished }
            // Pause cannot retract the first OS submission, but there must not
            // be a second alert for this already-cancelled sample.
            XCTAssertEqual(fixture.center.requests.count, 1, "\(action)")
            XCTAssertFalse(fixture.safety.hasInterruptedSample)
        }
    }

    func testQuitDeadlineDoesNotClaimAnUnfinishedSubmissionDrained() async throws {
        let fixture = makeFixture(status: .authorized)
        fixture.center.holdSubmission = true
        let run = fixture.sample()
        try await eventually { fixture.center.submissionPending }
        let drained = await fixture.lifecycle.shutdownAndDrain(timeout: 0)
        XCTAssertFalse(drained)
        XCTAssertFalse(run.finished)
        XCTAssertTrue(fixture.safety.hasInterruptedSample)
        fixture.center.releaseSubmission()
        try await eventually { run.finished }
        XCTAssertFalse(fixture.safety.hasInterruptedSample)
        XCTAssertEqual(fixture.center.requests.count, 1)
    }

    private static let message = MonitoringNotification(title: "Fixture capacity", body: "Synthetic evidence only")

    private func makeFixture(status: UNAuthorizationStatus) -> NotificationLifecycleFixture {
        let fixture = NotificationLifecycleFixture(status: status)
        addTeardownBlock { @MainActor in fixture.stop() }
        return fixture
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Notification fixture did not reach its bounded checkpoint", file: file, line: line)
        throw FixtureNotificationError.checkpoint
    }
}

private enum FixtureNotificationError: Error { case authorization, checkpoint }

private enum StopAction: CaseIterable {
    case pause, sleep, quit, settingsPause, settingsChange

    @MainActor
    func apply(to fixture: NotificationLifecycleFixture) {
        switch self {
        case .pause: fixture.lifecycle.pause()
        case .sleep: fixture.lifecycle.prepareForSystemSleep()
        case .quit: fixture.lifecycle.shutdown()
        case .settingsPause: fixture.settings.update { $0.monitoringPaused = true }
        case .settingsChange: fixture.settings.update { $0.capacityThresholdPercent = 99 }
        }
    }
}

@MainActor
private final class NotificationSampleRun {
    var finished = false
}

@MainActor
private final class NotificationLifecycleFixture {
    let center: FixtureNotificationCenter
    let settings: MonitoringSettingsStore
    let safety: MonitoringSafetyStateStore
    let lifecycle: MonitoringLifecycleController

    init(status: UNAuthorizationStatus) {
        let persistence = EphemeralSettingsPersistence()
        settings = MonitoringSettingsStore(persistence: persistence)
        settings.update { $0.capacityThresholdPercent = 50; $0.growthThresholdMiB = 1 }
        safety = MonitoringSafetyStateStore(persistence: persistence)
        center = FixtureNotificationCenter(status: status)
        lifecycle = MonitoringLifecycleController(settingsStore: settings, probe: NotificationThresholdProbe(), notificationDelivery: UserNotificationDelivery(center: center), changeCollector: nil, safetyState: safety)
    }

    func sample() -> NotificationSampleRun {
        let run = NotificationSampleRun()
        Task { await lifecycle.sampleNow(); run.finished = true }
        return run
    }

    func stop() {
        lifecycle.shutdown()
        center.releaseAll()
    }
}

private struct NotificationThresholdProbe: MonitoringProbing {
    func sample(settings: MonitoringSettings) async throws -> MonitoringObservation {
        let snapshot = StorageSnapshot(snapshotID: UUID().uuidString, observedAt: "2026-09-17T00:00:00.000Z", volumes: [.init(mountPath: "/", totalBytes: 1_000, availableBytes: 100, isInternal: true, isReadOnly: false)])
        return MonitoringObservation(observedAt: Date(timeIntervalSince1970: 1_789_603_200), snapshot: snapshot, detailedEvents: [], growthReport: GrowthExplanationEngine().explain(volumeUsedDelta: 2 * 1_024 * 1_024, detailedEvents: []))
    }
}

@MainActor
private final class FixtureNotificationCenter: MonitoringUserNotificationCenter {
    var status: UNAuthorizationStatus
    var holdSettings = false
    var holdAuthorization = false
    var holdSubmission = false
    var authorizationGranted = true
    var authorizationFails = false
    private(set) var settingsCalls = 0
    private(set) var authorizationCalls = 0
    private(set) var requests: [UNNotificationRequest] = []
    private var settingsContinuation: CheckedContinuation<Void, Never>?
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var submissionCompletion: (@Sendable (Error?) -> Void)?

    var settingsPending: Bool { settingsContinuation != nil }
    var authorizationPending: Bool { authorizationContinuation != nil }
    var submissionPending: Bool { submissionCompletion != nil }

    init(status: UNAuthorizationStatus) { self.status = status }

    func authorizationStatus() async -> UNAuthorizationStatus {
        settingsCalls += 1
        if holdSettings { await withCheckedContinuation { settingsContinuation = $0 } }
        return status
    }

    func requestAuthorization() async throws -> Bool {
        authorizationCalls += 1
        if holdAuthorization { await withCheckedContinuation { authorizationContinuation = $0 } }
        if authorizationFails { throw FixtureNotificationError.authorization }
        status = authorizationGranted ? .authorized : .denied
        return authorizationGranted
    }

    func submit(_ request: UNNotificationRequest, completion: @escaping @Sendable (Error?) -> Void) {
        requests.append(request)
        if holdSubmission { submissionCompletion = completion } else { completion(nil) }
    }

    func releaseSettings() {
        holdSettings = false
        let continuation = settingsContinuation
        settingsContinuation = nil
        continuation?.resume()
    }

    func releaseAuthorization() {
        holdAuthorization = false
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        continuation?.resume()
    }

    func releaseSubmission() {
        holdSubmission = false
        let completion = submissionCompletion
        submissionCompletion = nil
        completion?(nil)
    }

    func releaseAll() { releaseSettings(); releaseAuthorization(); releaseSubmission() }
}
