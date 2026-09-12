import DiskStewardCore
import Foundation

struct MonitoringNotification: Equatable, Sendable {
    let title: String
    let body: String
}

struct ThresholdNotificationPolicy: Sendable {
    private var capacityWasAbove = false
    private var growthWasAbove = false

    mutating func evaluate(observation: MonitoringObservation, settings: MonitoringSettings) -> [MonitoringNotification] {
        let volume = observation.snapshot.volumes.first { $0.isInternal && !$0.isReadOnly } ?? observation.snapshot.volumes.first
        let percent = volume.flatMap { $0.totalBytes > 0 ? Int((Double($0.usedBytes) / Double($0.totalBytes)) * 100) : nil } ?? 0
        let capacityAbove = percent >= settings.capacityThresholdPercent
        let growthMiB = observation.growthReport.volumeUsedDelta / (1_024 * 1_024)
        let growthAbove = growthMiB >= Int64(settings.growthThresholdMiB)
        var notifications: [MonitoringNotification] = []

        if capacityAbove && !capacityWasAbove {
            notifications.append(.init(
                title: "Disk usage reached \(percent)%",
                body: "Disk Steward recorded the threshold crossing. Export evidence before deciding what to clean."
            ))
        }
        if growthAbove && !growthWasAbove {
            notifications.append(.init(
                title: "Material disk growth detected",
                body: "Usage increased by \(ByteCountFormatter.string(fromByteCount: observation.growthReport.volumeUsedDelta, countStyle: .file)); attribution confidence is included in the evidence."
            ))
        }
        capacityWasAbove = capacityAbove
        growthWasAbove = growthAbove
        return notifications
    }
}
