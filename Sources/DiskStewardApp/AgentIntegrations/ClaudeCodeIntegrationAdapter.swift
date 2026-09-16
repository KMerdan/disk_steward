import Foundation

@MainActor
final class ClaudeCodeIntegrationAdapter: CodexCLIIntegrationAdapter {
    init(
        executableURL: URL,
        helperURL: URL,
        receiptStore: AgentIntegrationReceiptStore,
        runner: any AgentCommandRunning = FoundationAgentCommandRunner(),
        fileManager: FileManager = .default
    ) {
        super.init(
            descriptor: AgentClientDescriptor.supported.first { $0.id == .claudeCode }!,
            executableURL: executableURL,
            helperURL: helperURL,
            receiptStore: receiptStore,
            runner: runner,
            fileManager: fileManager,
            commands: .claudeCode
        )
    }
}

extension CodexCLIIntegrationAdapter.ClientCommands {
    static let claudeCode = CodexCLIIntegrationAdapter.ClientCommands(
        get: { ["mcp", "get", $0] },
        add: { name, helper in ["mcp", "add", "--scope", "user", name, "--", helper.path] },
        remove: { ["mcp", "remove", "--scope", "user", $0] },
        parseDefinition: ClaudeCodeIntegrationAdapter.parseClaudeDefinition
    )
}

extension ClaudeCodeIntegrationAdapter {
    nonisolated static func parseClaudeDefinition(_ output: String) -> AgentIntegrationDefinition? {
        var command: String?
        var arguments: [String] = []
        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("command:") {
                command = String(line.dropFirst("command:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("args:") {
                let text = String(line.dropFirst("args:".count)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && text != "[]" { arguments = text.split(separator: " ").map(String.init) }
            }
        }
        guard let command, !command.isEmpty else { return nil }
        return AgentIntegrationDefinition(command: command, arguments: arguments)
    }
}
