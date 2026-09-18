import Foundation
import Darwin

struct AgentCommand: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL?

    init(executableURL: URL, arguments: [String], environment: [String: String] = [:], workingDirectoryURL: URL? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
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
    case timedOut
    case outputLimitExceeded
    case commandLimitReached
    case cleanupIncomplete

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
        case .timedOut:
            "The integration command exceeded its time limit."
        case .outputLimitExceeded:
            "The integration command exceeded its output limit."
        case .commandLimitReached:
            "Four integration commands are already running or finishing cleanup. Try again after they finish."
        case .cleanupIncomplete:
            "The integration command did not finish cleanup within its time limit. Disk Steward retains ownership of any still-running command group."
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
    private let beforePersist: () throws -> Void

    init(url: URL, fileManager: FileManager = .default, beforePersist: @escaping () throws -> Void = {}) {
        self.url = url
        self.fileManager = fileManager
        self.beforePersist = beforePersist
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
        guard let data = try PrivateIntegrationFile.read(url) else { return [] }
        let document = try decoder.decode(Document.self, from: data)
        guard document.schemaVersion == AgentIntegrationReceipt.currentSchemaVersion else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported integration receipt version \(document.schemaVersion).",
            ])
        }
        return document.receipts
    }

    private func persist(_ receipts: [AgentIntegrationReceipt]) throws {
        try beforePersist()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(Document(
            schemaVersion: AgentIntegrationReceipt.currentSchemaVersion,
            receipts: receipts
        ))
        try PrivateIntegrationFile.write(data, to: url)
    }
}

// File permissions are set at creation, before the atomic rename. A successful
// rename is the commit point: no later chmod can throw after committing data.
enum PrivateIntegrationFile {
    // Detect normal app updates/replacements without hashing the helper on every
    // Settings refresh. This is a freshness identity, not a signature guarantee.
    static func executableIdentity(_ url: URL) -> String? {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o111 != 0 else { return nil }
        return "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }

    static func read(_ url: URL) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { Darwin.close(fd) }
        var metadata = stat()
        let limit = 4 * 1_024 * 1_024
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_size >= 0, metadata.st_size <= limit else { throw CocoaError(.fileReadNoPermission) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            guard count <= limit - result.count else { throw CocoaError(.fileReadTooLarge) }
            result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, metadata.st_size == after.st_size,
              metadata.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              metadata.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw CocoaError(.fileReadUnknown) }
        return result
    }

    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= 4 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
        let temporary = url.deletingLastPathComponent().appending(path: ".disk-steward-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
