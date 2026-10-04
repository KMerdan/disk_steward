import AppKit
import DiskStewardCore
import Foundation

/// TASK-623: the review window's state. Capacity and review are separate on
/// purpose: free space is measured, while "worth reviewing" is an estimate
/// that never claims anything is safe to delete.
@MainActor
final class ReviewWindowModel: ObservableObject {
    struct Capacity: Equatable {
        /// Nil when the volume could not be measured; no old value is shown instead.
        var availableBytes: Int64?
        var reserveBytes: Int64?

        static let unavailable = Capacity(availableBytes: nil, reserveBytes: nil)
    }

    enum Scope: Hashable, Identifiable {
        case folder(String)
        case caches

        var id: String { label }
        var label: String {
            switch self {
            case let .folder(path): return (path as NSString).abbreviatingWithTildeInPath
            case .caches: return "Opted-in caches"
            }
        }
    }

    enum Evidence: String, Equatable {
        case verifiedNow = "Verified now"
        case stale = "Stale"
        case partial = "Partial"
        case unknown = "Unknown"
    }

    struct Item: Identifiable, Equatable {
        var id: String { path }
        let rank: Int
        let name: String
        let path: String
        let group: String
        let allocatedBytes: Int64
        let recreateClass: String
        let origin: String
        let whyDisposable: [String]
        let reasonsToKeep: [String]
        let rebuildCommand: String
        let rebuildCommandKnown: Bool
        let cleanupCommand: String?
        let verifiedAt: Date
        let evidence: Evidence
    }

    struct Display: Equatable {
        let scope: Scope
        let completedAt: Date
        let status: ReviewStatus
        let isComplete: Bool
        let coveredFolders: Int
        let uncovered: [String]
        let limitations: [String]
        let items: [Item]

        var stopped: Bool { status != .completed }
    }

    /// The window's states, from the design's state table.
    enum ReviewState: Equatable {
        case none
        case reviewing(ReviewProgress)
        case completeWithItems
        case completeWithZeroItems
        case partial
        case detailUnavailable(String)
    }

    @Published var scopes: [Scope]
    @Published var selectedScope: Scope
    @Published private(set) var capacity: Capacity
    @Published var reviewState: ReviewState = .none
    @Published var display: Display?
    @Published var selectedItemID: Item.ID?
    @Published private(set) var lastMessage: String?

    private let service: ReviewService?
    private let index: ReviewIndex?
    private let capacityProvider: () -> Capacity
    private let excluded: () -> [String]
    private let optedInCaches: () -> Set<String>
    private let now: () -> Date
    private var running: Task<Void, Never>?

    init(service: ReviewService?, index: ReviewIndex?, scopes: [Scope], capacity: @escaping () -> Capacity,
         excluded: @escaping () -> [String] = { [] }, optedInCaches: @escaping () -> Set<String> = { [] }, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.index = index
        self.scopes = scopes
        selectedScope = scopes.first ?? .caches
        capacityProvider = capacity
        self.capacity = capacity()
        self.excluded = excluded
        self.optedInCaches = optedInCaches
        self.now = now
    }

    var isReviewing: Bool { if case .reviewing = reviewState { return true } else { return false } }

    var selectedItem: Item? { display?.items.first { $0.id == selectedItemID } }

