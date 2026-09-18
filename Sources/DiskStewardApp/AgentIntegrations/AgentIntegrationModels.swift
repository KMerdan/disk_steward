import Foundation

enum AgentClientID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case cursor
    case visualStudioCode = "visual-studio-code"
    case claudeDesktop = "claude-desktop"
    case manual

    var id: String { rawValue }
}

struct AgentClientDescriptor: Equatable, Identifiable, Sendable {
    let id: AgentClientID
    let displayName: String
    let detail: String
    let executableNames: [String]
    let applicationBundleIdentifiers: [String]
    let applicationPaths: [String]
    let supportsAutomaticSetup: Bool

    static let supported: [AgentClientDescriptor] = [
        .init(
            id: .codex,
            displayName: "Codex",
            detail: "Codex app, CLI, and IDE extension share one user configuration.",
            executableNames: ["codex"],
            applicationBundleIdentifiers: ["com.openai.codex"],
            applicationPaths: ["/Applications/Codex.app", "/Applications/ChatGPT.app"],
            supportsAutomaticSetup: true
        ),
        .init(
            id: .claudeCode,
            displayName: "Claude Code",
            detail: "User-scoped Claude Code MCP configuration.",
            executableNames: ["claude"],
            applicationBundleIdentifiers: [],
            applicationPaths: [],
            supportsAutomaticSetup: true
        ),
        .init(
            id: .cursor,
            displayName: "Cursor",
            detail: "Cursor editor and cursor-agent CLI.",
            executableNames: ["cursor", "cursor-agent"],
            applicationBundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            applicationPaths: ["/Applications/Cursor.app"],
            supportsAutomaticSetup: true
        ),
        .init(
            id: .visualStudioCode,
            displayName: "Visual Studio Code",
            detail: "User-profile MCP configuration managed by VS Code.",
            executableNames: ["code"],
            applicationBundleIdentifiers: ["com.microsoft.VSCode"],
            applicationPaths: ["/Applications/Visual Studio Code.app"],
            supportsAutomaticSetup: true
        ),
        .init(
            id: .claudeDesktop,
            displayName: "Claude Desktop",
            detail: "Claude Desktop local MCP configuration.",
            executableNames: [],
            applicationBundleIdentifiers: ["com.anthropic.claudefordesktop"],
            applicationPaths: ["/Applications/Claude.app"],
            supportsAutomaticSetup: true
        ),
        .init(
            id: .manual,
            displayName: "Other MCP Client",
            detail: "Copy a standard read-only stdio configuration.",
            executableNames: [],
            applicationBundleIdentifiers: [],
            applicationPaths: [],
            supportsAutomaticSetup: false
        ),
    ]
}

enum AgentClientPresence: Equatable, Sendable {
    case notDetected
    case detected(location: String?)
    case unavailable(reason: String)
}

struct AgentIntegrationDefinition: Codable, Equatable, Sendable {
    let command: String
    let arguments: [String]
    // Legacy receipts omit this field. Meaningful extra configuration breaks
    // ownership without persisting environment values or other secrets.
    let configurationFingerprint: String?

    init(command: String, arguments: [String] = [], configurationFingerprint: String? = nil) {
        self.command = command
        self.arguments = arguments
        self.configurationFingerprint = configurationFingerprint
    }

    static func parse(_ entry: [String: Any]) -> AgentIntegrationDefinition? {
        guard let command = entry["command"] as? String, !command.isEmpty,
              entry["args"] == nil || entry["args"] is [String] else { return nil }
        var extras = entry
        extras.removeValue(forKey: "command")
        extras.removeValue(forKey: "args")
        if extras["type"] as? String == "stdio" { extras.removeValue(forKey: "type") }
        for key in ["env", "cwd", "env_vars"] {
            if extras[key] is NSNull { extras.removeValue(forKey: key) }
        }
        if let env = extras["env"] as? [String: Any], env.isEmpty { extras.removeValue(forKey: "env") }
        if let env = extras["env_vars"] as? [String], env.isEmpty { extras.removeValue(forKey: "env_vars") }
        let digest = extras.isEmpty ? nil : (try? JSONSerialization.data(withJSONObject: extras, options: [.sortedKeys])).map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        guard extras.isEmpty || digest != nil else { return nil }
        return .init(command: command, arguments: entry["args"] as? [String] ?? [], configurationFingerprint: digest)
    }
}

