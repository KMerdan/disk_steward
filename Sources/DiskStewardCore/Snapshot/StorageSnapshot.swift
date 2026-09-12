import Foundation

public struct StorageSnapshot: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable {
        case wholeVolume = "whole-volume"
        case watchedRoot = "watched-root"
        case registeredProcess = "registered-process"
        case investigation
    }

    public let schema: String
    public let snapshotID: String
    public let observedAt: String
    public let scope: Scope
    public let volumes: [VolumeCapacity]
    public let limitations: [String]

    public init(
        snapshotID: String,
        observedAt: String,
        scope: Scope = .wholeVolume,
        volumes: [VolumeCapacity],
        limitations: [String] = []
    ) {
        self.schema = "storage-snapshot-v1"
        self.snapshotID = snapshotID
        self.observedAt = observedAt
        self.scope = scope
        self.volumes = volumes.sorted { $0.mountPath < $1.mountPath }
        self.limitations = limitations.sorted()
    }

    enum CodingKeys: String, CodingKey {
        case schema
        case snapshotID = "snapshot_id"
        case observedAt = "observed_at"
        case scope
        case volumes
        case limitations
    }
}

public struct VolumeCapacity: Codable, Equatable, Sendable {
    public let mountPath: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let usedBytes: Int64
    public let isInternal: Bool
    public let isReadOnly: Bool

    public init(
        mountPath: String,
        totalBytes: Int64,
        availableBytes: Int64,
        isInternal: Bool,
        isReadOnly: Bool
    ) {
        let safeTotal = max(0, totalBytes)
        let safeAvailable = min(safeTotal, max(0, availableBytes))
        self.mountPath = mountPath
        self.totalBytes = safeTotal
        self.availableBytes = safeAvailable
        self.usedBytes = safeTotal - safeAvailable
        self.isInternal = isInternal
        self.isReadOnly = isReadOnly
    }

    enum CodingKeys: String, CodingKey {
        case mountPath = "mount_path"
        case totalBytes = "total_bytes"
        case availableBytes = "available_bytes"
        case usedBytes = "used_bytes"
        case isInternal = "is_internal"
        case isReadOnly = "is_read_only"
    }
}
