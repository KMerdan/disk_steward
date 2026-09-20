import Foundation

public struct VolumeGrowthSample: Equatable, Sendable {
    public let observedAt: String
    public let usedByteDeltas: [String: Int64]
    public let limitations: [String]
    /// A mount path can be reused by a different disk. Unknown UUIDs must not
    /// create a dashboard growth baseline. No persistent schema change needed.
    public var selectedVolumeIdentity: String? = nil
}

public func selectedCapacityVolume(in snapshot: StorageSnapshot) -> VolumeCapacity? {
    snapshot.volumes.first { $0.isInternal && !$0.isReadOnly } ?? snapshot.volumes.first
}

public struct WholeVolumeSampler: Sendable {
    private let service: VolumeSnapshotService

    public init(service: VolumeSnapshotService = VolumeSnapshotService()) {
        self.service = service
    }

    public func sample(after previous: StorageSnapshot?) throws -> (StorageSnapshot, VolumeGrowthSample) {
        let current = try service.capture()
        let oldByPath = Dictionary(uniqueKeysWithValues: (previous?.volumes ?? []).map { ($0.mountPath, $0) })
        let deltas = Dictionary(uniqueKeysWithValues: current.volumes.map { volume in
            (volume.mountPath, volume.usedBytes - (oldByPath[volume.mountPath]?.usedBytes ?? volume.usedBytes))
        })
        var growth = VolumeGrowthSample(observedAt: current.observedAt, usedByteDeltas: deltas, limitations: current.limitations)
        if let volume = selectedCapacityVolume(in: current) {
            growth.selectedVolumeIdentity = try? URL(fileURLWithPath: volume.mountPath)
                .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        }
        return (current, growth)
    }
}
