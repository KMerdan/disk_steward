import Foundation

public struct SnapshotExportManifest: Codable, Equatable, Sendable {
    public struct Producer: Codable, Equatable, Sendable {
        public let name: String
        public let version: String
        public let evidenceSchemaVersion: Int

        enum CodingKeys: String, CodingKey {
            case name
            case version
            case evidenceSchemaVersion = "evidence_schema_version"
        }
    }

    public struct RequestedRange: Codable, Equatable, Sendable {
        public let from: String
        public let through: String
    }

    public struct FileEntry: Codable, Equatable, Sendable {
        public enum Role: String, Codable, Sendable {
            case codexBrief = "codex-brief"
            case snapshot
        }

        public let path: String
        public let role: Role
        public let sha256: String
        public let bytes: Int
    }

    public struct Privacy: Codable, Equatable, Sendable {
        public let containsFileContents: Bool
        public let containsEnvironment: Bool
        public let pathDetail: String

        enum CodingKeys: String, CodingKey {
            case containsFileContents = "contains_file_contents"
            case containsEnvironment = "contains_environment"
            case pathDetail = "path_detail"
        }
    }

    public let schema: String
    public let bundleID: String
    public let createdAt: String
    public let producer: Producer
    public let requestedRange: RequestedRange
    public let files: [FileEntry]
    public let limitations: [String]
    public let privacy: Privacy

    enum CodingKeys: String, CodingKey {
        case schema
        case bundleID = "bundle_id"
        case createdAt = "created_at"
        case producer
        case requestedRange = "requested_range"
        case files
        case limitations
        case privacy
    }
}

public struct SnapshotExportResult: Equatable, Sendable {
    public let bundleURL: URL
    public let manifest: SnapshotExportManifest
}

public enum SnapshotExportError: Error, Equatable, LocalizedError {
    case unsafeBundleIdentifier
    case destinationAlreadyExists

    public var errorDescription: String? {
        switch self {
        case .unsafeBundleIdentifier:
            return "The bundle identifier is not a safe path component."
        case .destinationAlreadyExists:
            return "An export with this bundle identifier already exists."
        }
    }
}