/// Every configuration mutation either preserves the user's file byte for byte
/// or fails with one of these, naming the file, the backup that holds the
/// pre-mutation bytes, and the recovery step. Nothing is ever partially applied
/// without an explicit, recoverable report.
enum AgentIntegrationMutationError: LocalizedError, Equatable {
    case notOwned(path: String)
    case concurrentEdit(path: String, backup: String?)
    case backupFailed(path: String, reason: String)
    case commitFailed(path: String, backup: String?, reason: String)
    case restoreFailed(path: String, backup: String?, reason: String)
    /// A concurrent writer's file was swapped out and could not be swapped
    /// back; it is preserved at `preserved` and the caller's bytes stand.
    case concurrentEditUndoFailed(path: String, preserved: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .notOwned(path):
            return "Disk Steward will not change an entry it does not own in \(path). Remove or rename that entry, then rescan; nothing was changed."
        case let .concurrentEdit(path, backup):
            return "\(path) changed while Disk Steward was editing it, so the edit was abandoned and the file was left as the other writer saved it. Rescan and retry" + (backup.map { "; the bytes read before the edit are in \($0)." } ?? ".")
        case let .backupFailed(path, reason):
            return "Disk Steward could not write a backup before editing \(path) (\(reason)), so it changed nothing. Free space or fix permissions in \((path as NSString).deletingLastPathComponent), then retry."
        case let .commitFailed(path, backup, reason):
            return "Disk Steward could not save \(path) (\(reason)); the file was left unchanged" + (backup.map { " and its pre-edit bytes are in \($0)" } ?? "") + ". Retry after fixing the folder's permissions or free space."
        case let .restoreFailed(path, backup, reason):
            return "Disk Steward saved \(path) but could not record its receipt and could not restore the file automatically (\(reason))." + (backup.map { " Your previous configuration is preserved in \($0); copy it back or rescan and repair." } ?? " Rescan and repair.")
        case let .concurrentEditUndoFailed(path, preserved, reason):
            return "\(path) was changed by another program while Disk Steward saved it, and Disk Steward could not put that program's version back (\(reason)). Disk Steward's version is now in place; the other program's version is preserved at \(preserved). Merge them by hand, then rescan."
        }
    }
}

struct AgentIntegrationReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let clientID: AgentClientID
    let serverName: String
    let definition: AgentIntegrationDefinition
    let installedAt: Date
    let helperIdentity: String?
    // Client-owned install prompts can be cancelled. Retain the exact prior
    // entry until approval replaces it, so repair never forfeits ownership.
    let previousDefinition: AgentIntegrationDefinition?
    let previousHelperIdentity: String?
    var lastVerifiedAt: Date?
    var lastResult: String
    /// The backup written before the last direct edit of the client file;
    /// legacy receipts omit it. Backups live next to the client file in
    /// `.disk-steward-backups/` and are bounded per file.
    var lastBackupPath: String?

    init(
        clientID: AgentClientID,
        serverName: String = "disk-steward",
        definition: AgentIntegrationDefinition,
        installedAt: Date = Date(),
        helperIdentity: String? = nil,
        previousDefinition: AgentIntegrationDefinition? = nil,
        previousHelperIdentity: String? = nil,
        lastVerifiedAt: Date? = nil,
        lastResult: String = "configured",
        lastBackupPath: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.clientID = clientID
        self.serverName = serverName
        self.definition = definition
        self.installedAt = installedAt
        self.helperIdentity = helperIdentity
        self.previousDefinition = previousDefinition
        self.previousHelperIdentity = previousHelperIdentity
        self.lastVerifiedAt = lastVerifiedAt
        self.lastResult = lastResult
        self.lastBackupPath = lastBackupPath
    }
}

enum AgentConfigurationInspection: Equatable, Sendable {
    case missing
    case owned(receipt: AgentIntegrationReceipt)
    case external(definition: AgentIntegrationDefinition)
    case approvalPending(receipt: AgentIntegrationReceipt)
    case malformed(reason: String)
    case unavailable(reason: String)
}

enum AgentVerification: Equatable, Sendable {
    case notRun
    case passed(at: Date)
    /// The exact configured helper connected, but the evidence it returned is
    /// older than `HelperSelfCheck.staleEvidenceThreshold`, or nothing has been
    /// persisted yet (`evidenceAge == nil`).
    case stale(at: Date, evidenceAge: TimeInterval?)
    case failed(reason: String)
}

enum AgentIntegrationStateKind: String, Codable, Equatable, Sendable {
    case notDetected
    case available
    case configured
    case approvalPending
    case verified
    case stale
    case broken
    case conflict
    case unavailable
}

