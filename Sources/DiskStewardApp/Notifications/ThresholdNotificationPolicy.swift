import DiskStewardCore
import Foundation

struct MonitoringNotification: Equatable, Sendable {
    let title: String
    let body: String
    var growthComparison: VolumeComparison? = nil
}

struct ThresholdNotificationPolicy: Sendable {
    /// Consecutive comparable samples below the reserve.
    private var belowReserveSamples = 0
    /// A reserve alert may fire; re-armed only above reserve plus hysteresis.
    private var reserveArmed = true
    private var growthWasAbove = false
    private var selectedVolumeIdentity: String?

    mutating func evaluate(observation: MonitoringObservation, settings: MonitoringSettings) -> [MonitoringNotification] {
        let volume = observation.capacity?.volume
        if selectedVolumeIdentity != observation.capacity?.identity {
            belowReserveSamples = 0
            reserveArmed = true
            growthWasAbove = false
            selectedVolumeIdentity = observation.capacity?.identity
        }
        let comparison = observation.capacity?.comparison
        let growthAbove = comparison.map { $0.usedByteDelta >= Int64(settings.growthThresholdMiB) * 1_024 * 1_024 } ?? false
        var notifications: [MonitoringNotification] = []

        if let volume, volume.totalBytes > 0 {
            let reserve = settings.reserveBytes(totalBytes: volume.totalBytes)
            let hysteresis = max(MonitoringSettings.gibibyte, reserve / 20)
            if volume.availableBytes < reserve {
                // Two comparable samples in a row: the same volume, measured
                // again later. A first or non-comparable sample counts once.
                belowReserveSamples = comparison != nil ? belowReserveSamples + 1 : 1
            } else {
                belowReserveSamples = 0
                if volume.availableBytes >= reserve + hysteresis { reserveArmed = true }
            }
            if reserveArmed, belowReserveSamples >= 2 {
                reserveArmed = false
                notifications.append(.init(
                    title: "Free space is below your \(Self.bytes(reserve)) reserve",
                    body: "\(ObservedVolume.name(for: volume.mountPath)): \(Self.bytes(volume.availableBytes)) free, \(Self.bytes(reserve - volume.availableBytes)) below the reserve on two samples in a row. Review storage before deciding what to clean."
                ))
            }
        }
        if growthAbove && !growthWasAbove, let comparison {
            notifications.append(.init(
                title: "Material disk growth detected",
                body: "\(ObservedVolume.name(for: comparison.mountPath)): \(comparison.amountText). \(comparison.intervalText). File-detail evidence may cover a different interval; review its attribution confidence before cleanup.",
                growthComparison: comparison
            ))
        }
        growthWasAbove = growthAbove
        return notifications
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}
