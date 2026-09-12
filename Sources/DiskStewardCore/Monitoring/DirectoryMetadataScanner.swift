import Foundation

public struct FileMetadata: Equatable, Sendable {
    public let path: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modifiedAt: Date?

    public init(path: String, logicalBytes: Int64, allocatedBytes: Int64, modifiedAt: Date?) {
        self.path = path
        self.logicalBytes = max(0, logicalBytes)
        self.allocatedBytes = max(0, allocatedBytes)
        self.modifiedAt = modifiedAt
    }
}

public struct MetadataSnapshot: Equatable, Sendable {
    public let observedAt: Date
    public let entries: [String: FileMetadata]
    public let limitations: [String]

    public init(observedAt: Date, entries: [String: FileMetadata], limitations: [String]) {
        self.observedAt = observedAt
        self.entries = entries
        self.limitations = limitations.sorted()
    }
}

public struct DirectoryMetadataScanner: Sendable {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
    ]

    public init() {}

    public func scan(policy: MonitoringPolicy, at date: Date = Date()) -> MetadataSnapshot {
        var entries: [String: FileMetadata] = [:]
        var limitations = policy.scopeLimitations(at: date)
        let manager = FileManager.default

        for root in policy.activeRoots(at: date) {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                limitations.append("Watched root unavailable: \(root.path).")
                continue
            }
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(Self.keys),
                options: [],
                errorHandler: { url, error in
                    limitations.append("Metadata unavailable for \(url.path): \(error.localizedDescription)")
                    return true
                }
            ) else {
                limitations.append("Unable to enumerate watched root: \(root.path).")
                continue
            }

            let rootDepth = root.pathComponents.count
            for case let url as URL in enumerator {
                if entries.count >= policy.maximumEntries {
                    limitations.append("Detailed scan stopped at the configured \(policy.maximumEntries)-entry limit.")
                    enumerator.skipDescendants()
                    break
                }
                if url.pathComponents.count - rootDepth > policy.maximumDepth {
                    enumerator.skipDescendants()
                    continue
                }
                if policy.exclusionReason(for: url.path) != nil {
                    enumerator.skipDescendants()
                    continue
                }
                do {
                    let values = try url.resourceValues(forKeys: Self.keys)
                    if values.isSymbolicLink == true {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard values.isRegularFile == true else { continue }
                    entries[url.standardizedFileURL.path] = FileMetadata(
                        path: url.standardizedFileURL.path,
                        logicalBytes: Int64(values.fileSize ?? 0),
                        allocatedBytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                        modifiedAt: values.contentModificationDate
                    )
                } catch {
                    limitations.append("Metadata unavailable for \(url.path): \(error.localizedDescription)")
                }
            }
        }
        return MetadataSnapshot(observedAt: date, entries: entries, limitations: Array(Set(limitations)))
    }

    public func changes(from before: MetadataSnapshot, to after: MetadataSnapshot) -> [EvidenceStoreEvent] {
        let paths = Set(before.entries.keys).union(after.entries.keys).sorted()
        return paths.compactMap { path in
            let old = before.entries[path]
            let new = after.entries[path]
            guard old != new else { return nil }
            let operation: EvidenceStoreEvent.Operation
            switch (old, new) {
            case (nil, .some): operation = .create
            case (.some, nil): operation = .delete
            default: operation = .writeSummary
            }
            let logicalDelta = (new?.logicalBytes ?? 0) - (old?.logicalBytes ?? 0)
            let allocatedDelta = (new?.allocatedBytes ?? 0) - (old?.allocatedBytes ?? 0)
            return EvidenceStoreEvent(
                eventID: "scan-\(Self.stableIdentifier(path: path, date: after.observedAt))",
                observedAt: after.observedAt,
                operation: operation,
                path: path,
                logicalDelta: logicalDelta,
                allocatedDelta: allocatedDelta,
                consumerCategory: Self.category(for: path),
                confidence: .inferred,
                isAnomaly: allocatedDelta > 1_073_741_824
            )
        }
    }

    private static func category(for path: String) -> String {
        let lower = path.lowercased()
        if lower.contains("/documents/codex/") || lower.contains("/.claude/") { return "agent-artifact" }
        if lower.contains("/downloads/") { return "downloads" }
        if lower.contains("/deriveddata/") || lower.contains("/.build/") || lower.contains("/node_modules/") || lower.contains("/caches/") {
            return "developer-cache"
        }
        return "watched-root"
    }

    private static func stableIdentifier(path: String, date: Date) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Data("\(path)|\(date.timeIntervalSince1970)".utf8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