struct AgentIntegrationSnapshot: Equatable, Identifiable, Sendable {
    let descriptor: AgentClientDescriptor
    let presence: AgentClientPresence
    let inspection: AgentConfigurationInspection
    let verification: AgentVerification
    let state: AgentIntegrationStateKind
    let statusDetail: String

    var id: AgentClientID { descriptor.id }

    var canSelectForSetup: Bool {
        switch state {
        case .available, .configured, .broken:
            true
        case .notDetected, .approvalPending, .verified, .stale, .conflict, .unavailable:
            false
        }
    }

    static func derive(
        descriptor: AgentClientDescriptor,
        presence: AgentClientPresence,
        inspection: AgentConfigurationInspection,
        verification: AgentVerification = .notRun
    ) -> AgentIntegrationSnapshot {
        let state: AgentIntegrationStateKind
        let detail: String

        switch (presence, inspection, verification) {
        case let (.unavailable(reason), _, _), let (_, .unavailable(reason), _):
            state = .unavailable
            detail = reason
        case (.notDetected, .missing, _):
            state = .notDetected
            detail = "Not found on this Mac."
        case (.detected, .missing, _):
            state = .available
            detail = "Detected and ready to set up."
        case let (_, .external(definition), _):
            state = .conflict
            detail = "An existing disk-steward entry is not owned by Disk Steward: \(definition.command)"
        case (_, .approvalPending, _):
            state = .approvalPending
            detail = "Configured; finish approval in \(descriptor.displayName)."
        case let (_, .malformed(reason), _):
            state = .broken
            detail = reason
        case let (_, .owned, .failed(reason)):
            state = .broken
            detail = reason
        case let (_, .owned, .passed(at)):
            state = .verified
            detail = "Verified \(at.formatted(date: .abbreviated, time: .shortened))."
        case let (_, .owned, .stale(at, age)):
            state = .stale
            detail = "Connected \(at.formatted(date: .abbreviated, time: .shortened)), but \(HelperSelfCheck.describeStaleness(age: age)). Monitoring may be paused or the app may have just started."
        case (_, .owned, .notRun):
            state = .configured
            detail = "Configured; verification has not run yet."
        case (.notDetected, _, _):
            state = .unavailable
            detail = "Configuration exists, but the client is not currently installed."
        }

        return AgentIntegrationSnapshot(
            descriptor: descriptor,
            presence: presence,
            inspection: inspection,
            verification: verification,
            state: state,
            statusDetail: detail
        )
    }
}

enum AgentIntegrationAction: String, CaseIterable, Sendable {
    case setup
    case verify
    case repair
    case remove
}

enum AgentIntegrationOperationOutcome: Equatable, Sendable {
    case changed
    case unchanged
    case approvalRequired
    case failed
}

struct AgentIntegrationOperationResult: Equatable, Sendable {
    let clientID: AgentClientID
    let action: AgentIntegrationAction
    let outcome: AgentIntegrationOperationOutcome
    let message: String
    let snapshot: AgentIntegrationSnapshot
}

@MainActor
protocol AgentIntegrationAdapting: AnyObject {
    var descriptor: AgentClientDescriptor { get }
    func inspect() async -> AgentIntegrationSnapshot
    func perform(_ action: AgentIntegrationAction) async -> AgentIntegrationOperationResult
}

enum AgentIntegrationOwnership: Equatable, Sendable {
    case missing
    case owned(AgentIntegrationReceipt)
    case external(AgentIntegrationDefinition)
    case conflict(expected: AgentIntegrationDefinition, actual: AgentIntegrationDefinition)

    static func resolve(
        current: AgentIntegrationDefinition?,
        receipt: AgentIntegrationReceipt?
    ) -> AgentIntegrationOwnership {
        switch (current, receipt) {
        case (nil, _):
            return .missing
        case let (current?, nil):
            return .external(current)
        case let (current?, receipt?) where current == receipt.definition:
            return .owned(receipt)
        case let (current?, receipt?) where receipt.lastResult == "approval-pending" && current == receipt.previousDefinition:
            return .owned(.init(clientID: receipt.clientID, serverName: receipt.serverName,
                definition: current, installedAt: receipt.installedAt,
                helperIdentity: receipt.previousHelperIdentity, lastResult: "approval-pending"))
        case let (current?, receipt?):
            return .conflict(expected: receipt.definition, actual: current)
        }
    }
}
import CryptoKit
import DiskStewardCore
