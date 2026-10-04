import Darwin
import Foundation

/// How one object's size changed between its last measurement and now.
public struct ObjectGrowth: Codable, Sendable, Equatable {
    public enum Basis: String, Codable, Sendable {
        /// Measured now against an earlier measurement.
        case measured
        /// Created inside the window (by its birth time), so it was empty before.
        case created
        /// No earlier measurement and not created in the window: its size is
        /// known, its change is not.
        case noBaseline = "no-baseline"
        /// Gone since its last measurement.
        case gone
        /// The budget ran out, or it could not be read, before it was measured.
        case notMeasured = "not-measured"
    }

    public let path: String
    public let basis: Basis
    /// Journal changes inside it in the window; 0 when it was measured
    /// because it lies under a changed directory.
    public let changes: Int64
    public let previousBytes: Int64?
    public let previousMeasuredAt: Date?
    public let currentBytes: Int64?
    public let deltaBytes: Int64?
    /// Folders inside it that could not be read; its size covers the rest.
    public let unreadableDirectories: Int
}

/// TASK-661: the volume's change over a window, attributed to measured
/// objects, with the rest stated as unexplained. The remainder is never given
/// a cause: it covers what no object measurement can see.
public struct GrowthAttribution: Codable, Sendable, Equatable {
    public enum Trigger: String, Codable, Sendable {
        /// Free space dropped by the growth threshold since the last attribution.
        case threshold
        /// A growth question reached the present.
        case request
    }

    /// Used-space change from the capacity ring, between its first and last
    /// samples inside the window.
    public struct VolumeChange: Codable, Sendable, Equatable {
        public let deltaBytes: Int64
        public let firstSampleAt: Date
        public let lastSampleAt: Date
    }

    public struct Gap: Codable, Sendable, Equatable {
        public let reason: String
        public let path: String
        public let at: Date
    }

    public static let remainderCovers = "System Data, purgeable space, APFS snapshots, files outside measured objects, and anything outside the monitored folders"

    public let attributionID: String
    public let trigger: Trigger
    public let from: Date
    public let through: Date
    public let volume: VolumeChange?
    /// The sum of measured deltas (growth minus shrinkage).
    public let attributedBytes: Int64
    /// The volume delta minus the attributed bytes, when the delta is known.
    public let unexplainedBytes: Int64?
    /// Largest changes first; at most `GrowthAttributor.storedObjects`.
    public let objects: [ObjectGrowth]
    public let objectsOmitted: Int
    /// Changed directories inside no measured object (a sample) and their count.
    public let unmeasuredDirectories: [String]
    public let unmeasuredDirectoryCount: Int
    public let gaps: [Gap]
    public let stopReason: ReviewStopReason?
    public let limitations: [String]

    /// Every candidate was measured and the journal vouches for the window.
    public var isComplete: Bool { stopReason == nil && gaps.isEmpty && !objects.contains { $0.basis == .notMeasured } }
}

/// Re-measures the objects the change journal marks dirty and attributes the
/// volume delta to them. Measurement is the review walker's size-only pass,
/// under a review budget.
public struct GrowthAttributor: Sendable {
    /// An answer to a question must come back within the IPC deadline (10 s).
    public static let requestBudget = ReviewBudget(wallSeconds: 4, maximumEntries: 1_000_000, maximumMemoryBytes: 128 * 1_024 * 1_024)
    /// The most objects one attribution measures.
    public static let maximumTargets = 500
    /// The most objects one stored attribution lists.
    public static let storedObjects = 100
    public static let storedDirectories = 24
    public static let label = "attribution"

    public struct Target: Sendable, Equatable {
        public let path: String
        public let baseline: IndexedObject?
        public let changes: Int64
    }

    public struct Plan: Sendable, Equatable {
        public let targets: [Target]
        /// Candidates beyond `maximumTargets`, not measured.
        public let omittedTargets: Int
        public let unmatched: [JournalChange]
    }

    public struct Outcome: Sendable {
        public let attribution: GrowthAttribution
        /// Fresh measurements to store as the next baselines.
        public let measured: [ReviewObject]
        /// Object paths that no longer exist.
        public let gone: [String]
    }

    private let makeWalker: @Sendable (ReviewBudget) -> ReviewWalker

    public init(makeWalker: @escaping @Sendable (ReviewBudget) -> ReviewWalker = { ReviewWalker(budget: $0) }) {
        self.makeWalker = makeWalker
    }

