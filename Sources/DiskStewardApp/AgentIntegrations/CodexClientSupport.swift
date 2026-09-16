import Foundation

struct SystemAgentDetectionEnvironment: AgentDetectionEnvironment {
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func executableURL(named name: String) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let boundedDirectories = pathDirectories + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            homeDirectory.appending(path: ".local/bin").path,
        ]
        var seen = Set<String>()
        for directory in boundedDirectories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    func applicationExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

actor FoundationAgentCommandRunner: AgentCommandRunning {
    func run(_ command: AgentCommand) async throws -> AgentCommandResult {
        try Task.checkCancellation()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try process.run()
            return try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(returning: AgentCommandResult(
                        exitCode: process.terminationStatus,
                        standardOutput: output,
                        standardError: error
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

@MainActor
class CodexCLIIntegrationAdapter: AgentIntegrationAdapting {
    struct ClientCommands: Sendable {
        let get: @Sendable (String) -> [String]
        let add: @Sendable (String, URL) -> [String]
        let remove: @Sendable (String) -> [String]
        let parseDefinition: @Sendable (String) -> AgentIntegrationDefinition?
    }

    let descriptor: AgentClientDescriptor
    let executableURL: URL
    let helperURL: URL

    private let commands: ClientCommands
    private let runner: any AgentCommandRunning
    private let receiptStore: AgentIntegrationReceiptStore
    private let fileManager: FileManager
    private let serverName: String

    init(
        descriptor: AgentClientDescriptor = AgentClientDescriptor.supported.first { $0.id == .codex }!,
        executableURL: URL,
        helperURL: URL,
        receiptStore: AgentIntegrationReceiptStore,
        runner: any AgentCommandRunning = FoundationAgentCommandRunner(),
        fileManager: FileManager = .default,
        serverName: String = "disk-steward",
        commands: ClientCommands = .codex
    ) {
        self.descriptor = descriptor
        self.executableURL = executableURL
        self.helperURL = helperURL.standardizedFileURL
        self.receiptStore = receiptStore
        self.runner = runner
        self.fileManager = fileManager
        self.serverName = serverName
        self.commands = commands
    }

    func inspect() async -> AgentIntegrationSnapshot {
        let presence: AgentClientPresence = fileManager.isExecutableFile(atPath: executableURL.path)
            ? .detected(location: executableURL.path)
            : .notDetected
        let receipt: AgentIntegrationReceipt?
        do {
            receipt = try receiptStore.receipt(for: descriptor.id)
        } catch {
            return .derive(
                descriptor: descriptor,
                presence: presence,
                inspection: .unavailable(reason: "Integration receipt cannot be read: \(error.localizedDescription)")
            )
        }

        guard case .detected = presence else {
            return .derive(descriptor: descriptor, presence: presence, inspection: receipt.map { .owned(receipt: $0) } ?? .missing)
        }

        do {
            let command = AgentCommand(executableURL: executableURL, arguments: commands.get(serverName))
            let result = try await runner.run(command)
            if result.exitCode != 0 {
                if Self.isMissingServerOutput(result.combinedOutput) {
                    return .derive(descriptor: descriptor, presence: presence, inspection: .missing)
                }
                return .derive(
                    descriptor: descriptor,
                    presence: presence,
                    inspection: .unavailable(reason: Self.failureMessage(result, command: command))
                )
            }
            guard let definition = commands.parseDefinition(result.standardOutput) else {
                return .derive(
                    descriptor: descriptor,
                    presence: presence,
                    inspection: .malformed(reason: "\(descriptor.displayName) returned a configuration Disk Steward could not understand.")
                )
            }
            switch AgentIntegrationOwnership.resolve(current: definition, receipt: receipt) {
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
        } catch is CancellationError {
            return .derive(descriptor: descriptor, presence: presence, inspection: .unavailable(reason: AgentIntegrationCommandError.cancelled.localizedDescription))
        } catch {
            return .derive(descriptor: descriptor, presence: presence, inspection: .unavailable(reason: error.localizedDescription))
        }
    }

    func perform(_ action: AgentIntegrationAction) async -> AgentIntegrationOperationResult {
        if Task.isCancelled {
            let snapshot = await inspect()
            return .init(clientID: descriptor.id, action: action, outcome: .failed, message: AgentIntegrationCommandError.cancelled.localizedDescription, snapshot: snapshot)
        }

        switch action {
        case .setup:
            return await setup(action: action, replacingOwnedConfiguration: false)
        case .repair:
            return await setup(action: action, replacingOwnedConfiguration: true)
        case .verify:
            return await verify()
        case .remove:
            return await remove()
        }
    }

    private func setup(action: AgentIntegrationAction, replacingOwnedConfiguration: Bool) async -> AgentIntegrationOperationResult {
        let before = await inspect()
        guard case .detected = before.presence else {
            return result(action, .failed, "\(descriptor.displayName) is not installed.", before)
        }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            let broken = AgentIntegrationSnapshot.derive(
                descriptor: descriptor,
                presence: before.presence,
                inspection: .malformed(reason: "The bundled MCP helper is missing at \(helperURL.path). Reinstall Disk Steward.")
            )
            return result(action, .failed, broken.statusDetail, broken)
        }
        if before.state == .conflict {
            return result(action, .failed, "Disk Steward will not overwrite an entry it does not own.", before)
        }
        if before.state == .configured || before.state == .verified, !replacingOwnedConfiguration {
            return result(action, .unchanged, "Disk Steward is already configured for \(descriptor.displayName).", before)
        }

        do {
            if replacingOwnedConfiguration,
               case .owned = before.inspection
            {
                let removeCommand = AgentCommand(executableURL: executableURL, arguments: commands.remove(serverName))
                _ = try (await runner.run(removeCommand)).requireSuccess(command: removeCommand)
            }
            let addCommand = AgentCommand(executableURL: executableURL, arguments: commands.add(serverName, helperURL))
            _ = try (await runner.run(addCommand)).requireSuccess(command: addCommand)
            let receipt = AgentIntegrationReceipt(
                clientID: descriptor.id,
                serverName: serverName,
                definition: .init(command: helperURL.path),
                lastResult: action == .repair ? "repaired" : "configured"
            )
            try receiptStore.upsert(receipt)
            let after = AgentIntegrationSnapshot.derive(
                descriptor: descriptor,
                presence: before.presence,
                inspection: .owned(receipt: receipt)
            )
            return result(action, .changed, "Configured \(descriptor.displayName).", after)
        } catch {
            let after = await inspect()
            return result(action, .failed, error.localizedDescription, after)
        }
    }

    private func verify() async -> AgentIntegrationOperationResult {
        let before = await inspect()
        guard case let .owned(receipt) = before.inspection else {
            return result(.verify, .failed, before.state == .conflict ? "Resolve the existing configuration conflict first." : "Set up \(descriptor.displayName) first.", before)
        }
        do {
            let selfCheck = AgentCommand(executableURL: helperURL, arguments: ["--self-check"])
            _ = try (await runner.run(selfCheck)).requireSuccess(command: selfCheck)
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
            let snapshot = AgentIntegrationSnapshot.derive(
                descriptor: descriptor,
                presence: before.presence,
                inspection: .owned(receipt: receipt),
                verification: .failed(reason: error.localizedDescription)
            )
            return result(.verify, .failed, error.localizedDescription, snapshot)
        }
    }

    private func remove() async -> AgentIntegrationOperationResult {
        let before = await inspect()
        switch before.inspection {
        case .external:
            return result(.remove, .failed, "Disk Steward will not remove an entry it does not own.", before)
        case .missing:
            do { try receiptStore.remove(clientID: descriptor.id) } catch {
                return result(.remove, .failed, error.localizedDescription, before)
            }
            return result(.remove, .unchanged, "No Disk Steward configuration was present.", before)
        case .owned, .approvalPending:
            break
        case let .malformed(reason), let .unavailable(reason):
            return result(.remove, .failed, reason, before)
        }

        do {
            let command = AgentCommand(executableURL: executableURL, arguments: commands.remove(serverName))
            _ = try (await runner.run(command)).requireSuccess(command: command)
            try receiptStore.remove(clientID: descriptor.id)
            let after = AgentIntegrationSnapshot.derive(descriptor: descriptor, presence: before.presence, inspection: .missing)
            return result(.remove, .changed, "Removed only Disk Steward's \(descriptor.displayName) entry.", after)
        } catch {
            return result(.remove, .failed, error.localizedDescription, await inspect())
        }
    }

    private func result(
        _ action: AgentIntegrationAction,
        _ outcome: AgentIntegrationOperationOutcome,
        _ message: String,
        _ snapshot: AgentIntegrationSnapshot
    ) -> AgentIntegrationOperationResult {
        .init(clientID: descriptor.id, action: action, outcome: outcome, message: message, snapshot: snapshot)
    }

    private static func isMissingServerOutput(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("not found") || lower.contains("no mcp server") || lower.contains("does not exist")
    }

    private static func failureMessage(_ result: AgentCommandResult, command: AgentCommand) -> String {
        (try? result.requireSuccess(command: command)) == nil
            ? (AgentIntegrationCommandError.exited(
                executable: command.executableURL.path,
                code: result.exitCode,
                message: result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            ).localizedDescription)
            : "Unknown client command failure."
    }
}

extension CodexCLIIntegrationAdapter.ClientCommands {
    static let codex = CodexCLIIntegrationAdapter.ClientCommands(
        get: { ["mcp", "get", $0, "--json"] },
        add: { name, helper in ["mcp", "add", name, "--", helper.path] },
        remove: { ["mcp", "remove", $0] },
        parseDefinition: CodexCLIIntegrationAdapter.parseCodexDefinition
    )
}

extension CodexCLIIntegrationAdapter {
    nonisolated static func parseCodexDefinition(_ output: String) -> AgentIntegrationDefinition? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return findDefinition(in: object)
    }

    nonisolated static func findDefinition(in value: Any) -> AgentIntegrationDefinition? {
        if let dictionary = value as? [String: Any] {
            if let command = dictionary["command"] as? String {
                let arguments = dictionary["args"] as? [String] ?? []
                return AgentIntegrationDefinition(command: command, arguments: arguments)
            }
            for nested in dictionary.values {
                if let definition = findDefinition(in: nested) { return definition }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let definition = findDefinition(in: nested) { return definition }
            }
        }
        return nil
    }
}
