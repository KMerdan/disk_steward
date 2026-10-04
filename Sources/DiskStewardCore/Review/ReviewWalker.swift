import CryptoKit
import Darwin
import Foundation

/// The limits a review may spend. A review that reaches one stops with a
/// partial report; it never runs on.
public struct ReviewBudget: Sendable, Equatable {
    public var wallSeconds: TimeInterval
    public var maximumEntries: Int
    /// Growth of the process's physical footprint since the review started.
    public var maximumMemoryBytes: UInt64

    public init(wallSeconds: TimeInterval = 120, maximumEntries: Int = 5_000_000, maximumMemoryBytes: UInt64 = 256 * 1_024 * 1_024) {
        self.wallSeconds = wallSeconds
        self.maximumEntries = maximumEntries
        self.maximumMemoryBytes = maximumMemoryBytes
    }

    public static let `default` = ReviewBudget()
}

public enum ReviewStopReason: String, Sendable, Codable, Equatable {
    case wallTime = "wall-time"
    case entries
    case memory
    /// More than twice the previous complete review's entries.
    case growth
    /// A directory seen twice: the walk is not converging.
    case revisit
    case cancelled
}

public enum ReviewStatus: Sendable, Equatable {
    case completed
    case stopped(ReviewStopReason)

    public var label: String {
        switch self {
        case .completed: return "completed"
        case let .stopped(reason): return "stopped:" + reason.rawValue
        }
    }
}

/// How an object is recreated if removed. The bounded review assigns the
/// class from what decided the object; later tasks refine it per tool.
public enum RecreateClass: String, Sendable, Codable, Equatable {
    case rebuild
    case redownload = "re-download"
    case liveState = "live-state"
}

public struct ReviewObject: Sendable, Equatable {
    public let path: String
    public let kind: ClassifiedObjectKind
    public let rule: ObjectDetectionRule
    public let reason: String
    public let projectPath: String?
    public let recreateClass: RecreateClass
    /// Allocated bytes inside it, hard links counted once within the object.
    public let allocatedBytes: Int64
    public let fileCount: Int
    /// Newest modification time inside it, seconds since 1970.
    public let lastActivity: TimeInterval
}

public struct ReviewProject: Sendable, Equatable {
    public let path: String
    /// `.git` or the manifest that marks it.
    public let marker: String
    /// Newest modification time of a file in the project outside its objects.
    public let lastSourceActivity: TimeInterval
    /// Tools named by the files in the project folder (`pnpm`, `cargo`, …),
    /// sorted; how its objects would be rebuilt.
    public let tools: [String]

    public init(path: String, marker: String, lastSourceActivity: TimeInterval, tools: [String] = []) {
        self.path = path
        self.marker = marker
        self.lastSourceActivity = lastSourceActivity
        self.tools = tools
    }

    /// Files that name a project's tooling, read from the project folder's own listing.
    public static let toolFiles: [String: String] = [
        "package-lock.json": "npm", "pnpm-lock.yaml": "pnpm", "yarn.lock": "yarn", "bun.lockb": "bun", "bun.lock": "bun",
        "package.json": "node", "uv.lock": "uv", "poetry.lock": "poetry", "Pipfile.lock": "pipenv", "Pipfile": "pipenv",
        "requirements.txt": "pip", "pyproject.toml": "python", "setup.py": "python", "tox.ini": "tox",
        "Cargo.toml": "cargo", "Package.swift": "swiftpm", "go.mod": "go", "Podfile": "cocoapods", "composer.json": "composer",
        "build.gradle": "gradle", "build.gradle.kts": "gradle", "CMakeLists.txt": "cmake", "Makefile": "make", "meson.build": "meson",
        "next.config.js": "next", "next.config.mjs": "next", "next.config.ts": "next", "nuxt.config.ts": "nuxt", "turbo.json": "turbo",
    ]
}

