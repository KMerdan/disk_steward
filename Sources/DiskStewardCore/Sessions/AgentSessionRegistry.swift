import Foundation

public actor AgentSessionRegistry {
    private let expectedPeerUID: uid_t
    private let expectedChallengeDigest: String
    private let maximumLease: TimeInterval
    private let evidenceStore: EvidenceStore?
    private var registrations: [UUID: AgentSessionRegistration] = [:]
    private var loadedPersistedState = false
    private var accessBusy = false
    private var accessWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        expectedPeerUID: uid_t,
        expectedChallengeDigest: String,
        maximumLease: TimeInterval = 24 * 60 * 60,
        evidenceStore: EvidenceStore? = nil
    ) {
        self.expectedPeerUID = expectedPeerUID
        self.expectedChallengeDigest = expectedChallengeDigest
        self.maximumLease = max(60, min(maximumLease, 24 * 60 * 60))
        self.evidenceStore = evidenceStore
    }

    @discardableResult
    public func register(
        _ request: SessionRegistrationRequest,
        proof: SessionAuthenticationProof,
        now: Date = Date()
    ) async throws -> AgentSessionRegistration {
        try authenticate(proof)
        try validate(request, now: now)
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        try await loadIfNeeded()
        _ = try await expireLoadedStale(at: now)

        if registrations.values.contains(where: { $0.sessionID == request.sessionID && $0.lifecycle == .active }) {
            throw SessionRegistryError.duplicateSession
        }
        if registrations.values.contains(where: { $0.process == request.process && $0.lifecycle == .active }) {
            throw SessionRegistryError.processAlreadyRegistered
        }

        let registration = AgentSessionRegistration(
            registrationID: request.registrationID,
            client: request.client,
            sessionID: request.sessionID,
            process: request.process,
            workspaceRoots: normalizedRoots(request.workspaceRoots),
            registeredAt: request.registeredAt,
            expiresAt: request.expiresAt,
            endedAt: nil,
            lifecycle: .active,
            authentication: SessionAuthenticationSummary(challengeDigest: proof.challengeDigest),
            lastHeartbeatAt: request.registeredAt,
            taskContext: request.taskContext
        )
        try await persist(registration)
        registrations[registration.registrationID] = registration
        return registration
    }

    @discardableResult
    public func end(
        registrationID: UUID,
        proof: SessionAuthenticationProof,
        now: Date = Date()
    ) async throws -> AgentSessionRegistration {
        try authenticate(proof)
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        try await loadIfNeeded()
        _ = try await expireLoadedStale(at: now)
        guard let current = registrations[registrationID] else { throw SessionRegistryError.notFound }
        guard current.lifecycle == .active else { throw SessionRegistryError.staleRegistration }

        let ended = AgentSessionRegistration(
            registrationID: current.registrationID,
            client: current.client,
            sessionID: current.sessionID,
            process: current.process,
            workspaceRoots: current.workspaceRoots,
            registeredAt: current.registeredAt,
            expiresAt: current.expiresAt,
            endedAt: now,
            lifecycle: .ended,
            authentication: current.authentication,
            lastHeartbeatAt: current.lastHeartbeatAt,
            taskContext: current.taskContext
        )
        try await persist(ended)
        registrations[registrationID] = ended
        return ended
    }

    @discardableResult
    public func heartbeat(
        registrationID: UUID,
        extendBy: TimeInterval,
        proof: SessionAuthenticationProof,
        now: Date = Date()
    ) async throws -> AgentSessionRegistration {
        try authenticate(proof)
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        try await loadIfNeeded()
        _ = try await expireLoadedStale(at: now)
        guard let current = registrations[registrationID] else { throw SessionRegistryError.notFound }
        guard current.lifecycle == .active else { throw SessionRegistryError.staleRegistration }
        guard now >= current.lastHeartbeatAt else {
            throw SessionRegistryError.invalidRequest("heartbeat time cannot move backward")
        }
        let extensionInterval = min(max(60, extendBy), maximumLease)
        let heartbeat = AgentSessionRegistration(
            registrationID: current.registrationID,
            client: current.client,
            sessionID: current.sessionID,
            process: current.process,
            workspaceRoots: current.workspaceRoots,
            registeredAt: current.registeredAt,
            expiresAt: max(current.expiresAt, now.addingTimeInterval(extensionInterval)),
            endedAt: nil,
            lifecycle: .active,
            authentication: current.authentication,
            lastHeartbeatAt: now,
            taskContext: current.taskContext
        )
        try await persist(heartbeat)
        registrations[registrationID] = heartbeat
        return heartbeat
    }

    public func registration(
        id: UUID,
        proof: SessionAuthenticationProof,
        now: Date = Date()
    ) async throws -> AgentSessionRegistration {
        try authenticate(proof)
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        try await loadIfNeeded()
        _ = try await expireLoadedStale(at: now)
        guard let registration = registrations[id] else { throw SessionRegistryError.notFound }
        return registration
    }

    public func activeRegistrations(
        proof: SessionAuthenticationProof,
        now: Date = Date()
    ) async throws -> [AgentSessionRegistration] {
        try authenticate(proof)
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        try await loadIfNeeded()
        _ = try await expireLoadedStale(at: now)
        return registrations.values
            .filter { $0.lifecycle == .active }
            .sorted { ($0.registeredAt, $0.sessionID) < ($1.registeredAt, $1.sessionID) }
    }

    public func historicalRegistrations(
        sessionID: String? = nil,
        proof: SessionAuthenticationProof,
        now: Date = Date()
    ) async throws -> [AgentSessionRegistration] {
        try authenticate(proof)
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        try await loadIfNeeded()
        _ = try await expireLoadedStale(at: now)
        return registrations.values
            .filter { sessionID == nil || $0.sessionID == sessionID }
            .sorted { ($0.registeredAt, $0.registrationID.uuidString) < ($1.registeredAt, $1.registrationID.uuidString) }
    }

    @discardableResult
    public func expireStale(at now: Date = Date()) async throws -> Int {
        await acquireExclusiveAccess()
        defer { releaseExclusiveAccess() }
        try await loadIfNeeded()
        return try await expireLoadedStale(at: now)
    }

    private func expireLoadedStale(at now: Date) async throws -> Int {
        var count = 0
        for (id, current) in registrations where current.lifecycle == .active && current.expiresAt <= now {
            let expired = AgentSessionRegistration(
                registrationID: current.registrationID,
                client: current.client,
                sessionID: current.sessionID,
                process: current.process,
                workspaceRoots: current.workspaceRoots,
                registeredAt: current.registeredAt,
                expiresAt: current.expiresAt,
                endedAt: current.expiresAt,
                lifecycle: .expired,
                authentication: current.authentication,
                lastHeartbeatAt: current.lastHeartbeatAt,
                taskContext: current.taskContext
            )
            try await persist(expired)
            registrations[id] = expired
            count += 1
        }
        return count
    }

    private func acquireExclusiveAccess() async {
        if !accessBusy {
            accessBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            accessWaiters.append(continuation)
        }
    }

    private func releaseExclusiveAccess() {
        if accessWaiters.isEmpty {
            accessBusy = false
        } else {
            accessWaiters.removeFirst().resume()
        }
    }

    private func loadIfNeeded() async throws {
        guard !loadedPersistedState else { return }
        if let evidenceStore {
            for registration in try await evidenceStore.agentSessions() {
                registrations[registration.registrationID] = registration
            }
        }
        loadedPersistedState = true
    }

    private func persist(_ registration: AgentSessionRegistration) async throws {
        if let evidenceStore { try await evidenceStore.persistAgentSession(registration) }
    }

    private func authenticate(_ proof: SessionAuthenticationProof) throws {
        guard proof.peerUID == expectedPeerUID,
              proof.socketMode == 0o600,
              constantTimeEqual(proof.challengeDigest, expectedChallengeDigest)
        else { throw SessionRegistryError.unauthenticated }
    }

    private func validate(_ request: SessionRegistrationRequest, now: Date) throws {
        guard !request.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.sessionID.utf8.count <= 256
        else { throw SessionRegistryError.invalidRequest("session_id must contain 1...256 UTF-8 bytes") }
        guard request.process.pid > 0 else { throw SessionRegistryError.invalidRequest("pid must be positive") }
        guard request.process.startTime <= now.addingTimeInterval(5) else {
            throw SessionRegistryError.invalidRequest("process start time is in the future")
        }
        guard request.registeredAt <= now.addingTimeInterval(5) else {
            throw SessionRegistryError.invalidRequest("registration time is in the future")
        }
        guard request.expiresAt > now,
              request.expiresAt.timeIntervalSince(request.registeredAt) <= maximumLease
        else { throw SessionRegistryError.invalidRequest("registration is stale or lease exceeds the maximum") }
        guard request.workspaceRoots.count <= 32 else {
            throw SessionRegistryError.invalidRequest("too many workspace roots")
        }
        guard !request.workspaceRoots.contains(where: { $0.isEmpty || !$0.hasPrefix("/") }) else {
            throw SessionRegistryError.invalidRequest("workspace roots must be absolute paths")
        }
        if let taskContext = request.taskContext {
            guard !taskContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  taskContext.utf8.count <= 1_024
            else { throw SessionRegistryError.invalidRequest("task context must contain 1...1024 UTF-8 bytes") }
        }
    }

    private func normalizedRoots(_ roots: [String]) -> [String] {
        Array(Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        for index in 0 ..< max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
    }
}