    /// Joins changed directories to objects. A change inside or at a stored
    /// object marks it; a change above stored objects marks every object
    /// under it (the journal collapses changes two levels below a root); a
    /// change at an object-named directory with no stored object is a new
    /// candidate. Anything else is a changed directory no object explains.
    public static func plan(changes: [JournalChange], containing: [String: IndexedObject], under: [String: [IndexedObject]]) -> Plan {
        var direct: [String: (IndexedObject?, Int64)] = [:]
        var nested: [String: IndexedObject] = [:]
        var unmatched: [JournalChange] = []
        for change in changes {
            if let object = containing[change.path] {
                direct[object.path, default: (object, 0)].1 += change.changes
                continue
            }
            let inside = under[change.path] ?? []
            for object in inside where direct[object.path] == nil { nested[object.path] = object }
            if ChangeJournal.objectNames.contains(URL(fileURLWithPath: change.path).lastPathComponent) {
                direct[change.path, default: (nil, 0)].1 += change.changes
            } else if inside.isEmpty {
                unmatched.append(change)
            }
        }
        var targets = direct.map { Target(path: $0.key, baseline: $0.value.0, changes: $0.value.1) }
            .sorted { ($0.changes, $1.path) > ($1.changes, $0.path) }
        // Objects only known to lie under a changed directory: most recently active first.
        targets += nested.values.filter { direct[$0.path] == nil }
            .sorted { ($0.lastActivity, $1.path) > ($1.lastActivity, $0.path) }
            .map { Target(path: $0.path, baseline: $0, changes: 0) }
        // The walker stops at a revisit, so a target inside another is dropped.
        var kept: [Target] = []
        for target in targets.sorted(by: { $0.path < $1.path }) {
            if let last = kept.last, target.path.hasPrefix(last.path == "/" ? "/" : last.path + "/") { continue }
            kept.append(target)
        }
        let order = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($1.path, $0) })
        kept.sort { order[$0.path, default: .max] < order[$1.path, default: .max] }
        return Plan(targets: Array(kept.prefix(maximumTargets)), omittedTargets: max(0, kept.count - maximumTargets),
                    unmatched: unmatched.sorted { ($0.changes, $1.path) > ($1.changes, $0.path) })
    }

    public func attribute(plan: Plan, gaps: [JournalGap], changesTruncated: Int, volume: GrowthAttribution.VolumeChange?, from: Date, through: Date,
                          trigger: GrowthAttribution.Trigger, budget: ReviewBudget, id: String = UUID().uuidString) -> Outcome {
        var present: [Target] = []
        var growth: [ObjectGrowth] = []
        var gone: [String] = []
        for target in plan.targets {
            var status = stat()
            if lstat(target.path, &status) == 0 {
                present.append(target)
            } else if let baseline = target.baseline {
                gone.append(target.path)
                growth.append(ObjectGrowth(path: target.path, basis: .gone, changes: target.changes, previousBytes: baseline.allocatedBytes,
                                           previousMeasuredAt: baseline.measuredAt, currentBytes: 0, deltaBytes: -baseline.allocatedBytes,
                                           unreadableDirectories: 0))
            }
        }
        let targets = present.map { target in
            ReviewWalker.CatalogTarget(
                path: target.path,
                object: ClassifiedObject(path: target.path, kind: ClassifiedObjectKind(rawValue: target.baseline?.kind ?? "") ?? .artifact, rule: .catalog,
                                         confidence: .high, reason: "it changed since it was last measured"),
                recreateClass: RecreateClass(rawValue: target.baseline?.recreateClass ?? "") ?? .rebuild, cleanupCommand: nil)
        }
        let report = makeWalker(budget).reviewCatalog(targets, label: Self.label, startedAt: through)
        let measuredByPath = Dictionary(report.objects.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var fresh: [ReviewObject] = []
        for target in present {
            guard let object = measuredByPath[target.path] else {
                growth.append(ObjectGrowth(path: target.path, basis: .notMeasured, changes: target.changes, previousBytes: target.baseline?.allocatedBytes,
                                           previousMeasuredAt: target.baseline?.measuredAt, currentBytes: nil, deltaBytes: nil, unreadableDirectories: 0))
                continue
            }
            fresh.append(object)
            if let baseline = target.baseline {
                growth.append(ObjectGrowth(path: target.path, basis: .measured, changes: target.changes, previousBytes: baseline.allocatedBytes,
                                           previousMeasuredAt: baseline.measuredAt, currentBytes: object.allocatedBytes,
                                           deltaBytes: object.allocatedBytes - baseline.allocatedBytes, unreadableDirectories: object.unreadableDirectories))
            } else if let born = Self.birthTime(target.path), born >= from {
                growth.append(ObjectGrowth(path: target.path, basis: .created, changes: target.changes, previousBytes: 0, previousMeasuredAt: nil,
                                           currentBytes: object.allocatedBytes, deltaBytes: object.allocatedBytes, unreadableDirectories: object.unreadableDirectories))
            } else {
                growth.append(ObjectGrowth(path: target.path, basis: .noBaseline, changes: target.changes, previousBytes: nil, previousMeasuredAt: nil,
                                           currentBytes: object.allocatedBytes, deltaBytes: nil, unreadableDirectories: object.unreadableDirectories))
            }
        }
        let attributed = growth.compactMap(\.deltaBytes).reduce(0, +)
        var stop: ReviewStopReason?
        if case let .stopped(reason) = report.status { stop = reason }
        var limitations: [String] = []
        if let stop { limitations.append("Measurement stopped (\(stop.rawValue)); \(growth.filter { $0.basis == .notMeasured }.count) objects were not measured and their change is in the remainder.") }
        if plan.omittedTargets > 0 { limitations.append("\(plan.omittedTargets) further changed objects were beyond the \(Self.maximumTargets)-object limit and were not measured.") }
        if changesTruncated > 0 { limitations.append("\(changesTruncated) further changed directories were not considered; their change is in the remainder.") }
        let early = growth.filter { ($0.previousMeasuredAt.map { $0 < from.addingTimeInterval(-60) }) == true }.count
        if early > 0 { limitations.append("\(early) objects were last measured before the window, so their deltas can include earlier change.") }
        let late = growth.filter { ($0.previousMeasuredAt.map { $0 > from.addingTimeInterval(60) }) == true }.count
        if late > 0 { limitations.append("\(late) objects were measured during the window, so their deltas miss earlier change in it.") }
        let unknown = growth.filter { $0.basis == .noBaseline }.count
        if unknown > 0 { limitations.append("\(unknown) objects had no earlier measurement; their sizes are recorded for next time and their change is in the remainder.") }
        if let volume {
            if volume.firstSampleAt.timeIntervalSince(from) > 600 || through.timeIntervalSince(volume.lastSampleAt) > 600 {
                limitations.append("Capacity samples cover only part of the window, so the remainder compares slightly different intervals.")
            }
        } else {
            limitations.append("No capacity samples cover the window, so the unexplained remainder is unknown.")
        }
        if !gaps.isEmpty { limitations.append("The change journal has gaps in the window; changes there are unknown, not absent.") }
        let ordered = growth.sorted { (abs($0.deltaBytes ?? 0), $1.path) > (abs($1.deltaBytes ?? 0), $0.path) }
        let attribution = GrowthAttribution(
            attributionID: id, trigger: trigger, from: from, through: through, volume: volume, attributedBytes: attributed,
            unexplainedBytes: volume.map { $0.deltaBytes - attributed }, objects: Array(ordered.prefix(Self.storedObjects)),
            objectsOmitted: max(0, ordered.count - Self.storedObjects),
            unmeasuredDirectories: plan.unmatched.prefix(Self.storedDirectories).map(\.path), unmeasuredDirectoryCount: plan.unmatched.count,
            gaps: gaps.map { .init(reason: $0.reason, path: $0.path, at: $0.at) }, stopReason: stop, limitations: limitations)
        return Outcome(attribution: attribution, measured: fresh, gone: gone)
    }

    static func birthTime(_ path: String) -> Date? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(status.st_birthtimespec.tv_sec) + TimeInterval(status.st_birthtimespec.tv_nsec) / 1e9)
    }
}

