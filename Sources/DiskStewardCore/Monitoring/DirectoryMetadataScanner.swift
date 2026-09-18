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
    /// Time this metadata was sampled, not file creation time or publication time.
    public let observedAt: Date?
    /// Producing immediate-directory pass; absent in legacy/non-generation scans.
    public let directoryPassID: String?

    public init(
        objectID: String? = nil,
        identityMethod: FileIdentityMethod = .pathTemporal,
        rootPath: String? = nil,
        path: String,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        modifiedAt: Date?,
        linkCount: Int = 1,
        observedAt: Date? = nil,
        directoryPassID: String? = nil
    ) {
        self.objectID = objectID ?? "path:\(Self.stablePathIdentifier(path))"
        self.identityMethod = identityMethod
        self.rootPath = rootPath ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
        self.path = path
        self.logicalBytes = max(0, logicalBytes)
        self.allocatedBytes = max(0, allocatedBytes)
        self.modifiedAt = modifiedAt
        self.linkCount = max(1, linkCount)
        self.observedAt = observedAt
        self.directoryPassID = directoryPassID
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
    /// Signature of the directory when `afterName` was produced. A mismatch
    /// resets the lexical cursor so names inserted before it are not skipped.
    public let directorySignature: String?
    public let startedAt: Date?
    public let passID: String?
    /// Names the pass's in-process stream had served when this cursor was
    /// produced. A stream that has served more was read by a slice the store
    /// never committed; resuming from it would skip those names silently.
    public let consumedNames: Int?

    public init(
        directoryPath: String,
        depth: Int,
        afterName: String? = nil,
        directorySignature: String? = nil,
        startedAt: Date? = nil,
        passID: String? = nil,
        consumedNames: Int? = nil
    ) {
        self.directoryPath = directoryPath
        self.depth = max(0, depth)
        self.afterName = afterName
        self.directorySignature = directorySignature
        self.startedAt = startedAt
        self.passID = passID
        self.consumedNames = consumedNames.map { max(0, $0) }
    }
}

public struct MetadataScanRootProgress: Codable, Equatable, Sendable {
    public let rootPath: String
    public let status: MetadataScanRootStatus
    /// The bounded in-memory working window of directories. Directories
    /// discovered beyond the window live in the store's durable frontier rows
    /// and are moved into the window after each slice commits.
    public let frontier: [MetadataScanDirectoryCursor]
    public let processedEntryCount: Int
    public let observedFileCount: Int
    public let limitations: [String]
    /// Durable pending directories outside the window; nil for legacy
    /// progress that never spilled, which the store treats as zero.
    public let pendingDirectoryCount: Int?

    public init(
        rootPath: String,
        status: MetadataScanRootStatus = .pending,
        frontier: [MetadataScanDirectoryCursor]? = nil,
        processedEntryCount: Int = 0,
        observedFileCount: Int = 0,
        limitations: [String] = [],
        pendingDirectoryCount: Int? = nil
    ) {
        self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.status = status
        self.frontier = frontier ?? [.init(directoryPath: self.rootPath, depth: 0)]
        self.processedEntryCount = max(0, processedEntryCount)
        self.observedFileCount = max(0, observedFileCount)
        self.limitations = Array(Set(limitations)).sorted()
        self.pendingDirectoryCount = pendingDirectoryCount.map { max(0, $0) }
    }
}

/// A directory discovered by a slice that did not fit the root's window. The
/// store appends it to the durable frontier in the same slice transaction.
public struct MetadataScanDiscoveredDirectory: Codable, Equatable, Sendable {
    public let rootPath: String
    public let directoryPath: String
    public let depth: Int

    public init(rootPath: String, directoryPath: String, depth: Int) {
        self.rootPath = rootPath
        self.directoryPath = directoryPath
        self.depth = max(0, depth)
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
    /// Optional so generations persisted by older releases remain decodable.
    public let schedulerCursor: Int?
    /// Missing on legacy staging, which cannot establish directory-pass membership.
    public let passProvenanceVersion: Int?
    /// Receipt-order fence for dirty evidence. A late slice from an older
    /// revision must not overwrite a root reset, even if wall time repeats.
    public let reconciliationToken: String?

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
        limitations: [String] = [],
        schedulerCursor: Int? = 0,
        passProvenanceVersion: Int? = 2,
        reconciliationToken: String? = UUID().uuidString.lowercased()
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
        self.schedulerCursor = schedulerCursor.map { max(0, $0) }
        self.passProvenanceVersion = passProvenanceVersion
        self.reconciliationToken = reconciliationToken
    }

