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

    init(
        clientID: AgentClientID,
        serverName: String = "disk-steward",
        definition: AgentIntegrationDefinition,
        installedAt: Date = Date(),
        helperIdentity: String? = nil,
        previousDefinition: AgentIntegrationDefinition? = nil,
        previousHelperIdentity: String? = nil,
        lastVerifiedAt: Date? = nil,
        lastResult: String = "configured"
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
    case failed(reason: String)
}

enum AgentIntegrationStateKind: String, Codable, Equatable, Sendable {
    case notDetected
    case available
    case configured
    case approvalPending
    case verified
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
        case .notDetected, .approvalPending, .verified, .conflict, .unavailable:
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
