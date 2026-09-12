import CryptoKit
import Foundation

public enum EvidencePathPolicy: String, Codable, Sendable {
    case full
    case basename
    case hashed
}

public struct EvidencePrivacyPolicy: Equatable, Sendable {
    public let pathPolicy: EvidencePathPolicy
    public let excludedRoots: [String]
    public let sensitiveValues: [String]

    public init(
        pathPolicy: EvidencePathPolicy = .full,
        excludedRoots: [String] = [],
        sensitiveValues: [String] = []
    ) {
        self.pathPolicy = pathPolicy
        self.excludedRoots = excludedRoots.map(Self.normalize).sorted()
        self.sensitiveValues = sensitiveValues.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    public func excludes(_ path: String) -> Bool {
        let path = Self.normalize(path)
        return excludedRoots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

public struct PrivacyFilteredMetadata: Codable, Equatable, Sendable {
    public let path: String
    public let command: String?
    public let executable: String?
    public let redactionsApplied: Int

    public init(path: String, command: String?, executable: String?, redactionsApplied: Int) {
        self.path = path
        self.command = command
        self.executable = executable
        self.redactionsApplied = redactionsApplied
    }
}

public enum EvidencePrivacyFilterResult: Equatable, Sendable {
    case excluded(reason: String)
    case included(PrivacyFilteredMetadata)
}

public struct EvidencePrivacyFilter: Sendable {
    public init() {}

    public func filter(path: String, command: String?, executable: String?, policy: EvidencePrivacyPolicy) -> EvidencePrivacyFilterResult {
        guard !policy.excludes(path) else {
            return .excluded(reason: "Path is inside a user-configured excluded root.")
        }
        var count = 0
        let visiblePath: String
        switch policy.pathPolicy {
        case .full:
            visiblePath = redact(path, values: policy.sensitiveValues, count: &count)
        case .basename:
            visiblePath = URL(fileURLWithPath: path).lastPathComponent
        case .hashed:
            visiblePath = "sha256:" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let visibleCommand = command.map { redact($0, values: policy.sensitiveValues, count: &count) }
        let visibleExecutable = executable.map { redact($0, values: policy.sensitiveValues, count: &count) }
        return .included(.init(path: visiblePath, command: visibleCommand, executable: visibleExecutable, redactionsApplied: count))
    }

    private func redact(_ source: String, values: [String], count: inout Int) -> String {
        values.reduce(source) { partial, value in
            let matches = partial.components(separatedBy: value).count - 1
            count += matches
            return partial.replacingOccurrences(of: value, with: "<redacted>")
        }
    }
}

public struct SafeUninstallPlan: Equatable, Sendable {
    public enum EvidenceAction: String, Sendable {
        case preserve
        case exportThenDelete = "export-then-delete"
    }

    public let removeApplication: Bool
    public let deactivateExtension: Bool
    public let removeIntegrationEntries: Bool
    public let evidenceAction: EvidenceAction
    public let requiresExplicitEvidenceConfirmation: Bool

    public init(evidenceAction: EvidenceAction = .preserve) {
        removeApplication = true
        deactivateExtension = true
        removeIntegrationEntries = true
        self.evidenceAction = evidenceAction
        requiresExplicitEvidenceConfirmation = evidenceAction == .exportThenDelete
    }
}