    public var completedRootCount: Int {
        roots.filter { $0.status == .completed }.count
    }
}

public struct MetadataScanDiagnostics: Equatable, Sendable {
    public let directoryEnumerationPasses: Int
    public let directoryEntriesInspected: Int
    public let peakRetainedDirectoryNames: Int
    public let directoryChangeRestarts: Int

    public init(
        directoryEnumerationPasses: Int = 0,
        directoryEntriesInspected: Int = 0,
        peakRetainedDirectoryNames: Int = 0,
        directoryChangeRestarts: Int = 0
    ) {
        self.directoryEnumerationPasses = max(0, directoryEnumerationPasses)
        self.directoryEntriesInspected = max(0, directoryEntriesInspected)
        self.peakRetainedDirectoryNames = max(0, peakRetainedDirectoryNames)
        self.directoryChangeRestarts = max(0, directoryChangeRestarts)
    }
}

/// One completed immediate-directory membership pass. The store retains these
/// independently of the frontier and revalidates them before publication.
public struct MetadataScanDirectoryPass: Codable, Equatable, Sendable {
    public let passID: String
    public let rootPath: String
    public let directoryPath: String
    public let depth: Int
    public let signature: String
    public let startedAt: Date
    public let completedAt: Date
}

public struct MetadataScanDirectoryInvalidation: Equatable, Sendable {
    public let rootPath: String
    public let directoryPath: String
}

public struct MetadataScanSlice: Equatable, Sendable {
    public let generation: MetadataScanGeneration
    public let entries: [FileMetadata]
    public let diagnostics: MetadataScanDiagnostics
    public let invalidatedDirectoryPasses: [MetadataScanDirectoryInvalidation]
    public var invalidatedDirectories: [String] { invalidatedDirectoryPasses.map(\.directoryPath) }
    public let directoryPasses: [MetadataScanDirectoryPass]
    public let discoveredDirectories: [MetadataScanDiscoveredDirectory]

