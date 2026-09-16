import AppKit
import Foundation

@MainActor
protocol AgentIntegrationLinkOpening: AnyObject {
    func open(_ url: URL) -> Bool
}

@MainActor
final class WorkspaceAgentIntegrationLinkOpener: AgentIntegrationLinkOpening {
    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

enum JSONClientSetupMode: Sendable {
    case direct
    case clientHandoff(@Sendable (_ name: String, _ definition: AgentIntegrationDefinition) -> URL?)
}

@MainActor
class JSONClientIntegrationAdapter: AgentIntegrationAdapting {
    let descriptor: AgentClientDescriptor
    let configurationURL: URL
    let helperURL: URL

    private let rootKey: String
    private let serverName: String
    private let setupMode: JSONClientSetupMode
    private let receiptStore: AgentIntegrationReceiptStore
    private let runner: any AgentCommandRunning
    private let linkOpener: any AgentIntegrationLinkOpening
    private let fileManager: FileManager

    init(
        descriptor: AgentClientDescriptor,
        configurationURL: URL,
        rootKey: String,
        helperURL: URL,
        receiptStore: AgentIntegrationReceiptStore,
        setupMode: JSONClientSetupMode,
        runner: any AgentCommandRunning = FoundationAgentCommandRunner(),
        linkOpener: any AgentIntegrationLinkOpening = WorkspaceAgentIntegrationLinkOpener(),
        fileManager: FileManager = .default,
        serverName: String = "disk-steward"
    ) {
        self.descriptor = descriptor
        self.configurationURL = configurationURL.standardizedFileURL
        self.rootKey = rootKey
        self.helperURL = helperURL.standardizedFileURL
        self.receiptStore = receiptStore
        self.setupMode = setupMode
        self.runner = runner
        self.linkOpener = linkOpener
        self.fileManager = fileManager
        self.serverName = serverName
    }

    func inspect() async -> AgentIntegrationSnapshot {
        let presence: AgentClientPresence = .detected(location: configurationURL.path)
        do {
            let receipt = try receiptStore.receipt(for: descriptor.id)
            let current = try readDefinition()
            if current == nil, let receipt, receipt.lastResult == "approval-pending" {
                return .derive(descriptor: descriptor, presence: presence, inspection: .approvalPending(receipt: receipt))
            }
            switch AgentIntegrationOwnership.resolve(current: current, receipt: receipt) {
            case .missing:
                return .derive(descriptor: descriptor, presence: presence, inspection: .missing)
            case let .owned(receipt):
                let expected = AgentIntegrationDefinition(command: helperURL.path)
                guard receipt.definition == expected,
                      fileManager.isExecutableFile(atPath: helperURL.path)
                else {
                    return .derive(
                        descriptor: descriptor,
                        presence: presence,
                        inspection: .owned(receipt: receipt),
                        verification: .failed(reason: "The bundled helper path changed or is missing. Use Repair to update \(descriptor.displayName).")
                    )
                }
                return .derive(descriptor: descriptor, presence: presence, inspection: .owned(receipt: receipt))
            case let .external(definition), let .conflict(_, definition):
                return .derive(descriptor: descriptor, presence: presence, inspection: .external(definition: definition))
            }
        } catch {
            return .derive(
                descriptor: descriptor,
                presence: presence,
                inspection: .malformed(reason: "Cannot safely read \(descriptor.displayName) configuration: \(error.localizedDescription)")
            )
        }
    }

    func perform(_ action: AgentIntegrationAction) async -> AgentIntegrationOperationResult {
        switch action {
        case .setup: return await setup(action: .setup)
        case .repair: return await setup(action: .repair)
        case .verify: return await verify()
        case .remove: return await remove()
        }
    }

    private func setup(action: AgentIntegrationAction) async -> AgentIntegrationOperationResult {
        let before = await inspect()
        if before.state == .conflict {
            return result(action, .failed, "Disk Steward will not overwrite an existing entry it does not own.", before)
        }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            return result(action, .failed, "The bundled MCP helper is missing at \(helperURL.path). Reinstall Disk Steward.", before)
        }
        let definition = AgentIntegrationDefinition(command: helperURL.path)
        if before.state == .configured || before.state == .verified, action == .setup {
            return result(action, .unchanged, "Disk Steward is already configured for \(descriptor.displayName).", before)
        }

        do {
            switch setupMode {
            case .direct:
                try writeDefinition(definition)
                let receipt = AgentIntegrationReceipt(clientID: descriptor.id, definition: definition)
                try receiptStore.upsert(receipt)
                let snapshot = AgentIntegrationSnapshot.derive(
                    descriptor: descriptor,
                    presence: before.presence,
                    inspection: .owned(receipt: receipt)
                )
                return result(action, .changed, "Configured \(descriptor.displayName). Restart it if it is already open.", snapshot)
            case let .clientHandoff(makeURL):
                guard let url = makeURL(serverName, definition), linkOpener.open(url) else {
                    return result(action, .failed, "Could not open the \(descriptor.displayName) installation prompt.", before)
                }
                let receipt = AgentIntegrationReceipt(
                    clientID: descriptor.id,
                    definition: definition,
                    lastResult: "approval-pending"
                )
                try receiptStore.upsert(receipt)
                let snapshot = AgentIntegrationSnapshot.derive(
                    descriptor: descriptor,
                    presence: before.presence,
                    inspection: .approvalPending(receipt: receipt)
                )
                return result(action, .approvalRequired, "Approve Disk Steward in \(descriptor.displayName), then press Rescan.", snapshot)
            }
        } catch {
            return result(action, .failed, error.localizedDescription, await inspect())
        }
    }

