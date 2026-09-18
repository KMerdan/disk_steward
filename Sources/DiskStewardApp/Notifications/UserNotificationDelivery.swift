import Foundation
import UserNotifications

protocol MonitoringNotificationDelivering: Sendable {
    func deliver(_ notification: MonitoringNotification) async
}

/// Explicitly selected by isolated smoke launches and fixture-only tests.
struct DisabledNotificationDelivery: MonitoringNotificationDelivering {
    func deliver(_ notification: MonitoringNotification) async {}
}

struct UserNotificationDelivery: MonitoringNotificationDelivering {
    private let center: (any MonitoringUserNotificationCenter)?

    init(center: (any MonitoringUserNotificationCenter)? = nil) {
        self.center = center
    }

    @MainActor
    func deliver(_ notification: MonitoringNotification) async {
        guard !Task.isCancelled else { return }
        let center = center ?? SystemMonitoringUserNotificationCenter()
        let status = await center.authorizationStatus()
        guard !Task.isCancelled else { return }
        switch status {
        case .notDetermined:
            guard (try? await center.requestAuthorization()) == true, !Task.isCancelled else { return }
        case .authorized, .provisional:
            break
        case .denied:
            return
        @unknown default:
            return
        }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        await withCheckedContinuation { continuation in
            // No suspension between this check and native submission. Pause,
            // sleep, quit and settings invalidation use this same main actor.
            // A request already handed to the OS cannot be recalled here.
            guard !Task.isCancelled else { continuation.resume(); return }
            center.submit(request) { _ in continuation.resume() }
        }
    }
}

/// Submission is synchronous on the lifecycle actor; the OS completion remains
/// asynchronous. Keeping these distinct makes the external side-effect boundary
/// injectable without real permission prompts or notification-center writes.
@MainActor
protocol MonitoringUserNotificationCenter: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func submit(_ request: UNNotificationRequest, completion: @escaping @Sendable (Error?) -> Void)
}

@MainActor
private struct SystemMonitoringUserNotificationCenter: MonitoringUserNotificationCenter {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func submit(_ request: UNNotificationRequest, completion: @escaping @Sendable (Error?) -> Void) {
        center.add(request, withCompletionHandler: completion)
    }
}
