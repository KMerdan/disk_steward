import AppKit
import Foundation

@MainActor
protocol ManualConfigurationCopying: AnyObject {
    func copy(_ value: String) -> Bool
}

@MainActor
final class SystemManualConfigurationCopier: ManualConfigurationCopying {
    func copy(_ value: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
final class ManualIntegrationAdapter: AgentIntegrationAdapting {
    let descriptor = AgentClientDescriptor.supported.first { $0.id == .manual }!
    private let helperURL: URL
    private let runner: any AgentCommandRunning
    private let copier: any ManualConfigurationCopying

    init(
        helperURL: URL,
        runner: any AgentCommandRunning = FoundationAgentCommandRunner(),
        copier: any ManualConfigurationCopying = SystemManualConfigurationCopier()
    ) {
        self.helperURL = helperURL.standardizedFileURL
        self.runner = runner
        self.copier = copier
    }

    func inspect() async -> AgentIntegrationSnapshot {
        .derive(descriptor: descriptor, presence: .detected(location: nil), inspection: .missing)
    }

    func perform(_ action: AgentIntegrationAction) async -> AgentIntegrationOperationResult {
        let snapshot = await inspect()
        switch action {
        case .setup, .repair:
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                return .init(clientID: .manual, action: action, outcome: .failed, message: "The bundled MCP helper is missing. Reinstall Disk Steward.", snapshot: snapshot)
            }
            do {
                let value = try configuration()
                guard copier.copy(value) else { throw CocoaError(.fileWriteUnknown) }
                return .init(clientID: .manual, action: action, outcome: .unchanged, message: "Copied a standard read-only stdio configuration.", snapshot: snapshot)
            } catch {
                return .init(clientID: .manual, action: action, outcome: .failed, message: error.localizedDescription, snapshot: snapshot)
            }
        case .verify:
            do {
                let command = AgentCommand(executableURL: helperURL, arguments: ["--self-check"])
                _ = try (await runner.run(command)).requireSuccess(command: command)
                return .init(clientID: .manual, action: action, outcome: .unchanged, message: "The helper is ready; verify the pasted entry in your client.", snapshot: snapshot)
            } catch {
                return .init(clientID: .manual, action: action, outcome: .failed, message: error.localizedDescription, snapshot: snapshot)
            }
        case .remove:
            return .init(clientID: .manual, action: action, outcome: .unchanged, message: "Manual configurations are client-owned. Remove the disk-steward entry in that client.", snapshot: snapshot)
        }
    }

    func configuration() throws -> String {
        let object: [String: Any] = [
            "mcpServers": ["disk-steward": ["command": helperURL.path, "args": []]],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return value
    }
}