public enum GrowthAttributionError: Error, Equatable, Sendable {
    /// Another attribution is measuring.
    case busy
}

/// TASK-661: runs attributions when free space drops by the growth threshold
/// or when a growth question reaches the present, advances the stored
/// object sizes so the next attribution starts where this one ended, and
/// keeps the last few attributions in a bounded file beside the steward file.
public actor GrowthAttributionService {
    public static let storedAttributions = 8
    /// The attribution file never exceeds this; the oldest entries go first.
    public static let fileByteLimit = 512 * 1_024
    /// A question reusing an attribution this recent does not measure again.
    public static let reuseSeconds: TimeInterval = 120
    /// A window ending this close to now reaches the present.
    public static let presentSeconds: TimeInterval = 10 * 60
    /// The first attribution looks back this far, or to the journal's start.
    public static let firstWindow: TimeInterval = 24 * 60 * 60
    public static let directoriesConsidered = 500
    public static let objectsUnderEachDirectory = 200

    private let journal: ChangeJournal
    private let index: ReviewIndex
    private let ringURL: URL
    private let fileURL: URL
    private let attributor: GrowthAttributor
    private let now: @Sendable () -> Date
    private let paused: @Sendable () async -> Bool
    private var ring: CapacityRing?
    private var volumeUUID: String?
    private var lowWatermark: Int64?
    private var running = false
    private var stored: [GrowthAttribution]

    public init(journal: ChangeJournal, index: ReviewIndex, ringURL: URL, fileURL: URL, attributor: GrowthAttributor = .init(),
                now: @escaping @Sendable () -> Date = Date.init, paused: @escaping @Sendable () async -> Bool = { false }) {
        self.journal = journal
        self.index = index
        self.ringURL = ringURL
        self.fileURL = fileURL
        self.attributor = attributor
        self.now = now
        self.paused = paused
        stored = Self.load(fileURL)
    }

    public static func defaultFileURL(beside stewardURL: URL) -> URL {
        stewardURL.deletingLastPathComponent().appending(path: "growth-attributions.json")
    }

    /// Newest first.
    public var attributions: [GrowthAttribution] { stored }
    public var isRunning: Bool { running }

    public func attributions(overlapping from: Date, through: Date) -> [GrowthAttribution] {
        stored.filter { $0.from <= through && $0.through >= from }
    }

    /// The threshold trigger, fed every capacity sample. Once used space has
    /// grown by `thresholdBytes` above its lowest point since the last
    /// attribution, the dirty objects are measured under `budget`.
    @discardableResult
    public func observe(usedBytes: Int64, volumeUUID: String, thresholdBytes: Int64, budget: ReviewBudget = .default) async -> GrowthAttribution? {
        if self.volumeUUID != volumeUUID {
            self.volumeUUID = volumeUUID
            lowWatermark = nil
        }
        let low = min(lowWatermark ?? usedBytes, usedBytes)
        lowWatermark = low
        guard thresholdBytes > 0, usedBytes - low >= thresholdBytes, !running, !(await paused()) else { return nil }
        guard let attribution = try? await attribute(trigger: .threshold, budget: budget) else { return nil }
        lowWatermark = usedBytes
        return attribution
    }

    /// For a question that reaches the present: a recent attribution, or a
    /// new one within the request budget.
    public func current() async throws -> GrowthAttribution {
        if let latest = stored.first, now().timeIntervalSince(latest.through) < Self.reuseSeconds { return latest }
        return try await attribute(trigger: .request, budget: GrowthAttributor.requestBudget)
    }

    /// Measures the objects changed since the last attribution (or over the
    /// first window) and stores the result.
    public func attribute(trigger: GrowthAttribution.Trigger, budget: ReviewBudget) async throws -> GrowthAttribution {
        guard !running else { throw GrowthAttributionError.busy }
        running = true
        defer { running = false }
        let through = now()
        var from = through.addingTimeInterval(-Self.firstWindow)
        if let previous = stored.first?.through, previous < through {
            from = previous
        } else if let start = try await journal.coverageStart(), start > from {
            from = start
        }
        let window = try await journal.changes(from: from, through: through, limit: Self.directoriesConsidered)
        let paths = window.changes.items.map(\.path)
        let plan = GrowthAttributor.plan(changes: window.changes.items, containing: try await index.objectsContaining(paths),
                                         under: try await index.objectsUnder(paths, limit: Self.objectsUnderEachDirectory))
        let volume = await volumeChange(from: from, through: through)
        let attributor = self.attributor
        let gaps = window.gaps
        let truncated = max(0, window.changes.total - window.changes.items.count)
        // The size pass is synchronous file-system work; keep it off the actor.
        let outcome = await Task.detached(priority: .utility) {
            attributor.attribute(plan: plan, gaps: gaps, changesTruncated: truncated, volume: volume, from: from, through: through,
                                 trigger: trigger, budget: budget)
        }.value
        try await index.updateMeasurements(outcome.measured, gone: outcome.gone, at: through)
        stored.insert(outcome.attribution, at: 0)
        save()
        return outcome.attribution
    }

    private func volumeChange(from: Date, through: Date) async -> GrowthAttribution.VolumeChange? {
        guard let volumeUUID else { return nil }
        if ring == nil, FileManager.default.fileExists(atPath: ringURL.path) { ring = try? CapacityRing(url: ringURL) }
        guard let ring, let ends = try? await ring.endpoints(volumeUUID: volumeUUID, from: from, through: through) else { return nil }
        let before = ends.first.totalBytes - ends.first.availableBytes
        let after = ends.last.totalBytes - ends.last.availableBytes
        return .init(deltaBytes: after - before, firstSampleAt: ends.first.observedAt, lastSampleAt: ends.last.observedAt)
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (encoder, decoder)
    }

    private static func load(_ url: URL) -> [GrowthAttribution] {
        guard let data = try? Data(contentsOf: url), data.count <= fileByteLimit,
              let values = try? coder().1.decode([GrowthAttribution].self, from: data) else { return [] }
        return Array(values.sorted { $0.through > $1.through }.prefix(storedAttributions))
    }

    private func save() {
        var kept = Array(stored.prefix(Self.storedAttributions))
        let encoder = Self.coder().0
        var data = (try? encoder.encode(kept)) ?? Data("[]".utf8)
        while data.count > Self.fileByteLimit, !kept.isEmpty {
            kept.removeLast()
            data = (try? encoder.encode(kept)) ?? Data("[]".utf8)
        }
        stored = kept
        try? data.write(to: fileURL, options: .atomic)
    }
}
