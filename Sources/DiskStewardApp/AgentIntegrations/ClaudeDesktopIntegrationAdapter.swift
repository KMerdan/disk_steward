import Foundation

@MainActor
final class ClaudeDesktopIntegrationAdapter: JSONClientIntegrationAdapter {
    init(
        configurationURL: URL,
        helperURL: URL,
        receiptStore: AgentIntegrationReceiptStore,
        runner: any AgentCommandRunning = FoundationAgentCommandRunner(),
        fileManager: FileManager = .default
    ) {
        super.init(
            descriptor: AgentClientDescriptor.supported.first { $0.id == .claudeDesktop }!,
            configurationURL: configurationURL,
            rootKey: "mcpServers",
            helperURL: helperURL,
            receiptStore: receiptStore,
            setupMode: .direct,
            runner: runner,
            fileManager: fileManager
        )
    }
}