    public init(
        generation: MetadataScanGeneration,
        entries: [FileMetadata],
        diagnostics: MetadataScanDiagnostics = .init(),
        invalidatedDirectoryPasses: [MetadataScanDirectoryInvalidation] = [],
        directoryPasses: [MetadataScanDirectoryPass] = [],
        discoveredDirectories: [MetadataScanDiscoveredDirectory] = []
    ) {
        self.generation = generation
        self.entries = entries.sorted { $0.path < $1.path }
        self.diagnostics = diagnostics
        self.invalidatedDirectoryPasses = invalidatedDirectoryPasses
        self.directoryPasses = directoryPasses
        self.discoveredDirectories = discoveredDirectories
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

    /// Directories a root keeps in memory and in its persisted progress. The
    /// remainder of the frontier lives in indexed durable rows.
    public static let frontierWindowSize = 64

    private let streams: DirectoryStreamRegistry

    /// Streams default to the process-wide registry so any scanner instance
    /// in this process can continue a pass another instance began. A fresh
    /// registry models a new process: unfinished passes restart.
    public init(streams: DirectoryStreamRegistry = .shared) {
        self.streams = streams
    }

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
        var diagnostics = MetadataScanDiagnostics()
        var invalidatedDirectories: [MetadataScanDirectoryInvalidation] = []
        var directoryPasses: [MetadataScanDirectoryPass] = []
        var discovered: [MetadataScanDiscoveredDirectory] = []
        var nextSchedulerCursor = generation.schedulerCursor ?? 0

        let activeRootIndices = roots.indices.filter {
            roots[$0].status == .pending || roots[$0].status == .active
        }
        let scheduledRootIndices: [Int]
        if activeRootIndices.isEmpty {
            scheduledRootIndices = []
        } else {
            let start = nextSchedulerCursor % activeRootIndices.count
            scheduledRootIndices = Array(activeRootIndices[start...]) + Array(activeRootIndices[..<start])
        }

        for (scheduledOffset, rootIndex) in scheduledRootIndices.enumerated() where remaining > 0 {
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

            let rootsStillToVisit = max(1, scheduledRootIndices.count - scheduledOffset)
            var rootBudget = max(1, (remaining + rootsStillToVisit - 1) / rootsStillToVisit)
            while remaining > 0, rootBudget > 0, root.status == .active {
                guard var cursor = root.frontier.first else {
                    if (root.pendingDirectoryCount ?? 0) > 0 {
                        // Durable frontier rows remain; the store moves them into
                        // the window when this slice commits.
                        break
                    }
                    root = Self.copy(root, status: .completed, frontier: [])
                    break
                }

                guard let signatureBefore = Self.directorySignature(atPath: cursor.directoryPath) else {
                    let limitation = "Directory identity unavailable at \(cursor.directoryPath); absence cannot be established."
                    root = Self.copy(root, status: .failed, limitations: root.limitations + [limitation])
                    generationLimitations.append(limitation)
                    break
                }
                // An unfinished pass restarts when its directory changed since it
                // began, when its in-process stream no longer exists (new
                // process, evicted stream), or when it is a legacy lexical
                // cursor: no native position is ever persisted or trusted.
                let streamLost = cursor.passID.map { !streams.contains(passID: $0) } ?? false
                // A stream ahead of its committed cursor served names to a slice
                // the store refused or failed; it is the in-process form of a
                // lost stream and restarts the pass the same way.
                let streamDesynced: Bool = {
                    guard let passID = cursor.passID, let expected = cursor.consumedNames,
                          let consumed = streams.consumed(passID: passID) else { return false }
                    return consumed != expected
                }()
                let signatureChanged = cursor.directorySignature != nil && cursor.directorySignature != signatureBefore
                let legacyCursor = cursor.passID == nil && cursor.afterName != nil
                if streamLost || streamDesynced || signatureChanged || legacyCursor {
                    if let passID = cursor.passID { streams.close(passID: passID) }
                    cursor = .init(
                        directoryPath: cursor.directoryPath,
                        depth: cursor.depth,
                        directorySignature: signatureBefore,
                        startedAt: date
                    )
                    let prefix = cursor.directoryPath == "/" ? "/" : cursor.directoryPath + "/"
                    invalidatedDirectories.append(.init(rootPath: root.rootPath, directoryPath: cursor.directoryPath))
                    entries.removeAll { $0.rootPath == root.rootPath && $0.path.hasPrefix(prefix) }
                    directoryPasses.removeAll { $0.rootPath == root.rootPath && ($0.directoryPath == cursor.directoryPath || $0.directoryPath.hasPrefix(prefix)) }
                    discovered.removeAll { $0.rootPath == root.rootPath && $0.directoryPath.hasPrefix(prefix) }
                    var frontier = root.frontier.filter { $0.directoryPath == cursor.directoryPath || !$0.directoryPath.hasPrefix(prefix) }
                    frontier[0] = cursor
                    root = Self.copy(root, frontier: frontier)
                    diagnostics = diagnostics.addingDirectoryChangeRestart()
                }

                let passID = cursor.passID ?? UUID().uuidString.lowercased()
                if cursor.passID == nil {
                    cursor = .init(directoryPath: cursor.directoryPath, depth: cursor.depth,
                                   directorySignature: signatureBefore, startedAt: date,
                                   passID: passID)
                    var frontier = root.frontier
                    frontier[0] = cursor
                    root = Self.copy(root, frontier: frontier)
                }

                let batch: DirectoryStreamBatch
                do {
                    batch = try streams.read(passID: passID, directoryPath: cursor.directoryPath, limit: min(remaining, rootBudget))
                    diagnostics = diagnostics.adding(batch)
                } catch {
                    streams.close(passID: passID)
                    let limitation = "Scan cursor became invalid at \(cursor.directoryPath): \(error.localizedDescription)"
                    root = Self.copy(root, status: .failed, limitations: root.limitations + [limitation])
                    generationLimitations.append(limitation)
                    break
                }

                let signatureAfter = Self.directorySignature(atPath: cursor.directoryPath)
                guard signatureBefore == signatureAfter else {
                    streams.close(passID: passID)
                    let prefix = cursor.directoryPath == "/" ? "/" : cursor.directoryPath + "/"
                    invalidatedDirectories.append(.init(rootPath: root.rootPath, directoryPath: cursor.directoryPath))
                    entries.removeAll { $0.rootPath == root.rootPath && $0.path.hasPrefix(prefix) }
                    directoryPasses.removeAll { $0.rootPath == root.rootPath && ($0.directoryPath == cursor.directoryPath || $0.directoryPath.hasPrefix(prefix)) }
                    discovered.removeAll { $0.rootPath == root.rootPath && $0.directoryPath.hasPrefix(prefix) }
                    var frontier = root.frontier.filter { $0.directoryPath == cursor.directoryPath || !$0.directoryPath.hasPrefix(prefix) }
                    frontier[0] = .init(
                        directoryPath: cursor.directoryPath,
                        depth: cursor.depth,
                        directorySignature: signatureAfter,
                        startedAt: date
                    )
                    root = Self.copy(root, frontier: frontier)
                    diagnostics = diagnostics.addingDirectoryChangeRestart()
                    // Remain partial and yield instead of spinning on a hot directory.
                    remaining = 0
                    break
                }

                guard !batch.names.isEmpty else {
                    streams.close(passID: passID)
                    directoryPasses.append(.init(passID: passID, rootPath: root.rootPath, directoryPath: cursor.directoryPath,
                                                 depth: cursor.depth, signature: signatureBefore,
                                                 startedAt: cursor.startedAt ?? date, completedAt: date))
                    root = Self.copy(root, frontier: Array(root.frontier.dropFirst()))
                    // Empty directories are work too: bound pass metadata per slice.
                    remaining -= 1
                    rootBudget -= 1
                    continue
                }

                cursor = .init(
                    directoryPath: cursor.directoryPath,
                    depth: cursor.depth,
                    directorySignature: signatureAfter,
                    startedAt: cursor.startedAt ?? date,
                    passID: cursor.passID,
                    consumedNames: streams.consumed(passID: passID)
                )
                var frontier = root.frontier
                frontier[0] = cursor
                root = Self.copy(
                    root,
                    frontier: frontier,
                    processedEntryCount: root.processedEntryCount + batch.names.count
                )
                remaining -= batch.names.count
                rootBudget -= batch.names.count

                for childName in batch.names {
                    let child = URL(fileURLWithPath: cursor.directoryPath, isDirectory: true)
                        .appendingPathComponent(childName)
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
                            } else if root.frontier.count < Self.frontierWindowSize {
                                root = Self.copy(
                                    root,
                                    frontier: root.frontier + [.init(directoryPath: child.standardizedFileURL.path, depth: childDepth)]
                                )
                            } else {
                                // Beyond the window the frontier is durable rows,
                                // never a growing in-memory array.
                                discovered.append(.init(rootPath: root.rootPath, directoryPath: child.standardizedFileURL.path, depth: childDepth))
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
                            linkCount: identity.linkCount,
                            observedAt: date,
                            directoryPassID: cursor.passID
                        ))
                        root = Self.copy(root, observedFileCount: root.observedFileCount + 1)
                    } catch {
                        let limitation = "Metadata unavailable for \(child.path): \(error.localizedDescription)"
                        root = Self.copy(root, status: .failed, limitations: root.limitations + [limitation])
                        generationLimitations.append(limitation)
                    }
                }