public struct ReviewReport: Sendable {
    public let reportID: String
    public let scope: String
    public let startedAt: Date
    public let completedAt: Date
    public let status: ReviewStatus
    public var isComplete: Bool { status == .completed && unreadableDirectories == 0 }
    public let entriesVisited: Int
    public let directoriesVisited: Int
    /// Allocated bytes under the scope, every hard-linked file counted once.
    public let scopeAllocatedBytes: Int64
    public let objects: [ReviewObject]
    public let projects: [ReviewProject]
    public let unresolved: [UnresolvedCandidate]
    public let unresolvedCount: Int
    public let unreadableDirectories: Int
    public let unreadableEntries: Int
    public let skippedMounts: [String]
    public let excluded: [String]
    /// Top-level folders of the scope whose whole subtree was reviewed.
    public let coveredTopLevel: [String]
    /// Top-level folders not (or not completely) reviewed when the review stopped.
    public let uncoveredTopLevel: [String]
    public let classifierCalls: Int
    public let repositoryQueries: Int
    public let repositoryQuerySeconds: Double
    /// Git processes started to answer those questions.
    public let repositoryProcesses: Int

    public var objectBytes: Int64 { objects.reduce(0) { $0 + $1.allocatedBytes } }

    /// Plain sentences for the report: what was covered and what was not.
    public var limitations: [String] {
        var lines: [String] = []
        if case let .stopped(reason) = status {
            lines.append("The review stopped (\(reason.rawValue)) after \(entriesVisited) entries; it covers \(coveredTopLevel.count) of \(coveredTopLevel.count + uncoveredTopLevel.count) top-level folders completely.")
            if !uncoveredTopLevel.isEmpty {
                lines.append("Not reviewed completely: " + uncoveredTopLevel.prefix(20).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                             + (uncoveredTopLevel.count > 20 ? " and \(uncoveredTopLevel.count - 20) more." : "."))
            }
        }
        if unreadableDirectories > 0 { lines.append("\(unreadableDirectories) folders could not be read; their contents are unknown, not absent.") }
        if unreadableEntries > 0 { lines.append("\(unreadableEntries) entries returned an error and were skipped.") }
        if !skippedMounts.isEmpty { lines.append("\(skippedMounts.count) mounted volumes inside the scope were not entered.") }
        if !excluded.isEmpty { lines.append("\(excluded.count) excluded folders were not reviewed.") }
        if unresolvedCount > 0 { lines.append("\(unresolvedCount) folders carry an output name without project evidence; they were reviewed as ordinary folders, not classified.") }
        lines.append("Sizes are allocated bytes; nothing inside an object is listed or stored.")
        return lines
    }
}

/// What the walker asks before entering a directory: is it an object? Real
/// reviews use the TASK-611 classifier; tests substitute their own.
public protocol ReviewObjectDeciding: Sendable {
    func isCandidateName(_ name: String) -> Bool
    var selfMarkerNames: Set<String> { get }
    var projectMarkerNames: Set<String> { get }
    func classify(directoryPath: String, repositoryPath: String?) -> ObjectClassification
}

/// Counts and times repository questions, so a review can say what git cost.
final class CountingRepositoryOracle: RepositoryOracle, @unchecked Sendable {
    private let wrapped: any RepositoryOracle
    private let lock = NSLock()
    private(set) var queries = 0
    private(set) var seconds: Double = 0

    init(_ wrapped: any RepositoryOracle) { self.wrapped = wrapped }

    /// Git processes the wrapped oracle started, when it counts them.
    var processes: Int { (wrapped as? IndexedRepositoryOracle)?.processes ?? queries }
    func ignores(path: String, repositoryPath: String) -> Bool? { measure { wrapped.ignores(path: path, repositoryPath: repositoryPath) } }
    func tracksContents(ofPath path: String, repositoryPath: String) -> Bool? { measure { wrapped.tracksContents(ofPath: path, repositoryPath: repositoryPath) } }

    var snapshot: (Int, Double) { lock.withLock { (queries, seconds) } }

    private func measure(_ body: () -> Bool?) -> Bool? {
        let start = DispatchTime.now().uptimeNanoseconds
        let answer = body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        lock.withLock { queries += 1; seconds += elapsed }
        return answer
    }
}

/// The TASK-611 rules: candidate names, self markers and the repository
/// oracle decide; the walker never guesses.
public struct ClassifierObjectDecider: ReviewObjectDeciding {
    private let classifier: ObjectClassifier
    private let rules: ObjectDetectionRules
    private let oracle: CountingRepositoryOracle

    public init(rules: ObjectDetectionRules = .default, oracle: any RepositoryOracle = IndexedRepositoryOracle()) {
        self.rules = rules
        self.oracle = CountingRepositoryOracle(oracle)
        classifier = ObjectClassifier(rules: rules, oracle: self.oracle)
    }

