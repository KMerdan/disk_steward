import DiskStewardCore
import Foundation

struct MonitoringNotification: Equatable, Sendable {
    let title: String
    let body: String
    var growthComparison: VolumeComparison? = nil
}

struct ThresholdNotificationPolicy: Sendable {
    private var capacityWasAbove = false
    private var growthWasAbove = false
    private var selectedVolumeIdentity: String?

    mutating func evaluate(observation: MonitoringObservation, settings: MonitoringSettings) -> [MonitoringNotification] {
        let volume = observation.capacity?.volume
        if selectedVolumeIdentity != observation.capacity?.identity {
            capacityWasAbove = false
            growthWasAbove = false
            selectedVolumeIdentity = observation.capacity?.identity
        }
        let percent = volume.flatMap { $0.totalBytes > 0 ? Int((Double($0.usedBytes) / Double($0.totalBytes)) * 100) : nil } ?? 0
        let capacityAbove = percent >= settings.capacityThresholdPercent
        let comparison = observation.capacity?.comparison
        let growthAbove = comparison.map { $0.usedByteDelta >= Int64(settings.growthThresholdMiB) * 1_024 * 1_024 } ?? false
        var notifications: [MonitoringNotification] = []

        if capacityAbove && !capacityWasAbove {
            notifications.append(.init(
                title: "Disk usage reached \(percent)%",
                body: "Disk Steward recorded the threshold crossing. Export evidence before deciding what to clean."
            ))
        }
        if growthAbove && !growthWasAbove, let comparison {
            notifications.append(.init(
                title: "Material disk growth detected",
                body: "\(ObservedVolume.name(for: comparison.mountPath)): \(comparison.amountText). \(comparison.intervalText). File-detail evidence may cover a different interval; review its attribution confidence before cleanup.",
                growthComparison: comparison
            ))
        }
        capacityWasAbove = capacityAbove
        growthWasAbove = growthAbove
        return notifications
    }
}