                // Membership may change while the batch's child metadata is read.
                // No part of that superseded pass may survive in staging.
                if Self.directorySignature(atPath: cursor.directoryPath) != signatureBefore {
                    streams.close(passID: passID)
                    let prefix = cursor.directoryPath == "/" ? "/" : cursor.directoryPath + "/"
                    invalidatedDirectories.append(.init(rootPath: root.rootPath, directoryPath: cursor.directoryPath))
                    entries.removeAll { $0.rootPath == root.rootPath && $0.path.hasPrefix(prefix) }
                    directoryPasses.removeAll { $0.rootPath == root.rootPath && ($0.directoryPath == cursor.directoryPath || $0.directoryPath.hasPrefix(prefix)) }
                    discovered.removeAll { $0.rootPath == root.rootPath && $0.directoryPath.hasPrefix(prefix) }
                    var restarted = root.frontier.filter { $0.directoryPath == cursor.directoryPath || !$0.directoryPath.hasPrefix(prefix) }
                    restarted[0] = .init(directoryPath: cursor.directoryPath, depth: cursor.depth)
                    root = Self.copy(root, frontier: restarted)
                    diagnostics = diagnostics.addingDirectoryChangeRestart()
                    remaining = 0
                    break
                }
                if batch.exhausted, root.status != .failed {
                    streams.close(passID: passID)
                    directoryPasses.append(.init(passID: passID, rootPath: root.rootPath, directoryPath: cursor.directoryPath,
                                                 depth: cursor.depth, signature: signatureBefore,
                                                 startedAt: cursor.startedAt ?? date, completedAt: date))
                    root = Self.copy(root, frontier: Array(root.frontier.dropFirst()))
                }
            }
            roots[rootIndex] = root
            if !activeRootIndices.isEmpty,
               let position = activeRootIndices.firstIndex(of: rootIndex)
            {
                nextSchedulerCursor = (position + 1) % activeRootIndices.count
            }
        }

        let status: MetadataScanGenerationStatus
        let completedAt: Date?
        // A finished attempt with failed roots must publish failed coverage,
        // including when every root failed. Abandonment is reserved for an
        // invalidated generation/scope, not a substitute for uncertainty.
        if roots.allSatisfy({ $0.status == .completed || $0.status == .failed }) {
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
            limitations: generationLimitations,
            schedulerCursor: nextSchedulerCursor,
            passProvenanceVersion: generation.passProvenanceVersion,
            reconciliationToken: generation.reconciliationToken
        )
        return MetadataScanSlice(generation: updated, entries: entries, diagnostics: diagnostics,
                                 invalidatedDirectoryPasses: invalidatedDirectories, directoryPasses: directoryPasses,
                                 discoveredDirectories: discovered)
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

    static func directorySignature(atPath path: String) -> String? {
        var information = stat()
        guard lstat(path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR else { return nil }
        return [
            String(information.st_dev),
            String(information.st_ino),
            String(information.st_mtimespec.tv_sec),
            String(information.st_mtimespec.tv_nsec),
            String(information.st_ctimespec.tv_sec),
            String(information.st_ctimespec.tv_nsec),
        ].joined(separator: ":")
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
            limitations: limitations ?? root.limitations,
            pendingDirectoryCount: root.pendingDirectoryCount
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
            limitations: limitations,
            schedulerCursor: generation.schedulerCursor,
            passProvenanceVersion: generation.passProvenanceVersion,
            reconciliationToken: generation.reconciliationToken
        )
    }
}