    public func isCandidateName(_ name: String) -> Bool { rules.isCandidateName(name) }
    public var selfMarkerNames: Set<String> { Set(rules.selfMarkers.keys) }
    public var projectMarkerNames: Set<String> { Set(rules.outputNames.values.flatMap { $0 }).union([rules.repositoryMarker]) }
    public func classify(directoryPath: String, repositoryPath: String?) -> ObjectClassification {
        classifier.classify(directoryPath: directoryPath, repositoryPath: repositoryPath)
    }

    var repositoryQueries: (Int, Double) { oracle.snapshot }
    var repositoryProcesses: Int { oracle.processes }
}

/// TASK-621: one bounded walk of a review scope. Directories are listed level
/// by level; a classified object is one entry whose allocated size comes from
/// a size-only pass, with nothing inside it classified, listed or stored.
/// Nothing is persisted here: the caller stores the report.
///
/// The walk is synchronous and blocking; run it on its own thread at utility
/// QoS, never on the Swift cooperative pool.
public struct ReviewWalker: Sendable {
    public typealias Clock = @Sendable () -> TimeInterval
    public typealias Footprint = @Sendable () -> UInt64

    private let reader: any DirectoryReader
    private let decider: any ReviewObjectDeciding
    private let budget: ReviewBudget
    private let previousCompleteEntries: Int?
    private let clock: Clock
    private let footprint: Footprint
    private let isCancelled: @Sendable () -> Bool

    public init(reader: any DirectoryReader = BulkDirectoryReader(), decider: any ReviewObjectDeciding = ClassifierObjectDecider(),
                budget: ReviewBudget = .default, previousCompleteEntries: Int? = nil,
                clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
                footprint: @escaping Footprint = ReviewWalker.physicalFootprint,
                isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.reader = reader
        self.decider = decider
        self.budget = budget
        self.previousCompleteEntries = previousCompleteEntries
        self.clock = clock
        self.footprint = footprint
        self.isCancelled = isCancelled
    }

    /// The process's physical footprint (what Activity Monitor shows as memory).
    public static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private struct Frame {
        let path: String
        let depth: Int
        /// Index of the top-level folder this frame belongs to, if below the root.
        let top: Int?
        let repository: String?
        let project: String?
    }

    private final class State {
        var entries = 0
        var directories = 0
        var scopeBytes: Int64 = 0
        var scopeLinks = Set<FileIdentity>()
        var visited = Set<FileIdentity>()
        var objects: [ReviewObject] = []
        var projects: [String: (marker: String, activity: TimeInterval, tools: [String])] = [:]
        var unresolved: [UnresolvedCandidate] = []
        var unresolvedCount = 0
        var unreadableDirectories = 0
        var unreadableEntries = 0
        var skippedMounts: [String] = []
        var excluded: [String] = []
        var classifierCalls = 0
        var topNames: [String] = []
        var topPending: [Int] = []
        var topIndex: [String: Int] = [:]
        var topIncomplete = Set<Int>()
        /// Top-level folders the walk reached (entered or measured).
        var topStarted = Set<Int>()
        var stop: ReviewStopReason?
        var lastMemoryCheck = 0
    }

