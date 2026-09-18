import AppKit
import Foundation
import Darwin

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
            var receipt = try receiptStore.receipt(for: descriptor.id)
            let current = try readDefinition()
            if let pending = receipt, pending.lastResult == "approval-pending", current == pending.definition {
                let approved = AgentIntegrationReceipt(clientID: pending.clientID, serverName: pending.serverName,
                    definition: pending.definition, installedAt: pending.installedAt, helperIdentity: pending.helperIdentity)
                try receiptStore.upsert(approved)
                receipt = approved
            }
            if current == nil, let receipt, receipt.lastResult == "approval-pending" {
                return .derive(descriptor: descriptor, presence: presence, inspection: .approvalPending(receipt: receipt))
            }
            switch AgentIntegrationOwnership.resolve(current: current, receipt: receipt) {
            case .missing:
                return .derive(descriptor: descriptor, presence: presence, inspection: .missing)
            case let .owned(receipt):
                let expected = AgentIntegrationDefinition(command: helperURL.path)
                guard receipt.definition == expected,
                      receipt.helperIdentity != nil,
                      receipt.helperIdentity == PrivateIntegrationFile.executableIdentity(helperURL),
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
        switch before.inspection {
        case .malformed, .unavailable: return result(action, .failed, before.statusDetail, before)
        default: break
        }
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
                let receipt = AgentIntegrationReceipt(clientID: descriptor.id, definition: definition,
                    helperIdentity: PrivateIntegrationFile.executableIdentity(helperURL))
                let mutation = try writeDefinition(definition)
                do { try receiptStore.upsert(receipt) }
                catch {
                    try restore(mutation)
                    throw error
                }
                let snapshot = AgentIntegrationSnapshot.derive(
                    descriptor: descriptor,
                    presence: before.presence,
                    inspection: .owned(receipt: receipt)
                )
                return result(action, .changed, "Configured \(descriptor.displayName). Restart it if it is already open.", snapshot)
            case let .clientHandoff(makeURL):
                guard let url = makeURL(serverName, definition) else {
                    return result(action, .failed, "Could not open the \(descriptor.displayName) installation prompt.", before)
                }
                let prior = try receiptStore.receipt(for: descriptor.id)
                let previous: AgentIntegrationReceipt?
                if case let .owned(value) = before.inspection { previous = value } else { previous = nil }
                let receipt = AgentIntegrationReceipt(
                    clientID: descriptor.id,
                    definition: definition,
                    helperIdentity: PrivateIntegrationFile.executableIdentity(helperURL),
                    previousDefinition: previous?.definition,
                    previousHelperIdentity: previous?.helperIdentity,
                    lastResult: "approval-pending"
                )
                // Persist the recovery receipt before handing control to a
                // different process; a disk-write failure must not open it.
                try receiptStore.upsert(receipt)
                guard linkOpener.open(url) else {
                    if let prior { try receiptStore.upsert(prior) }
                    else { try receiptStore.remove(clientID: descriptor.id) }
                    return result(action, .failed, "Could not open the \(descriptor.displayName) installation prompt.", before)
                }
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
        guard receipt.definition == AgentIntegrationDefinition(command: helperURL.path),
              receipt.helperIdentity != nil,
              receipt.helperIdentity == PrivateIntegrationFile.executableIdentity(helperURL),
              fileManager.isExecutableFile(atPath: helperURL.path) else {
            return result(.verify, .failed, "The configured helper differs from this build or is missing. Repair before verifying.", before)
        }
        do {
            let command = AgentCommand(executableURL: helperURL, arguments: ["--self-check"])
            _ = try (await runner.run(command)).requireSuccess(command: command)
            guard try readDefinition() == receipt.definition,
                  receipt.helperIdentity == PrivateIntegrationFile.executableIdentity(helperURL),
                  AgentIntegrationOwnership.resolve(current: receipt.definition,
                    receipt: try receiptStore.receipt(for: descriptor.id)) == .owned(receipt) else {
                return result(.verify, .failed, "Configuration changed during verification. Rescan before retrying.", await inspect())
            }
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
            return result(.verify, .unchanged, "The configured helper connected to Disk Steward. Restart \(descriptor.displayName) to load this configuration; evidence freshness is reported separately.", snapshot)
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
                let mutation = try removeDefinition()
                do { try receiptStore.remove(clientID: descriptor.id) }
                catch {
                    try restore(mutation)
                    throw error
                }
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
        guard let data = try configurationBytes() else { return [:] }
        return try parseDocument(data)
    }

    private func configurationBytes() throws -> Data? {
        try PrivateIntegrationFile.read(configurationURL)
    }

    private func parseDocument(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard object[rootKey] == nil || object[rootKey] is [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return object
    }

    private func readDefinition() throws -> AgentIntegrationDefinition? {
        let document = try readDocument()
        return try definition(in: document)
    }

    private func definition(in document: [String: Any]) throws -> AgentIntegrationDefinition? {
        guard let servers = document[rootKey] as? [String: Any], let raw = servers[serverName] else { return nil }
        guard let entry = raw as? [String: Any], let definition = AgentIntegrationDefinition.parse(entry) else { throw CocoaError(.fileReadCorruptFile) }
        return definition
    }

    private struct Mutation { let before: Data?; let after: Data }

    private func writeDefinition(_ definition: AgentIntegrationDefinition) throws -> Mutation {
        let before = try configurationBytes()
        var document = try before.map(parseDocument) ?? [:]
        let current = try self.definition(in: document)
        if let current {
            guard case .owned = AgentIntegrationOwnership.resolve(current: current,
                receipt: try receiptStore.receipt(for: descriptor.id)) else { throw CocoaError(.fileWriteNoPermission) }
        }
        var servers = document[rootKey] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": definition.command, "args": definition.arguments]
        if rootKey == "servers" { entry["type"] = "stdio" }
        servers[serverName] = entry
        document[rootKey] = servers
        return try persist(document, replacing: before)
    }

    private func removeDefinition() throws -> Mutation {
        let before = try configurationBytes()
        var document = try before.map(parseDocument) ?? [:]
        guard let current = try definition(in: document),
              case .owned = AgentIntegrationOwnership.resolve(current: current, receipt: try receiptStore.receipt(for: descriptor.id)),
              var servers = document[rootKey] as? [String: Any] else { throw CocoaError(.fileWriteNoPermission) }
        servers.removeValue(forKey: serverName)
        document[rootKey] = servers
        return try persist(document, replacing: before)
    }

    private func persist(_ document: [String: Any], replacing before: Data?) throws -> Mutation {
        try fileManager.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try configurationBytes() == before else { throw CocoaError(.fileWriteFileExists) }
        if let before {
            let backup = configurationURL.appendingPathExtension("disk-steward-backup-\(UUID().uuidString)")
            let descriptor = Darwin.open(backup.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: before)
            try handle.close()
        }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        guard try configurationBytes() == before else { throw CocoaError(.fileWriteFileExists) }
        try PrivateIntegrationFile.write(data, to: configurationURL)
        return Mutation(before: before, after: data)
    }

    private func restore(_ mutation: Mutation) throws {
        guard try configurationBytes() == mutation.after else { throw CocoaError(.fileWriteFileExists) }
        if let original = mutation.before { try PrivateIntegrationFile.write(original, to: configurationURL) }
        else { try fileManager.removeItem(at: configurationURL) }
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
