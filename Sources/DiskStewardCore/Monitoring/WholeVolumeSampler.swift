import Foundation

public struct VolumeGrowthSample: Equatable, Sendable {
    public let observedAt: String
    public let usedByteDeltas: [String: Int64]
    public let limitations: [String]
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
        return (
            current,
            VolumeGrowthSample(observedAt: current.observedAt, usedByteDeltas: deltas, limitations: current.limitations)
        )
    }
}
