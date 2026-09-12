import Foundation

public enum VolumeSnapshotError: Error, Equatable, LocalizedError {
    case noAccessibleVolumes

    public var errorDescription: String? {
        switch self {
        case .noAccessibleVolumes:
            return "No accessible local volume exposed complete capacity metadata."
        }
    }
}

public struct VolumeSnapshotService: Sendable {
    public typealias VolumeSource = @Sendable () -> [URL]
    public typealias IdentifierSource = @Sendable () -> String
    public typealias DateSource = @Sendable () -> Date

    private static let resourceKeys: Set<URLResourceKey> = [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
        .volumeIsInternalKey,
        .volumeIsReadOnlyKey,
        .volumeIsLocalKey,
        .volumeURLForRemountingKey,
    ]

    private let volumeSource: VolumeSource
    private let identifierSource: IdentifierSource
    private let dateSource: DateSource

    public init(
        volumeSource: @escaping VolumeSource = VolumeSnapshotService.accessibleLocalVolumes,
        identifierSource: @escaping IdentifierSource = { UUID().uuidString.lowercased() },
        dateSource: @escaping DateSource = Date.init
    ) {
        self.volumeSource = volumeSource
        self.identifierSource = identifierSource
        self.dateSource = dateSource
    }

    public func capture() throws -> StorageSnapshot {
        var capacities: [VolumeCapacity] = []
        var limitations: [String] = []
        var seenMountPaths: Set<String> = []

        for volumeURL in volumeSource() {
            do {
                let values = try volumeURL.resourceValues(forKeys: Self.resourceKeys)
                guard values.volumeIsLocal != false else { continue }
                let path = (values.volumeURLForRemounting ?? volumeURL).standardizedFileURL.path
                guard seenMountPaths.insert(path).inserted else { continue }
                guard let total = values.volumeTotalCapacity.map(Int64.init) else {
                    limitations.append("Capacity unavailable for \(path).")
                    continue
                }
                let available = values.volumeAvailableCapacityForImportantUsage
                    ?? values.volumeAvailableCapacity.map(Int64.init)
                guard let available else {
                    limitations.append("Available capacity unavailable for \(path).")
                    continue
                }

                capacities.append(
                    VolumeCapacity(
                        mountPath: path,
                        totalBytes: total,
                        availableBytes: available,
                        isInternal: values.volumeIsInternal ?? false,
                        isReadOnly: values.volumeIsReadOnly ?? false
                    )
                )
            } catch {
                limitations.append(
                    "Volume metadata unavailable for \(volumeURL.standardizedFileURL.path): \(error.localizedDescription)"
                )
            }
        }

        guard !capacities.isEmpty else { throw VolumeSnapshotError.noAccessibleVolumes }

        return StorageSnapshot(
            snapshotID: identifierSource(),
            observedAt: Self.timestamp(dateSource()),
            volumes: capacities,
            limitations: limitations
        )
    }

    public static func currentDataVolume() -> [URL] {
        [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)]
    }

    public static func accessibleLocalVolumes() -> [URL] {
        let manager = FileManager.default
        let mounted = manager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(resourceKeys),
            options: [.skipHiddenVolumes]
        ) ?? []
        return mounted.isEmpty ? currentDataVolume() : mounted
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
