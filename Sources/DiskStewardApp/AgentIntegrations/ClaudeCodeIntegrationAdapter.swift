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
        var extraLines: [String] = []
        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("command:") {
                command = String(line.dropFirst("command:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("args:") {
                let text = String(line.dropFirst("args:".count)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && text != "[]" { arguments = text.split(separator: " ").map(String.init) }
            } else if ["environment:", "env:", "type: stdio", "scope: user config (available in all your projects)"].contains(line.lowercased()) {
                continue
            } else if line.hasPrefix("Status:") || line.hasPrefix("Issue:") || line.hasPrefix("To remove this server, run:") {
                continue
            } else if !rawLine.hasPrefix(" "), line.hasSuffix(":"), command == nil {
                continue // server-name heading, not a configuration field
            } else if !line.isEmpty {
                // Unknown configuration and non-user scopes are not ours. Do
                // not silently discard a future CLI field during ownership.
                extraLines.append(line)
            }
        }
        guard let command, !command.isEmpty else { return nil }
        var entry: [String: Any] = ["command": command, "args": arguments]
        if !extraLines.isEmpty { entry["client_extra_lines"] = extraLines }
        return AgentIntegrationDefinition.parse(entry)
    }
}
