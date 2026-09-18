import Foundation

/// Process-local receipt/commit ordering. This does not persist receipts: the
/// owner must durably invalidate the affected roots before acknowledging them,
/// and establish reconciliation uncertainty again after an unknown stream gap.
public final class ScanPublicationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = UUID()
    private var pending = false

    public init() {}

    /// Receipt acceptance linearizes here, independently of wall-clock time.
    /// No new permit is available until this exact revision is acknowledged.
    @discardableResult
    public func invalidate() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        revision = UUID()
        pending = true
        return revision
    }

    /// An older persistence completion cannot clear a newer dirty receipt.
    @discardableResult
    public func acknowledge(_ receipt: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == receipt else { return false }
        pending = false
        return true
    }

    public func permit() throws -> ScanPublicationPermit {
        lock.lock()
        defer { lock.unlock() }
        guard !pending else { throw ScanPublicationError.pendingChanges }
        return ScanPublicationPermit(fence: self, revision: revision)
    }

    fileprivate func commit(revision expected: UUID, _ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !pending, revision == expected else { throw ScanPublicationError.superseded }
        // Only the native COMMIT belongs in this critical section, never
        // traversal, reconciliation preparation, or callbacks into the inbox.
        try body()
    }
}

public struct ScanPublicationPermit: Sendable {
    fileprivate let fence: ScanPublicationFence
    fileprivate let revision: UUID

    func validate() throws { try commit {} }

    func commit(_ body: () throws -> Void) throws {
        try fence.commit(revision: revision, body)
    }
}

public enum ScanPublicationError: Error, Equatable, Sendable, LocalizedError {
    case pendingChanges
    case superseded

    public var errorDescription: String? {
        switch self {
        case .pendingChanges: return "File changes are awaiting durable reconciliation."
        case .superseded: return "New file changes superseded this scan before publication."
        }
    }
}