    public func review(scope: String, excluded: [String] = [], startedAt: Date = Date()) -> ReviewReport {
        let start = clock()
        let baseline = footprint()
        let state = State()
        let excludedSet = Set(excluded)
        let root = scope
        let rootIdentity = reader.identity(of: root)
        if let rootIdentity { state.visited.insert(rootIdentity) }
        var stack: [Frame] = [Frame(path: root, depth: 0, top: nil, repository: nil, project: nil)]

        func checkBudget() -> Bool {
            if state.stop != nil { return false }
            if isCancelled() { state.stop = .cancelled }
            else if clock() - start > budget.wallSeconds { state.stop = .wallTime }
            else if state.entries > budget.maximumEntries { state.stop = .entries }
            else if let previous = previousCompleteEntries, previous > 0, state.entries > previous * 2 { state.stop = .growth }
            else if state.directories - state.lastMemoryCheck >= 64 || state.directories < 2 {
                state.lastMemoryCheck = state.directories
                let now = footprint()
                if now > baseline, now - baseline > budget.maximumMemoryBytes { state.stop = .memory }
            }
            return state.stop == nil
        }

        func childPath(_ parent: String, _ name: String) -> String { parent == "/" ? "/" + name : parent + "/" + name }

        func finish(_ frame: Frame) {
            guard let top = frame.top else { return }
            state.topPending[top] -= 1
        }

        func enter(_ identity: FileIdentity) -> Bool {
            if state.visited.contains(identity) { state.stop = .revisit; return false }
            state.visited.insert(identity)
            return true
        }

        /// The size-only pass: sums allocated bytes inside an object, hard
        /// links once within it, and lists, classifies and stores nothing.
        func measureObject(_ path: String, listing first: DirectoryListing?, classified: ClassifiedObject, project: String?, top: Int?) {
            var bytes: Int64 = 0
            var files = 0
            var newest: TimeInterval = 0
            var links = Set<FileIdentity>()
            var pending: [(String, DirectoryListing?)] = [(path, first)]
            var complete = true
            while let (directory, cached) = pending.popLast() {
                guard checkBudget() else { complete = false; break }
                let listing: DirectoryListing
                if let cached { listing = cached } else {
                    do { listing = try reader.list(directory) } catch { state.unreadableDirectories += 1; complete = false; continue }
                }
                state.directories += 1
                state.entries += listing.entries.count
                state.unreadableEntries += listing.unreadableEntries
                for entry in listing.entries {
                    newest = max(newest, entry.modified)
                    switch entry.type {
                    case .directory:
                        let identity = FileIdentity(device: entry.device, fileID: entry.fileID)
                        if let rootIdentity, entry.device != rootIdentity.device { state.skippedMounts.append(childPath(directory, entry.name)); continue }
                        guard enter(identity) else { complete = false; break }
                        pending.append((childPath(directory, entry.name), nil))
                    case .file, .symlink, .other:
                        files += 1
                        if entry.linkCount > 1 {
                            let identity = FileIdentity(device: entry.device, fileID: entry.fileID)
                            if links.insert(identity).inserted { bytes += entry.allocatedBytes }
                            if state.scopeLinks.insert(identity).inserted { state.scopeBytes += entry.allocatedBytes }
                        } else {
                            bytes += entry.allocatedBytes
                            state.scopeBytes += entry.allocatedBytes
                        }
                    }
                }
                if state.stop != nil { complete = false; break }
            }
            if complete {
                let recreate: RecreateClass = classified.kind == .repository ? .liveState : (classified.kind == .cache ? .redownload : .rebuild)
                state.objects.append(ReviewObject(
                    path: path, kind: classified.kind, rule: classified.rule, reason: classified.reason,
                    projectPath: classified.owningProjectPath ?? project, recreateClass: recreate,
                    allocatedBytes: bytes, fileCount: files, lastActivity: newest))
            } else if let top {
                state.topIncomplete.insert(top)
            }
        }

        while let frame = stack.popLast() {
            guard checkBudget() else { if let top = frame.top { state.topIncomplete.insert(top) }; break }
            let listing: DirectoryListing
            do { listing = try reader.list(frame.path) } catch {
                state.unreadableDirectories += 1
                if let top = frame.top { state.topIncomplete.insert(top) }
                finish(frame)
                continue
            }
            let names = Set(listing.entries.map(\.name))
            // A marker inside makes the directory an object whatever it is named.
            if frame.depth > 0, !names.isDisjoint(with: decider.selfMarkerNames) {
                state.classifierCalls += 1
                if case let .object(object) = decider.classify(directoryPath: frame.path, repositoryPath: frame.repository) {
                    measureObject(frame.path, listing: listing, classified: object, project: frame.project, top: frame.top)
                    finish(frame)
                    continue
                }
            }
            state.directories += 1
            state.entries += listing.entries.count
            state.unreadableEntries += listing.unreadableEntries
            if frame.depth == 0 {
                for entry in listing.entries where entry.type == .directory {
                    let path = childPath(frame.path, entry.name)
                    guard !excludedSet.contains(path), rootIdentity.map({ entry.device == $0.device }) ?? true else { continue }
                    state.topIndex[path] = state.topNames.count
                    state.topNames.append(path)
                    state.topPending.append(0)
                }
            }
            let isRepository = listing.entries.contains { $0.type == .directory && $0.name == ".git" }
            let repository = isRepository ? frame.path : frame.repository
            let marker = isRepository ? ".git" : listing.entries.first { $0.type == .file && decider.projectMarkerNames.contains($0.name) }?.name
            let project = marker != nil ? frame.path : frame.project
            if let marker, state.projects[frame.path] == nil {
                let tools = Set(listing.entries.compactMap { $0.type == .file ? ReviewProject.toolFiles[$0.name] : nil })
                state.projects[frame.path] = (marker, 0, tools.sorted())
            }
            for entry in listing.entries {
                if state.stop != nil { break }
                let path = childPath(frame.path, entry.name)
                switch entry.type {
                case .directory:
                    if excludedSet.contains(path) { state.excluded.append(path); continue }
                    if let rootIdentity, entry.device != rootIdentity.device { state.skippedMounts.append(path); continue }
                    let top = frame.depth == 0 ? state.topIndex[path] : frame.top
                    guard enter(FileIdentity(device: entry.device, fileID: entry.fileID)) else {
                        if let top { state.topIncomplete.insert(top) }
                        break
                    }
                    if let top { state.topStarted.insert(top) }
                    if decider.isCandidateName(entry.name) {
                        state.classifierCalls += 1
                        switch decider.classify(directoryPath: path, repositoryPath: repository) {
                        case let .object(object):
                            measureObject(path, listing: nil, classified: object, project: project, top: top)
                            continue
                        case let .unresolved(candidate):
                            state.unresolvedCount += 1
                            if state.unresolved.count < 50 { state.unresolved.append(candidate) }
                        case .source:
                            break
                        }
                    }
                    if let top { state.topPending[top] += 1 }
                    stack.append(Frame(path: path, depth: frame.depth + 1, top: top, repository: repository, project: project))
                case .file, .symlink, .other:
                    if entry.linkCount > 1 {
                        if state.scopeLinks.insert(FileIdentity(device: entry.device, fileID: entry.fileID)).inserted { state.scopeBytes += entry.allocatedBytes }
                    } else {
                        state.scopeBytes += entry.allocatedBytes
                    }
                    if let project, let current = state.projects[project] {
                        state.projects[project] = (current.marker, max(current.activity, entry.modified), current.tools)
                    }
                }
            }
            finish(frame)
            if state.stop != nil { break }
        }

        var covered: [String] = []
        var uncovered: [String] = []
        for (index, path) in state.topNames.enumerated() {
            // Covered only when every frame below it finished and nothing in it was skipped.
            if state.topPending[index] == 0, !state.topIncomplete.contains(index), state.topStarted.contains(index) || state.stop == nil {
                covered.append(path)
            } else {
                uncovered.append(path)
            }
        }
        let (queries, seconds) = (decider as? ClassifierObjectDecider)?.repositoryQueries ?? (0, 0)
        let gitProcesses = (decider as? ClassifierObjectDecider)?.repositoryProcesses ?? 0
        let projects = state.projects.map { path, value -> ReviewProject in
            // Never leave activity unknown: fall back to the project folder's own time.
            let activity = value.activity > 0 ? value.activity : ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            return ReviewProject(path: path, marker: value.marker, lastSourceActivity: activity, tools: value.tools)
        }.sorted { $0.path < $1.path }
        let elapsed = clock() - start
        return ReviewReport(
            reportID: Self.identifier(scope + "\u{0}" + String(startedAt.timeIntervalSince1970)),
            scope: scope, startedAt: startedAt, completedAt: startedAt.addingTimeInterval(elapsed),
            status: state.stop.map { .stopped($0) } ?? .completed,
            entriesVisited: state.entries, directoriesVisited: state.directories, scopeAllocatedBytes: state.scopeBytes,
            objects: state.objects.sorted { $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes },
            projects: projects, unresolved: state.unresolved, unresolvedCount: state.unresolvedCount,
            unreadableDirectories: state.unreadableDirectories, unreadableEntries: state.unreadableEntries,
            skippedMounts: state.skippedMounts, excluded: state.excluded, coveredTopLevel: covered, uncoveredTopLevel: uncovered,
            classifierCalls: state.classifierCalls, repositoryQueries: queries, repositoryQuerySeconds: seconds, repositoryProcesses: gitProcesses)
    }

    static func identifier(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
