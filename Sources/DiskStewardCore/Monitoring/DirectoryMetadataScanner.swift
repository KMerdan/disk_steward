import Darwin
import Foundation

public enum FileIdentityMethod: String, Codable, Equatable, Sendable {
    case volumeFileGeneration = "volume-file-generation"
    case volumeFile = "volume-file"
    case pathTemporal = "path-temporal"
}

public enum ObservationCoverage: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case failed
}

public struct RootObservationCoverage: Codable, Equatable, Sendable {
    public let rootPath: String
    public let coverage: ObservationCoverage
    public let limitations: [String]

    public init(rootPath: String, coverage: ObservationCoverage, limitations: [String] = []) {
        self.rootPath = rootPath
        self.coverage = coverage
        self.limitations = limitations.sorted()
    }
}

public struct FileMetadata: Codable, Equatable, Sendable {
    public let objectID: String
    public let identityMethod: FileIdentityMethod
    public let rootPath: String
    public let path: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let modifiedAt: Date?
    public let linkCount: Int

    public init(
        objectID: String? = nil,
        identityMethod: FileIdentityMethod = .pathTemporal,
        rootPath: String? = nil,
        path: String,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        modifiedAt: Date?,
        linkCount: Int = 1
    ) {
        self.objectID = objectID ?? "path:\(Self.stablePathIdentifier(path))"
        self.identityMethod = identityMethod
        self.rootPath = rootPath ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
        self.path = path
        self.logicalBytes = max(0, logicalBytes)
        self.allocatedBytes = max(0, allocatedBytes)
        self.modifiedAt = modifiedAt
        self.linkCount = max(1, linkCount)
    }