    private func verify() async -> AgentIntegrationOperationResult {
        let before = await inspect()
        guard case let .owned(receipt) = before.inspection else {
            let message = before.state == .approvalPending
                ? "Finish approval in \(descriptor.displayName), then rescan."
                : "Set up \(descriptor.displayName) before testing it."
            return result(.verify, .failed, message, before)
        }
        do {
            let command = AgentCommand(executableURL: helperURL, arguments: ["--self-check"])
            _ = try (await runner.run(command)).requireSuccess(command: command)
            var verified = receipt
            verified.lastVerifiedAt = Date()
            verified.lastResult = "verified"
            try receiptStore.upsert(verified)
            let snapshot = AgentIntegrationSnapshot.derive(
                descriptor: descriptor,
                presence: before.presence,
                inspection: .owned(receipt: verified),
                verification: .passed(at: verified.lastVerifiedAt!)
            )
            return result(.verify, .unchanged, "Verified \(descriptor.displayName) and the bundled helper.", snapshot)
        } catch {
            return result(.verify, .failed, error.localizedDescription, before)
        }
    }

    private func remove() async -> AgentIntegrationOperationResult {
        let before = await inspect()
        if before.state == .conflict {
            return result(.remove, .failed, "Disk Steward will not remove an entry it does not own.", before)
        }
        do {
            switch before.inspection {
            case .owned:
                try removeDefinition()
                try receiptStore.remove(clientID: descriptor.id)
                let snapshot = AgentIntegrationSnapshot.derive(descriptor: descriptor, presence: before.presence, inspection: .missing)
                return result(.remove, .changed, "Removed only Disk Steward's \(descriptor.displayName) entry.", snapshot)
            case .approvalPending, .missing:
                try receiptStore.remove(clientID: descriptor.id)
                let snapshot = AgentIntegrationSnapshot.derive(descriptor: descriptor, presence: before.presence, inspection: .missing)
                return result(.remove, .unchanged, "Cleared Disk Steward's pending setup record; no approved entry was found.", snapshot)
            case .external, .malformed, .unavailable:
                return result(.remove, .failed, before.statusDetail, before)
            }
        } catch {
            return result(.remove, .failed, error.localizedDescription, before)
        }
    }

    private func readDocument() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: configurationURL.path) else { return [:] }
        let data = try Data(contentsOf: configurationURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    private func readDefinition() throws -> AgentIntegrationDefinition? {
        let document = try readDocument()
        guard let servers = document[rootKey] as? [String: Any],
              let entry = servers[serverName] as? [String: Any]
        else { return nil }
        guard let command = entry["command"] as? String else { throw CocoaError(.fileReadCorruptFile) }
        let arguments = entry["args"] as? [String] ?? []
        return AgentIntegrationDefinition(command: command, arguments: arguments)
    }

    private func writeDefinition(_ definition: AgentIntegrationDefinition) throws {
        var document = try readDocument()
        var servers = document[rootKey] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": definition.command, "args": definition.arguments]
        if rootKey == "servers" { entry["type"] = "stdio" }
        servers[serverName] = entry
        document[rootKey] = servers
        try persist(document)
    }

    private func removeDefinition() throws {
        var document = try readDocument()
        guard var servers = document[rootKey] as? [String: Any] else { return }
        servers.removeValue(forKey: serverName)
        document[rootKey] = servers
        try persist(document)
    }

    private func persist(_ document: [String: Any]) throws {
        try fileManager.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: configurationURL.path) {
            let backup = configurationURL.appendingPathExtension("disk-steward-backup")
            if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
            try fileManager.copyItem(at: configurationURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configurationURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }

    private func result(
        _ action: AgentIntegrationAction,
        _ outcome: AgentIntegrationOperationOutcome,
        _ message: String,
        _ snapshot: AgentIntegrationSnapshot
    ) -> AgentIntegrationOperationResult {
        .init(clientID: descriptor.id, action: action, outcome: outcome, message: message, snapshot: snapshot)
    }
}

@MainActor
final class CursorIntegrationAdapter: JSONClientIntegrationAdapter {
    init(
        configurationURL: URL,
        helperURL: URL,
        receiptStore: AgentIntegrationReceiptStore,
        runner: any AgentCommandRunning = FoundationAgentCommandRunner(),
        linkOpener: any AgentIntegrationLinkOpening = WorkspaceAgentIntegrationLinkOpener(),
        fileManager: FileManager = .default
    ) {
        super.init(
            descriptor: AgentClientDescriptor.supported.first { $0.id == .cursor }!,
            configurationURL: configurationURL,
            rootKey: "mcpServers",
            helperURL: helperURL,
            receiptStore: receiptStore,
            setupMode: .clientHandoff(Self.installURL),
            runner: runner,
            linkOpener: linkOpener,
            fileManager: fileManager
        )
    }

    nonisolated static func installURL(name: String, definition: AgentIntegrationDefinition) -> URL? {
        let object: [String: Any] = ["command": definition.command, "args": definition.arguments]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        let encoded = data.base64EncodedString()
        var components = URLComponents()
        components.scheme = "cursor"
        components.host = "anysphere.cursor-deeplink"
        components.path = "/mcp/install"
        components.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "config", value: encoded)]
        return components.url
    }
}
