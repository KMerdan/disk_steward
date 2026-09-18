import Foundation

/// Public read model. No traversal cursors or directory-pass payloads are
/// reachable from this value. Missing historical counters remain unknown.
public struct EvidenceScanGenerationSummary: Equatable, Sendable {
    public let generationID: String
    public let status: String
    public let startedAt: Date
    public let updatedAt: Date
    public let completedAt: Date?
    public let processedEntryCount: Int64
    public let stagedFileCount: Int64
    public let completedRootCount: Int64?
    public let pendingDirectoryCount: Int64?
    public let totalRootCount: Int64?
    public let configuredRoots: [String]
    public let excludedPaths: [String]
    public let publishedCoverage: String?
}

public struct EvidenceScanCoverageSummary: Equatable, Sendable {
    public let activeGeneration: EvidenceScanGenerationSummary?
    public let latestGeneration: EvidenceScanGenerationSummary
    public let lastCompleteGenerationAt: Date?
    public let detailCoverage: String
}

public struct EvidenceLifecycleSummary: Equatable, Sendable {
    public let status: EvidenceLifecycleStatus
    public let scanCoverage: EvidenceScanCoverageSummary?
    public let detailCoverage: String
}

public enum EvidenceLifecycleSummaryError: Error, Equatable, Sendable {
    case budgetExceeded
}
