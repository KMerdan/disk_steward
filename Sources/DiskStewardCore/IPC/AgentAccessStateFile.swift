import Darwin
import Foundation

public struct AgentAccessStateDocument: Codable, Equatable, Sendable {
    public let schema: String
    public let enabled: Bool
    public let updatedAt: Date

    public init(enabled: Bool, updatedAt: Date = Date()) {
        schema = "agent-access-state-v1"
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

public struct AgentAccessStateFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Disk Steward", directoryHint: .isDirectory)
            .appending(path: "agent-access.json")
    }

    public func readEnabled() throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(AgentAccessStateDocument.self, from: Data(contentsOf: url))
        guard document.schema == "agent-access-state-v1" else {
            throw DiskStewardIPCError.insecureSocket("Agent Access state has an unsupported schema.")
        }
        return document.enabled
    }

    public func write(enabled: Bool, at date: Date = Date()) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(parent.path, 0o700) == 0 else {
            throw DiskStewardIPCError.connectionFailed(errno)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(AgentAccessStateDocument(enabled: enabled, updatedAt: date)).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else {
            throw DiskStewardIPCError.connectionFailed(errno)
        }
    }
}