private struct POSIXDirectoryError: LocalizedError {
    let path: String
    let code: Int32

    var errorDescription: String? {
        "Unable to enumerate \(path): \(String(cString: strerror(code)))"
    }
}

/// One bounded read from an open directory stream: at most `limit` names in
/// native order. `exhausted` is known only when the stream reports its end.
public struct DirectoryStreamBatch: Equatable, Sendable {
    public let names: [String]
    public let exhausted: Bool
    public let opened: Bool
}

/// Open directory streams keyed by scan pass. A stream never outlives the
/// process and no native position is persisted: losing a stream restarts its
/// unfinished pass under a new identifier. Only the head directory of each
/// active root streams at a time, and the registry evicts the least recently
/// used stream beyond `maximumOpenStreams` so descriptors stay bounded.
///
/// A directory that fits one retained read (`sortedNameLimit` names) is served
/// in lexical order from that single read; a larger directory streams in
/// native order and never retains more than one batch of names.
public final class DirectoryStreamRegistry: @unchecked Sendable {
    public static let shared = DirectoryStreamRegistry()
    public static let maximumOpenStreams = 64
    public static let sortedNameLimit = 512

    private struct Entry {
        let handle: UnsafeMutablePointer<DIR>
        let directoryPath: String
        var buffer: [String]
        var bufferOffset: Int
        var streamExhausted: Bool
        var lastUsed: UInt64
        /// Names served so far; the scanner persists it in the cursor.
        var consumed: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var tick: UInt64 = 0

    public init() {}

    deinit { closeAll() }

    public var openStreamCount: Int { lock.withLock { entries.count } }

