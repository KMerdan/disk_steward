import Foundation

struct AgentCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    init(executableURL: URL, arguments: [String], environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
    }
}

struct AgentCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String { standardOutput + standardError }

    func requireSuccess(command: AgentCommand) throws -> AgentCommandResult {
        guard exitCode == 0 else {
            throw AgentIntegrationCommandError.exited(
                executable: command.executableURL.path,
                code: exitCode,
                message: combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return self
    }
}

enum AgentIntegrationCommandError: LocalizedError, Equatable {
    case executableNotFound(String)
    case exited(executable: String, code: Int32, message: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(name):
            "The \(name) command was not found. Install the client or use manual setup."
        case let .exited(executable, code, message):
            message.isEmpty
                ? "\(executable) exited with status \(code)."
                : "\(executable) exited with status \(code): \(message)"
        case .cancelled:
            "The integration operation was cancelled."
        }
    }
}

protocol AgentCommandRunning: Sendable {
    func run(_ command: AgentCommand) async throws -> AgentCommandResult
}

protocol AgentDetectionEnvironment: Sendable {
    func executableURL(named name: String) -> URL?
    func applicationExists(at path: String) -> Bool
}

struct KnownAgentClientDetector: Sendable {
    let environment: any AgentDetectionEnvironment

    func detect(_ descriptor: AgentClientDescriptor) -> AgentClientPresence {
        if descriptor.id == .manual {
            return .detected(location: nil)
        }
        for executable in descriptor.executableNames {
            if let url = environment.executableURL(named: executable) {
                return .detected(location: url.path)
            }
        }
        for path in descriptor.applicationPaths where environment.applicationExists(at: path) {
            return .detected(location: path)
        }
        return .notDetected
    }
}

@MainActor
final class AgentIntegrationReceiptStore {
    private struct Document: Codable {
        let schemaVersion: Int
        var receipts: [AgentIntegrationReceipt]
    }

    let url: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func receipt(for clientID: AgentClientID) throws -> AgentIntegrationReceipt? {
        try load().first { $0.clientID == clientID }
    }

    func allReceipts() throws -> [AgentIntegrationReceipt] {
        try load()
    }

    func upsert(_ receipt: AgentIntegrationReceipt) throws {
        var receipts = try load()
        receipts.removeAll { $0.clientID == receipt.clientID }
        receipts.append(receipt)
        receipts.sort { $0.clientID.rawValue < $1.clientID.rawValue }
        try persist(receipts)
    }

    func remove(clientID: AgentClientID) throws {
        var receipts = try load()
        let originalCount = receipts.count
        receipts.removeAll { $0.clientID == clientID }
        guard receipts.count != originalCount else { return }
        try persist(receipts)
    }

    private func load() throws -> [AgentIntegrationReceipt] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
        guard document.schemaVersion == AgentIntegrationReceipt.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported integration receipt version \(document.schemaVersion).",
            ])
        }
        return document.receipts
    }

    private func persist(_ receipts: [AgentIntegrationReceipt]) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(Document(
            schemaVersion: AgentIntegrationReceipt.currentSchemaVersion,
            receipts: receipts
        ))
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
