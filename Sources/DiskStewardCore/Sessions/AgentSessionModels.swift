import Foundation

public enum AgentClientKind: String, Codable, Sendable {
    case codex
    case claude
    case otherLocal = "other-local"
}

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTime: Date
    public let executablePath: String?

    public init(pid: Int32, startTime: Date, executablePath: String? = nil) {
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
    }

    public static func == (lhs: ProcessIdentity, rhs: ProcessIdentity) -> Bool {
        lhs.pid == rhs.pid && lhs.startTime == rhs.startTime
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(startTime)
    }
}

public enum AgentSessionLifecycle: String, Codable, Sendable {
    case active
    case ended
    case expired
}

public struct SessionAuthenticationSummary: Codable, Equatable, Sendable {
    public let transport: String
    public let socketMode: UInt16
    public let peerUIDVerified: Bool
    public let challengeDigest: String
    public let secretPersisted: Bool

    public init(challengeDigest: String) {
        transport = "unix-domain-socket"
        socketMode = 0o600
        peerUIDVerified = true
        self.challengeDigest = challengeDigest
        secretPersisted = false
    }
}

public struct AgentSessionRegistration: Codable, Equatable, Sendable {
    public let registrationID: UUID
    public let client: AgentClientKind
    public let sessionID: String
    public let process: ProcessIdentity
    public let workspaceRoots: [String]
    public let registeredAt: Date
    public let lastHeartbeatAt: Date
    public let expiresAt: Date
    public let endedAt: Date?
    public let lifecycle: AgentSessionLifecycle
    public let authentication: SessionAuthenticationSummary
    public let taskContext: String?

    public init(
        registrationID: UUID,
        client: AgentClientKind,
        sessionID: String,
        process: ProcessIdentity,
        workspaceRoots: [String],
        registeredAt: Date,
        expiresAt: Date,
        endedAt: Date?,
        lifecycle: AgentSessionLifecycle,
        authentication: SessionAuthenticationSummary,
        lastHeartbeatAt: Date? = nil,
        taskContext: String? = nil
    ) {
        self.registrationID = registrationID
        self.client = client
        self.sessionID = sessionID
        self.process = process
        self.workspaceRoots = workspaceRoots
        self.registeredAt = registeredAt
        self.lastHeartbeatAt = lastHeartbeatAt ?? registeredAt
        self.expiresAt = expiresAt
        self.endedAt = endedAt
        self.lifecycle = lifecycle
        self.authentication = authentication
        self.taskContext = taskContext
    }

    public func covers(_ date: Date) -> Bool {
        registeredAt <= date && date <= expiresAt && (endedAt == nil || date <= endedAt!)
    }
}

public struct SessionRegistrationRequest: Equatable, Sendable {
    public let registrationID: UUID
    public let client: AgentClientKind
    public let sessionID: String
    public let process: ProcessIdentity
    public let workspaceRoots: [String]
    public let registeredAt: Date
    public let expiresAt: Date
    public let taskContext: String?

    public init(
        registrationID: UUID = UUID(),
        client: AgentClientKind,
        sessionID: String,
        process: ProcessIdentity,
        workspaceRoots: [String],
        registeredAt: Date,
        expiresAt: Date,
        taskContext: String? = nil
    ) {
        self.registrationID = registrationID
        self.client = client
        self.sessionID = sessionID
        self.process = process
        self.workspaceRoots = workspaceRoots
        self.registeredAt = registeredAt
        self.expiresAt = expiresAt
        self.taskContext = taskContext
    }
}

public struct SessionAuthenticationProof: Equatable, Sendable {
    public let peerUID: uid_t
    public let socketMode: UInt16
    public let challengeDigest: String

    public init(peerUID: uid_t, socketMode: UInt16, challengeDigest: String) {
        self.peerUID = peerUID
        self.socketMode = socketMode
        self.challengeDigest = challengeDigest
    }
}

public enum SessionRegistryError: Error, Equatable, LocalizedError {
    case unauthenticated
    case invalidRequest(String)
    case duplicateSession
    case processAlreadyRegistered
    case notFound
    case staleRegistration

    public var errorDescription: String? {
        switch self {
        case .unauthenticated:
            return "The local session proof did not match the private Disk Steward socket."
        case let .invalidRequest(reason):
            return "Invalid session registration: \(reason)"
        case .duplicateSession:
            return "That agent session is already active."
        case .processAlreadyRegistered:
            return "That process identity is already registered to another active session."
        case .notFound:
            return "The agent session registration was not found."
        case .staleRegistration:
            return "The agent session registration is no longer active."
        }
    }
}