    /// Items grouped by project (or "Tool caches"), groups in rank order.
    var groups: [(name: String, items: [Item])] {
        guard let items = display?.items else { return [] }
        var order: [String] = []
        var grouped: [String: [Item]] = [:]
        for item in items {
            if grouped[item.group] == nil { order.append(item.group) }
            grouped[item.group, default: []].append(item)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var worthReviewingBytes: Int64 { display?.items.reduce(0) { $0 + $1.allocatedBytes } ?? 0 }

    // MARK: Text

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    var capacityLine: String {
        guard let available = capacity.availableBytes else { return "Capacity unavailable: the volume could not be measured just now." }
        var line = "\(Self.bytes(available)) free"
        if let reserve = capacity.reserveBytes {
            let distance = available - reserve
            line += distance >= 0 ? " · \(Self.bytes(distance)) above your \(Self.bytes(reserve)) reserve"
                                  : " · \(Self.bytes(-distance)) below your \(Self.bytes(reserve)) reserve"
        }
        return line
    }

    var belowReserve: Bool {
        guard let available = capacity.availableBytes, let reserve = capacity.reserveBytes else { return false }
        return available < reserve
    }

    /// The state's main sentence: what is known, and what is not.
    var stateLine: String {
        switch reviewState {
        case .none:
            return "No review of \(selectedScope.label) yet. A review measures build output, environments and caches; it deletes nothing."
        case let .reviewing(progress):
            return "Reviewing \(selectedScope.label) · \(Self.elapsed(progress.elapsedSeconds)) · \(Self.count(progress.entries, "entry", "entries")) in \(Self.count(progress.directories, "folder", "folders")) · \(Self.count(progress.objects, "object", "objects")) found"
        case .completeWithItems:
            guard let display else { return "" }
            return "\(Self.bytes(worthReviewingBytes)) worth reviewing in \(Self.count(display.items.count, "item", "items")) · reviewed \(display.completedAt.formatted(date: .abbreviated, time: .shortened))"
        case .completeWithZeroItems:
            return "Nothing in the completed scope met review rules. This says nothing about the rest of the disk."
        case .partial:
            guard let display else { return "" }
            if !display.stopped {
                // It ran to the end; only unreadable folders keep it partial.
                let found = display.items.isEmpty ? "Nothing in the readable part met review rules"
                    : "\(Self.bytes(worthReviewingBytes)) worth reviewing in \(Self.count(display.items.count, "item", "items"))"
                return "The review finished, but some folders could not be read. \(found); the unreadable folders are unknown, not absent."
            }
            let found = display.items.isEmpty ? "No items were found in the part that was covered" : "\(Self.bytes(worthReviewingBytes)) worth reviewing in \(Self.count(display.items.count, "item", "items")) so far"
            // A stored report keeps its limitations, not the uncovered paths.
            let rest = display.uncovered.isEmpty ? "the rest of the scope was not reviewed and is unknown, not empty."
                : "\(Self.count(display.uncovered.count, "folder was", "folders were")) not reviewed and \(display.uncovered.count == 1 ? "is" : "are") unknown, not empty."
            return "The review stopped before covering everything. \(found); \(rest)"
        case let .detailUnavailable(reason):
            return "File detail is unavailable: \(reason). Free space above is live and does not depend on it."
        }
    }

    var primaryActionTitle: String {
        if capacity.availableBytes == nil { return "Retry Capacity Read" }
        switch reviewState {
        case .reviewing: return "Stop Review"
        case .none: return "Review Storage"
        case .completeWithItems: return "Refresh Review"
        case .completeWithZeroItems: return "Choose Another Scope"
        case .partial where finishedWithUnreadable: return display?.items.isEmpty == false ? "Refresh Review" : "Choose Another Scope"
        case .partial, .detailUnavailable: return "Review a Smaller Scope"
        }
    }

    /// A review that ran to the end but could not read some folders: a
    /// smaller scope would not help, so its action matches a complete review.
    var finishedWithUnreadable: Bool { reviewState == .partial && display?.stopped == false }

    var accessibilitySummary: String {
        var parts = [capacityLine, stateLine]
        if let display { parts.append("Last review \(display.completedAt.formatted(date: .abbreviated, time: .shortened)).") }
        return parts.joined(separator: " ")
    }

    /// What VoiceOver reads for a row: the amount, how fresh it is, and when it was checked.
    static func accessibilityLabel(for item: Item) -> String {
        "\(item.name), \(bytes(item.allocatedBytes)), \(item.evidence.rawValue), checked \(item.verifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value.formatted()) \(value == 1 ? one : many)"
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }

    // MARK: Actions

    func refreshCapacity() { capacity = capacityProvider() }

    func primaryAction() {
        if capacity.availableBytes == nil { refreshCapacity(); return }
        switch reviewState {
        case .reviewing: stop()
        case .partial where finishedWithUnreadable && display?.items.isEmpty == false: start()
        case .completeWithZeroItems, .partial, .detailUnavailable:
            // Another scope is the honest next step; the user chooses it.
            if let next = scopes.first(where: { $0 != selectedScope }) { selectedScope = next; reviewState = .none; display = nil; Task { await loadLatest() } }
        default: start()
        }
    }

    func start() {
        guard let service, !isReviewing else { return }
        let scope = selectedScope
        reviewState = .reviewing(ReviewProgress(entries: 0, directories: 0, objects: 0, elapsedSeconds: 0, currentTopLevel: nil))
        let owner = WeakModel(self)
        let progress: @Sendable (ReviewProgress) -> Void = { value in
            Task { @MainActor in
                guard let model = owner.model, model.isReviewing else { return }
                model.reviewState = .reviewing(value)
            }
        }
        running = Task { [weak self] in
            do {
                let report: ReviewReport
                switch scope {
                case let .folder(path): report = try await service.review(scope: path, excluded: self?.excluded() ?? [], progress: progress)
                case .caches: report = try await service.reviewCatalog(optedIn: self?.optedInCaches() ?? [], progress: progress)
                }
                guard let self else { return }
                let ranked = ReviewRanking.revalidate(ReviewRanking.rank(report, now: report.completedAt), at: self.now())
                self.show(Self.display(for: scope, report: report, items: ranked, now: self.now()))
            } catch ReviewError.coolingDown(let until) {
                self?.reviewState = .detailUnavailable("this scope stopped early and can be reviewed again after \(until.formatted(date: .omitted, time: .shortened))")
            } catch {
                self?.reviewState = .detailUnavailable(Self.describe(error))
            }
            self?.refreshCapacity()
        }
    }

    func stop() { service?.stop() }

    /// Shows the newest stored review of the selected scope, revalidated now.
    func loadLatest() async {
        guard let index, !isReviewing else { return }
        let label: String
        switch selectedScope {
        case let .folder(path): label = DirectoryChangeStream.canonicalPath(path)
        case .caches: label = CacheCatalog.scope
        }
        do {
            guard let stored = try await index.latestReport(scope: label) else { reviewState = .none; display = nil; return }
            let items = try await index.items(reportID: stored.reportID, limit: ReviewRanking.maximumItems)
            show(Self.display(for: selectedScope, stored: stored, items: items, now: now()))
        } catch {
            reviewState = .detailUnavailable(Self.describe(error))
        }
    }

    func show(_ value: Display) {
        display = value
        selectedItemID = value.items.first?.id
        if value.stopped || !value.isComplete {
            // An interrupted review is never shown as "nothing found".
            reviewState = .partial
        } else {
            reviewState = value.items.isEmpty ? .completeWithZeroItems : .completeWithItems
        }
    }

    func revealInFinder(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    /// Plain text a person can paste anywhere: what it is, the evidence, and
    /// how to recreate or clean it with the owning tool. Never a verdict.
    func reviewBrief(_ item: Item) -> String {
        var lines = ["Review: \(item.name) (\(Self.bytes(item.allocatedBytes)))", "Path: \(item.path)", "Evidence: \(item.evidence.rawValue), checked \(item.verifiedAt.formatted(date: .abbreviated, time: .shortened))", "Origin: \(item.origin)"]
        lines += item.whyDisposable.map { "May be disposable: \($0)" }
        lines += item.reasonsToKeep.map { "Reason to keep: \($0)" }
        lines.append("Recreate: \(item.rebuildCommand)")
        if let cleanup = item.cleanupCommand { lines.append("Owning tool's cleanup command (not run): \(cleanup)") }
        lines.append("Disk Steward found this for review; it does not say it is safe to delete.")
        return lines.joined(separator: "\n")
    }

    func copyReviewBrief(_ item: Item) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reviewBrief(item), forType: .string)
        lastMessage = "Copied the review brief for \(item.name)."
    }

    // MARK: Building displays

    static func describe(_ error: Error) -> String {
        if case ReviewError.busy = error { return "another review is running" }
        if case let ReviewError.scopeUnavailable(path) = error { return "\((path as NSString).abbreviatingWithTildeInPath) is not available" }
        if case let ReviewIndexError.refused(table, _) = error { return "the review could not be stored (\(table))" }
        return error.localizedDescription
    }

    static func display(for scope: Scope, report: ReviewReport, items: [RankedReviewItem], now: Date) -> Display {
        Display(scope: scope, completedAt: report.completedAt, status: report.status, isComplete: report.isComplete,
                coveredFolders: report.coveredTopLevel.count, uncovered: report.uncoveredTopLevel, limitations: report.limitations,
                items: items.filter { $0.state == .reviewRequired }.map { item(from: $0, now: now) })
    }

    static func display(for scope: Scope, stored: StoredReviewReport, items: [StoredReviewItem], now: Date) -> Display {
        let status: ReviewStatus = stored.status == "completed" ? .completed : .stopped(ReviewStopReason(rawValue: String(stored.status.dropFirst("stopped:".count))) ?? .cancelled)
        return Display(scope: scope, completedAt: stored.completedAt, status: status, isComplete: stored.coverage == "complete",
                       coveredFolders: 0, uncovered: [], limitations: stored.limitations,
                       items: items.map { item(from: $0, now: now) })
    }

    /// An item is Partial only when its own size is a lower bound: the walker
    /// keeps an object only once it has measured all of it, so an interrupted
    /// review is partial as a whole while each listed size is whole.
    static func item(from ranked: RankedReviewItem, now: Date) -> Item {
        let object = ranked.object
        var keep: [String] = []
        if let idle = ranked.projectIdleDays, idle < 7, object.rule != .catalog {
            keep.append("Its project changed \(idle < 1 ? "today" : "\(Int(idle)) days ago"); it may be in use.")
        }
        if object.recreateClass == .expensive { keep.append("It is expensive to recreate.") }
        if !ranked.rebuildCommandKnown { keep.append("No rebuild command is known for it.") }
        if object.unreadableDirectories > 0 { keep.append("Part of it could not be read, so its size is a lower bound.") }
        keep.append("Review before removing anything; Disk Steward never deletes.")
        let why = Array(ranked.reasons.dropFirst())
        let evidence: Evidence = object.unreadableDirectories > 0 ? .partial : (now.timeIntervalSince(ranked.verifiedAt) < 300 ? .verifiedNow : .stale)
        return Item(rank: ranked.rank, name: URL(fileURLWithPath: object.path).lastPathComponent, path: object.path,
                    group: groupName(path: object.path, project: ranked.projectPath, catalog: object.rule == .catalog),
                    allocatedBytes: object.allocatedBytes, recreateClass: object.recreateClass.rawValue,
                    origin: ranked.reasons.first ?? object.reason, whyDisposable: why, reasonsToKeep: keep,
                    rebuildCommand: ranked.rebuildCommand, rebuildCommandKnown: ranked.rebuildCommandKnown,
                    cleanupCommand: ranked.cleanupCommand, verifiedAt: ranked.verifiedAt, evidence: evidence)
    }

    static func item(from stored: StoredReviewItem, now: Date) -> Item {
        var status = stat()
        let present = lstat(stored.path, &status) == 0
        let lowerBound = ReviewRanking.sizeIsLowerBound(reasons: stored.detail.reasons)
        let evidence: Evidence = !present ? .unknown : lowerBound ? .partial : (now.timeIntervalSince(stored.verifiedAt) < 300 ? .verifiedNow : .stale)
        var keep = stored.recreateClass == RecreateClass.expensive.rawValue ? ["It is expensive to recreate."] : []
        if !stored.detail.known { keep.append("No rebuild command is known for it.") }
        if !present { keep.append("It was not found at the last check.") }
        if lowerBound { keep.append("Part of it could not be read, so its size is a lower bound.") }
        keep.append("Review before removing anything; Disk Steward never deletes.")
        return Item(rank: stored.rank, name: URL(fileURLWithPath: stored.path).lastPathComponent, path: stored.path,
                    group: groupName(path: stored.path, project: nil, catalog: stored.detail.cleanup != nil),
                    allocatedBytes: stored.allocatedBytes, recreateClass: stored.recreateClass,
                    origin: stored.detail.reasons.first ?? "", whyDisposable: Array(stored.detail.reasons.dropFirst()), reasonsToKeep: keep,
                    rebuildCommand: stored.detail.command, rebuildCommandKnown: stored.detail.known, cleanupCommand: stored.detail.cleanup,
                    verifiedAt: stored.verifiedAt, evidence: evidence)
    }

    static func groupName(path: String, project: String?, catalog: Bool) -> String {
        if catalog { return "Tool caches" }
        let folder = project ?? URL(fileURLWithPath: path).deletingLastPathComponent().path
        return (folder as NSString).abbreviatingWithTildeInPath
    }
}

/// A weak reference the review's progress callback can carry across threads.
private final class WeakModel: @unchecked Sendable {
    weak var model: ReviewWindowModel?
    init(_ model: ReviewWindowModel) { self.model = model }
}
