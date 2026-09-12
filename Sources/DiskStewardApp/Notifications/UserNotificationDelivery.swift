import Foundation
import UserNotifications

protocol MonitoringNotificationDelivering: Sendable {
    func deliver(_ notification: MonitoringNotification) async
}

struct UserNotificationDelivery: MonitoringNotificationDelivering {
    func deliver(_ notification: MonitoringNotification) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}
