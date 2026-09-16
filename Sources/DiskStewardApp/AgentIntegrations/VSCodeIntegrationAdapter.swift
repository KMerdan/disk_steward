import Foundation

@MainActor
final class VSCodeIntegrationAdapter: JSONClientIntegrationAdapter {
    init(
        configurationURL: URL,
        helperURL: URL,
        receiptStore: AgentIntegrationReceiptStore,
        runner: any AgentCommandRunning = FoundationAgentCommandRunner(),
        linkOpener: any AgentIntegrationLinkOpening = WorkspaceAgentIntegrationLinkOpener(),
        fileManager: FileManager = .default
    ) {
        super.init(
            descriptor: AgentClientDescriptor.supported.first { $0.id == .visualStudioCode }!,
            configurationURL: configurationURL,
            rootKey: "servers",
            helperURL: helperURL,
            receiptStore: receiptStore,
            setupMode: .clientHandoff(Self.installURL),
            runner: runner,
            linkOpener: linkOpener,
            fileManager: fileManager
        )
    }

    nonisolated static func installURL(name: String, definition: AgentIntegrationDefinition) -> URL? {
        let object: [String: Any] = [
            "name": name,
            "type": "stdio",
            "command": definition.command,
            "args": definition.arguments,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8),
              let encoded = json.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "vscode:mcp/install?\(encoded)")
    }
}