    func contains(passID: String) -> Bool { lock.withLock { entries[passID] != nil } }

    /// Names the pass's stream has served, or nil when no stream is open.
    func consumed(passID: String) -> Int? { lock.withLock { entries[passID]?.consumed } }

    func read(passID: String, directoryPath: String, limit: Int) throws -> DirectoryStreamBatch {
        try lock.withLock {
            tick &+= 1
            var opened = false
            if entries[passID] == nil {
                if entries.count >= Self.maximumOpenStreams,
                   let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                    closedir(entries[oldest]!.handle)
                    entries.removeValue(forKey: oldest)
                }
                guard let handle = opendir(directoryPath) else {
                    throw POSIXDirectoryError(path: directoryPath, code: errno)
                }
                var entry = Entry(handle: handle, directoryPath: directoryPath, buffer: [], bufferOffset: 0, streamExhausted: false, lastUsed: tick, consumed: 0)
                // One bounded look-ahead read decides the mode: a directory that
                // ends within the limit is sorted once; anything larger streams.
                do {
                    entry.buffer = try Self.readNames(from: handle, path: directoryPath, limit: Self.sortedNameLimit + 1, exhausted: &entry.streamExhausted)
                } catch {
                    closedir(handle)
                    throw error
                }
                if entry.streamExhausted { entry.buffer.sort() }
                entries[passID] = entry
                opened = true
            }
            guard var entry = entries[passID], entry.directoryPath == directoryPath else {
                throw POSIXDirectoryError(path: directoryPath, code: EINVAL)
            }
            entry.lastUsed = tick
            let wanted = max(1, limit)
            var names: [String] = []
            let available = entry.buffer.count - entry.bufferOffset
            if available > 0 {
                let take = min(wanted, available)
                names = Array(entry.buffer[entry.bufferOffset ..< entry.bufferOffset + take])
                entry.bufferOffset += take
                if entry.bufferOffset == entry.buffer.count { entry.buffer = []; entry.bufferOffset = 0 }
            }
            if names.count < wanted, !entry.streamExhausted {
                do {
                    let more = try Self.readNames(from: entry.handle, path: directoryPath, limit: wanted - names.count, exhausted: &entry.streamExhausted)
                    names += more
                } catch {
                    closedir(entry.handle)
                    entries.removeValue(forKey: passID)
                    throw error
                }
            }
            let exhausted = entry.streamExhausted && entry.buffer.isEmpty
            entry.consumed += names.count
            entries[passID] = entry
            return DirectoryStreamBatch(names: names, exhausted: exhausted, opened: opened)
        }
    }

    private static func readNames(from handle: UnsafeMutablePointer<DIR>, path: String, limit: Int, exhausted: inout Bool) throws -> [String] {
        var names: [String] = []
        errno = 0
        while names.count < limit {
            guard let record = readdir(handle) else {
                if errno != 0 { throw POSIXDirectoryError(path: path, code: errno) }
                exhausted = true
                break
            }
            let name = withUnsafePointer(to: &record.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    func close(passID: String) {
        lock.withLock {
            guard let entry = entries.removeValue(forKey: passID) else { return }
            closedir(entry.handle)
        }
    }

    public func closeAll() {
        lock.withLock {
            for entry in entries.values { closedir(entry.handle) }
            entries.removeAll()
        }
    }
}

private extension MetadataScanDiagnostics {
    func adding(_ batch: DirectoryStreamBatch) -> MetadataScanDiagnostics {
        .init(
            directoryEnumerationPasses: directoryEnumerationPasses + (batch.opened ? 1 : 0),
            directoryEntriesInspected: directoryEntriesInspected + batch.names.count,
            peakRetainedDirectoryNames: max(peakRetainedDirectoryNames, batch.names.count),
            directoryChangeRestarts: directoryChangeRestarts
        )
    }

    func addingDirectoryChangeRestart() -> MetadataScanDiagnostics {
        .init(
            directoryEnumerationPasses: directoryEnumerationPasses,
            directoryEntriesInspected: directoryEntriesInspected,
            peakRetainedDirectoryNames: peakRetainedDirectoryNames,
            directoryChangeRestarts: directoryChangeRestarts + 1
        )
    }
}
