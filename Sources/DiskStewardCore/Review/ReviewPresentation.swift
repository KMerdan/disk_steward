import Darwin
import Foundation

/// How fresh and how complete one stored item's evidence is: the same words
/// the review window shows, so the window and agents read the same states.
public enum ReviewItemEvidence: String, Sendable, Equatable {
    case verifiedNow = "Verified now"
    case stale = "Stale"
    case partial = "Partial"
    case unknown = "Unknown"
}

/// TASK-671: one stored review item as every reader presents it. The window
/// and the MCP tools both build from this, so their numbers and states match.
public struct ReviewItemPresentation: Sendable, Equatable {
    /// Checked within this long counts as verified now.
    public static let freshSeconds: TimeInterval = 300

    public let evidence: ReviewItemEvidence
    /// The path still exists.
    public let present: Bool
    /// Folders inside it could not be read, so its size is a lower bound.
    public let lowerBound: Bool
    public let origin: String
    public let whyDisposable: [String]
    public let reasonsToKeep: [String]

    public init(_ stored: StoredReviewItem, now: Date) {
        var status = stat()
        present = lstat(stored.path, &status) == 0
        lowerBound = ReviewRanking.sizeIsLowerBound(reasons: stored.detail.reasons)
        evidence = !present ? .unknown : lowerBound ? .partial
            : (now.timeIntervalSince(stored.verifiedAt) < Self.freshSeconds ? .verifiedNow : .stale)
        var keep = stored.recreateClass == RecreateClass.expensive.rawValue ? ["It is expensive to recreate."] : []
        if !stored.detail.known { keep.append("No rebuild command is known for it.") }
        if !present { keep.append("It was not found at the last check.") }
        if lowerBound { keep.append("Part of it could not be read, so its size is a lower bound.") }
        keep.append("Review before removing anything; Disk Steward never deletes.")
        reasonsToKeep = keep
        origin = stored.detail.reasons.first ?? ""
        // Reviews stored before 1.5.1 also say it can be rebuilt when no
        // rebuild command is known; that claim is dropped when shown.
        let rebuilt = ReviewRanking.recreateSentence(.rebuild)
        whyDisposable = stored.detail.reasons.dropFirst().filter { stored.detail.known || $0 != rebuilt }
    }
}

/// What a stored review says as a whole, as the window states it.
public enum ReviewReportState: String, Sendable, Equatable {
    case completeWithItems = "complete-with-items"
    /// Nothing in the completed scope met review rules; says nothing about the rest of the disk.
    case completeWithZeroItems = "complete-with-zero-items"
    /// Stopped before covering everything: what was not reviewed is unknown, not empty.
    case partial
    /// Ran to the end, but some folders could not be read.
    case finishedWithUnreadable = "finished-with-unreadable"

    public static func of(stopped: Bool, complete: Bool, itemCount: Int) -> ReviewReportState {
        if stopped { return .partial }
        if !complete { return .finishedWithUnreadable }
        return itemCount == 0 ? .completeWithZeroItems : .completeWithItems
    }

    public static func of(_ report: StoredReviewReport, itemCount: Int) -> ReviewReportState {
        of(stopped: report.status != "completed", complete: report.coverage == "complete", itemCount: itemCount)
    }
}

public enum ReviewSummary {
    /// The window's headline: the sum of every listed item's allocated bytes.
    public static func worthReviewingBytes(_ items: [StoredReviewItem]) -> Int64 {
        items.reduce(0) { $0 + $1.allocatedBytes }
    }
}