    private static func stablePathIdentifier(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Data(path.utf8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public enum MetadataScanGenerationStatus: String, Codable, Equatable, Sendable {
    case active
    case completed
    case abandoned
}

public enum MetadataScanRootStatus: String, Codable, Equatable, Sendable {
    case pending
    case active
    case completed
    case failed
}

public struct MetadataScanDirectoryCursor: Codable, Equatable, Sendable {
    public let directoryPath: String
    public let depth: Int
    public let afterName: String?

    public init(directoryPath: String, depth: Int, afterName: String? = nil) {
        self.directoryPath = directoryPath
        self.depth = max(0, depth)
        self.afterName = afterName
    }
}

public struct MetadataScanRootProgress: Codable, Equatable, Sendable {
    public let rootPath: String
    public let status: MetadataScanRootStatus
    public let frontier: [MetadataScanDirectoryCursor]
    public let processedEntryCount: Int
    public let observedFileCount: Int
    public let limitations: [String]

    public init(
        rootPath: String,
        status: MetadataScanRootStatus = .pending,
        frontier: [MetadataScanDirectoryCursor]? = nil,
        processedEntryCount: Int = 0,
        observedFileCount: Int = 0,
        limitations: [String] = []
    ) {
        self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.status = status
        self.frontier = frontier ?? [.init(directoryPath: self.rootPath, depth: 0)]
        self.processedEntryCount = max(0, processedEntryCount)
        self.observedFileCount = max(0, observedFileCount)
        self.limitations = Array(Set(limitations)).sorted()
    }
}

public struct MetadataScanGeneration: Codable, Equatable, Sendable {
    public let generationID: String
    public let scopeVersionID: String
    public let rootPaths: [String]
    public let excludedPaths: [String]
    public let status: MetadataScanGenerationStatus
    public let roots: [MetadataScanRootProgress]
    public let processedEntryCount: Int
    public let stagedFileCount: Int
    public let startedAt: Date
    public let updatedAt: Date
    public let completedAt: Date?
    public let limitations: [String]

    public init(
        generationID: String,
        scopeVersionID: String,
        rootPaths: [String],
        excludedPaths: [String],
        status: MetadataScanGenerationStatus,
        roots: [MetadataScanRootProgress],
        processedEntryCount: Int,
        stagedFileCount: Int,
        startedAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        limitations: [String] = []
    ) {
        self.generationID = generationID
        self.scopeVersionID = scopeVersionID
        self.rootPaths = rootPaths.sorted()
        self.excludedPaths = excludedPaths.sorted()
        self.status = status
        self.roots = roots.sorted { $0.rootPath < $1.rootPath }
        self.processedEntryCount = max(0, processedEntryCount)
        self.stagedFileCount = max(0, stagedFileCount)
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.limitations = Array(Set(limitations)).sorted()
    }

    public var completedRootCount: Int {
        roots.filter { $0.status == .completed }.count
    }
}

public struct MetadataScanSlice: Equatable, Sendable {
    public let generation: MetadataScanGeneration
    public let entries: [FileMetadata]

    public init(generation: MetadataScanGeneration, entries: [FileMetadata]) {
        self.generation = generation
        self.entries = entries.sorted { $0.path < $1.path }
    }
}

public struct ScanGenerationCommitResult: Equatable, Sendable {
    public let generation: MetadataScanGeneration
    public let observation: ObservationCommitResult?

    public init(generation: MetadataScanGeneration, observation: ObservationCommitResult?) {
        self.generation = generation
        self.observation = observation
    }
}

public struct EvidenceScanCoverageStatus: Codable, Equatable, Sendable {
    public let configuredRoots: [String]
    public let excludedPaths: [String]
    public let detailCoverage: String
    public let activeGeneration: MetadataScanGeneration?
    public let latestGeneration: MetadataScanGeneration?
    public let lastCompleteGenerationAt: Date?

    public init(
        configuredRoots: [String],
        excludedPaths: [String],
        detailCoverage: String,
        activeGeneration: MetadataScanGeneration?,
        latestGeneration: MetadataScanGeneration?,
        lastCompleteGenerationAt: Date?
    ) {
        self.configuredRoots = configuredRoots.sorted()
        self.excludedPaths = excludedPaths.sorted()
        self.detailCoverage = detailCoverage
        self.activeGeneration = activeGeneration
        self.latestGeneration = latestGeneration
        self.lastCompleteGenerationAt = lastCompleteGenerationAt
    }
}

public struct MetadataSnapshot: Equatable, Sendable {
    public let observationID: String
    public let scopeVersionID: String
    public let observedAt: Date
    public let entries: [String: FileMetadata]
    public let rootCoverage: [RootObservationCoverage]
    public let limitations: [String]

    public init(
        observationID: String? = nil,
        scopeVersionID: String = "legacy-scope",
        observedAt: Date,
        entries: [String: FileMetadata],
        rootCoverage: [RootObservationCoverage] = [],
        limitations: [String]
    ) {
        self.observationID = observationID ?? "observation-\(Int64(observedAt.timeIntervalSince1970 * 1_000_000))"
        self.scopeVersionID = scopeVersionID
        self.observedAt = observedAt
        self.entries = entries
        self.rootCoverage = rootCoverage.sorted { $0.rootPath < $1.rootPath }
        self.limitations = limitations.sorted()
    }

    public var coverage: ObservationCoverage {
        if !rootCoverage.isEmpty, rootCoverage.allSatisfy({ $0.coverage == .failed }) { return .failed }
        if rootCoverage.contains(where: { $0.coverage == .failed }) { return .partial }
        if rootCoverage.contains(where: { $0.coverage == .partial }) { return .partial }
        return .complete
    }
}

public struct DirectoryMetadataScanner: Sendable {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
    ]

    public init() {}

    /// Advances one durable generation by at most `maximumEntries` filesystem
    /// entries. The caller persists the returned frontier and staged metadata;
    /// authoritative current state is reconciled only after `.completed`.
    public func scanSlice(
        policy: MonitoringPolicy,
        generation: MetadataScanGeneration,
        at date: Date = Date()
    ) -> MetadataScanSlice {
        let scope = policy.scopeVersion(at: date)
        guard generation.status == .active else {
            return MetadataScanSlice(generation: generation, entries: [])
        }
        guard generation.scopeVersionID == scope.scopeVersionID,
              generation.rootPaths == scope.rootPaths,
              generation.excludedPaths == scope.excludedPaths
        else {
            return MetadataScanSlice(
                generation: Self.copy(
                    generation,
                    status: .abandoned,
                    updatedAt: date,
                    limitations: generation.limitations + ["Scope changed while the scan generation was active; staged absence was discarded."]
                ),
                entries: []
            )
        }

        let manager = FileManager.default
        var roots = generation.roots
        var entries: [FileMetadata] = []
        var remaining = max(1, policy.maximumEntries)
        var generationLimitations = generation.limitations

        for rootIndex in roots.indices where remaining > 0 {
            var root = roots[rootIndex]
            guard root.status == .pending || root.status == .active else { continue }
            if root.status == .pending {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: root.rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                    let limitation = "Watched root became unavailable while generation \(generation.generationID) was active: \(root.rootPath)."
                    root = Self.copy(root, status: .failed, limitations: root.limitations + [limitation])
                    generationLimitations.append(limitation)
                    roots[rootIndex] = root
                    continue
                }
                root = Self.copy(root, status: .active)
            }

            while remaining > 0, root.status == .active {
                guard var cursor = root.frontier.first else {
                    root = Self.copy(root, status: .completed, frontier: [])
                    break
                }
                let children: [URL]
                do {
                    children = try manager.contentsOfDirectory(
                        at: URL(fileURLWithPath: cursor.directoryPath, isDirectory: true),
                        includingPropertiesForKeys: Array(Self.keys),
                        options: []
                    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
                } catch {
                    let limitation = "Scan cursor became invalid at \(cursor.directoryPath): \(error.localizedDescription)"
                    root = Self.copy(root, status: .failed, limitations: root.limitations + [limitation])
                    generationLimitations.append(limitation)
                    break
                }

                guard let child = children.first(where: { candidate in
                    cursor.afterName.map { candidate.lastPathComponent > $0 } ?? true
                }) else {
                    root = Self.copy(root, frontier: Array(root.frontier.dropFirst()))
                    continue
                }

                cursor = .init(directoryPath: cursor.directoryPath, depth: cursor.depth, afterName: child.lastPathComponent)
                var frontier = root.frontier
                frontier[0] = cursor
                root = Self.copy(root, frontier: frontier, processedEntryCount: root.processedEntryCount + 1)
                remaining -= 1

                if policy.exclusionReason(for: child.path) != nil { continue }
                do {
                    let values = try child.resourceValues(forKeys: Self.keys)
                    if values.isSymbolicLink == true { continue }
                    if values.isDirectory == true {
                        let childDepth = cursor.depth + 1
                        if childDepth > policy.maximumDepth {
                            let limitation = "Configured depth limit prevented complete coverage below \(child.path)."
                            root = Self.copy(root, status: .failed, limitations: root.limitations + [limitation])
                            generationLimitations.append(limitation)
                        } else {
                            root = Self.copy(
                                root,
                                frontier: root.frontier + [.init(directoryPath: child.standardizedFileURL.path, depth: childDepth)]
                            )
                        }
                        continue
                    }
                    guard values.isRegularFile == true else { continue }
                    let path = child.standardizedFileURL.path
                    let identity = Self.identity(for: path)
                    entries.append(FileMetadata(
                        objectID: identity.id,
                        identityMethod: identity.method,
                        rootPath: root.rootPath,
                        path: path,
                        logicalBytes: Int64(values.fileSize ?? 0),
                        allocatedBytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                        modifiedAt: values.contentModificationDate,
                        linkCount: identity.linkCount
                    ))
                    root = Self.copy(root, observedFileCount: root.observedFileCount + 1)
                } catch {
                    let limitation = "Metadata unavailable for \(child.path): \(error.localizedDescription)"
                    root = Self.copy(root, status: .failed, limitations: root.limitations + [limitation])
                    generationLimitations.append(limitation)
                }
            }
            roots[rootIndex] = root
        }

        let status: MetadataScanGenerationStatus
        let completedAt: Date?
        if roots.contains(where: { $0.status == .failed }) {
            status = .abandoned
            completedAt = date
        } else if roots.allSatisfy({ $0.status == .completed }) {
            status = .completed
            completedAt = date
        } else {
            status = .active
            completedAt = nil
        }
        let updated = MetadataScanGeneration(
            generationID: generation.generationID,
            scopeVersionID: generation.scopeVersionID,
            rootPaths: generation.rootPaths,
            excludedPaths: generation.excludedPaths,
            status: status,
            roots: roots,
            processedEntryCount: roots.reduce(0) { $0 + $1.processedEntryCount },
            stagedFileCount: generation.stagedFileCount + entries.count,
            startedAt: generation.startedAt,
            updatedAt: date,
            completedAt: completedAt,
            limitations: generationLimitations
        )
        return MetadataScanSlice(generation: updated, entries: entries)
    }

    public func scan(policy: MonitoringPolicy, at date: Date = Date()) -> MetadataSnapshot {
        var entries: [String: FileMetadata] = [:]
        var limitations = policy.scopeLimitations(at: date)
        var rootCoverage: [RootObservationCoverage] = []
        let manager = FileManager.default
        let scope = policy.scopeVersion(at: date)

        for root in policy.activeRoots(at: date) {
            var rootLimitations: [String] = []
            var coverage = ObservationCoverage.complete
            if entries.count >= policy.maximumEntries {
                let limitation = "Watched root was not observed because the global \(policy.maximumEntries)-entry limit was already reached: \(root.path)."
                limitations.append(limitation)
                rootCoverage.append(.init(rootPath: root.path, coverage: .failed, limitations: [limitation]))
                continue
            }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                let limitation = "Watched root unavailable: \(root.path)."
                limitations.append(limitation)
                rootCoverage.append(.init(rootPath: root.path, coverage: .failed, limitations: [limitation]))
                continue
            }
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(Self.keys),
                options: [],
                errorHandler: { url, error in
                    let limitation = "Metadata unavailable for \(url.path): \(error.localizedDescription)"
                    limitations.append(limitation)
                    rootLimitations.append(limitation)
                    coverage = .partial
                    return true
                }
            ) else {
                let limitation = "Unable to enumerate watched root: \(root.path)."
                limitations.append(limitation)
                rootCoverage.append(.init(rootPath: root.path, coverage: .failed, limitations: [limitation]))
                continue
            }

            let rootDepth = root.pathComponents.count
            for case let url as URL in enumerator {
                if entries.count >= policy.maximumEntries {
                    let limitation = "Detailed scan stopped at the configured \(policy.maximumEntries)-entry limit."
                    limitations.append(limitation)
                    rootLimitations.append(limitation)
                    coverage = .partial
                    enumerator.skipDescendants()
                    break
                }
                if url.pathComponents.count - rootDepth > policy.maximumDepth {
                    let limitation = "Detailed scan skipped entries beyond the configured depth for \(root.path)."
                    limitations.append(limitation)
                    rootLimitations.append(limitation)
                    coverage = .partial
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
                    let path = url.standardizedFileURL.path
                    let identity = Self.identity(for: path)
                    entries[path] = FileMetadata(
                        objectID: identity.id,
                        identityMethod: identity.method,
                        rootPath: root.standardizedFileURL.path,
                        path: path,
                        logicalBytes: Int64(values.fileSize ?? 0),
                        allocatedBytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                        modifiedAt: values.contentModificationDate,
                        linkCount: identity.linkCount
                    )
                } catch {
                    let limitation = "Metadata unavailable for \(url.path): \(error.localizedDescription)"
                    limitations.append(limitation)
                    rootLimitations.append(limitation)
                    coverage = .partial
                }
            }
            rootCoverage.append(.init(rootPath: root.path, coverage: coverage, limitations: rootLimitations))
        }
        return MetadataSnapshot(
            observationID: "observation-\(Self.stableIdentifier(path: scope.scopeVersionID, date: date))",
            scopeVersionID: scope.scopeVersionID,
            observedAt: date,
            entries: entries,
            rootCoverage: rootCoverage,
            limitations: Array(Set(limitations))
        )
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
            case let (.some(previous), nil):
                let rootState = after.rootCoverage.first { $0.rootPath == previous.rootPath }?.coverage
                guard before.scopeVersionID == after.scopeVersionID, rootState == .complete else { return nil }
                operation = .delete
            default:
                operation = (new?.logicalBytes ?? 0) < (old?.logicalBytes ?? 0) ? .truncate : .modify
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

    private static func identity(for path: String) -> (id: String, method: FileIdentityMethod, linkCount: Int) {
        var information = stat()
        if lstat(path, &information) == 0 {
            if information.st_gen != 0 {
                return ("file:\(information.st_dev):\(information.st_ino):\(information.st_gen)", .volumeFileGeneration, Int(information.st_nlink))
            }
            return ("file:\(information.st_dev):\(information.st_ino)", .volumeFile, Int(information.st_nlink))
        }
        return ("path:\(stablePathOnlyIdentifier(path))", .pathTemporal, 1)
    }

    private static func stablePathOnlyIdentifier(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Data(path.utf8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func stableIdentifier(path: String, date: Date) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in Data("\(path)|\(date.timeIntervalSince1970)".utf8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func copy(
        _ root: MetadataScanRootProgress,
        status: MetadataScanRootStatus? = nil,
        frontier: [MetadataScanDirectoryCursor]? = nil,
        processedEntryCount: Int? = nil,
        observedFileCount: Int? = nil,
        limitations: [String]? = nil
    ) -> MetadataScanRootProgress {
        .init(
            rootPath: root.rootPath,
            status: status ?? root.status,
            frontier: frontier ?? root.frontier,
            processedEntryCount: processedEntryCount ?? root.processedEntryCount,
            observedFileCount: observedFileCount ?? root.observedFileCount,
            limitations: limitations ?? root.limitations
        )
    }

    private static func copy(
        _ generation: MetadataScanGeneration,
        status: MetadataScanGenerationStatus,
        updatedAt: Date,
        limitations: [String]
    ) -> MetadataScanGeneration {
        .init(
            generationID: generation.generationID,
            scopeVersionID: generation.scopeVersionID,
            rootPaths: generation.rootPaths,
            excludedPaths: generation.excludedPaths,
            status: status,
            roots: generation.roots,
            processedEntryCount: generation.processedEntryCount,
            stagedFileCount: generation.stagedFileCount,
            startedAt: generation.startedAt,
            updatedAt: updatedAt,
            completedAt: updatedAt,
            limitations: limitations
        )
    }
}
