import Darwin
import DiskStewardCore
import XCTest

final class AgentSessionRegistryTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testAuthenticatedRegistrationEndsAndExpiresWithoutPersistingSecret() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = AgentSessionRegistry(expectedPeerUID: getuid(), expectedChallengeDigest: digest)
        let proof = SessionAuthenticationProof(peerUID: getuid(), socketMode: 0o600, challengeDigest: digest)
        let request = SessionRegistrationRequest(
            client: .codex,
            sessionID: "task-one",
            process: ProcessIdentity(pid: 101, startTime: now.addingTimeInterval(-30)),
            workspaceRoots: ["/tmp/project/../project"],
            registeredAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        let active = try await registry.register(request, proof: proof, now: now)
        XCTAssertEqual(active.lifecycle, .active)
        XCTAssertEqual(active.workspaceRoots, ["/tmp/project"])
        XCTAssertFalse(active.authentication.secretPersisted)
        let activeRegistrations = try await registry.activeRegistrations(proof: proof, now: now)
        XCTAssertEqual(activeRegistrations.count, 1)

        let ended = try await registry.end(registrationID: active.registrationID, proof: proof, now: now.addingTimeInterval(10))
        XCTAssertEqual(ended.lifecycle, .ended)
        let afterEnd = try await registry.activeRegistrations(proof: proof, now: now.addingTimeInterval(11))
        XCTAssertEqual(afterEnd, [])

        let second = SessionRegistrationRequest(
            client: .claude,
            sessionID: "task-two",
            process: ProcessIdentity(pid: 102, startTime: now),
            workspaceRoots: [],
            registeredAt: now,
            expiresAt: now.addingTimeInterval(20)
        )
        let expiring = try await registry.register(second, proof: proof, now: now)
        let expiredCount = await registry.expireStale(at: now.addingTimeInterval(21))
        XCTAssertEqual(expiredCount, 1)
        let expired = try await registry.registration(id: expiring.registrationID, proof: proof, now: now.addingTimeInterval(21))
        XCTAssertEqual(expired.lifecycle, .expired)
    }

    func testSpoofedStaleDuplicateAndCrossTaskRegistrationsFailClosed() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = AgentSessionRegistry(expectedPeerUID: 501, expectedChallengeDigest: digest)
        let proof = SessionAuthenticationProof(peerUID: 501, socketMode: 0o600, challengeDigest: digest)
        let process = ProcessIdentity(pid: 201, startTime: now.addingTimeInterval(-10))
        let valid = SessionRegistrationRequest(
            client: .codex,
            sessionID: "one",
            process: process,
            workspaceRoots: ["/tmp/one"],
            registeredAt: now,
            expiresAt: now.addingTimeInterval(100)
        )

        do {
            _ = try await registry.register(valid, proof: .init(peerUID: 502, socketMode: 0o600, challengeDigest: digest), now: now)
            XCTFail("spoofed UID should fail")
        } catch { XCTAssertEqual(error as? SessionRegistryError, .unauthenticated) }

        do {
            _ = try await registry.register(valid, proof: .init(peerUID: 501, socketMode: 0o666, challengeDigest: digest), now: now)
            XCTFail("public socket mode should fail")
        } catch { XCTAssertEqual(error as? SessionRegistryError, .unauthenticated) }

        _ = try await registry.register(valid, proof: proof, now: now)
        do {
            _ = try await registry.register(valid, proof: proof, now: now)
            XCTFail("duplicate session should fail")
        } catch { XCTAssertEqual(error as? SessionRegistryError, .duplicateSession) }

        let otherSessionSameProcess = SessionRegistrationRequest(
            client: .claude,
            sessionID: "two",
            process: process,
            workspaceRoots: ["/tmp/two"],
            registeredAt: now,
            expiresAt: now.addingTimeInterval(100)
        )
        do {
            _ = try await registry.register(otherSessionSameProcess, proof: proof, now: now)
            XCTFail("one process identity cannot own two active tasks")
        } catch { XCTAssertEqual(error as? SessionRegistryError, .processAlreadyRegistered) }

        let stale = SessionRegistrationRequest(
            client: .claude,
            sessionID: "stale",
            process: ProcessIdentity(pid: 202, startTime: now.addingTimeInterval(-10)),
            workspaceRoots: [],
            registeredAt: now.addingTimeInterval(-200),
            expiresAt: now.addingTimeInterval(-1)
        )
        do {
            _ = try await registry.register(stale, proof: proof, now: now)
            XCTFail("stale registration should fail")
        } catch {
            guard case .invalidRequest = error as? SessionRegistryError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPIDReuseIsASeparateIdentityAndLocalInspectorFindsCurrentProcess() async throws {
        let now = Date()
        let registry = AgentSessionRegistry(expectedPeerUID: getuid(), expectedChallengeDigest: digest)
        let proof = SessionAuthenticationProof(peerUID: getuid(), socketMode: 0o600, challengeDigest: digest)
        _ = try await registry.register(
            SessionRegistrationRequest(
                client: .codex,
                sessionID: "old-pid-generation",
                process: ProcessIdentity(pid: 301, startTime: now.addingTimeInterval(-100)),
                workspaceRoots: [],
                registeredAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            proof: proof,
            now: now
        )
        _ = try await registry.register(
            SessionRegistrationRequest(
                client: .claude,
                sessionID: "new-pid-generation",
                process: ProcessIdentity(pid: 301, startTime: now.addingTimeInterval(-10)),
                workspaceRoots: [],
                registeredAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            proof: proof,
            now: now
        )
        let activeRegistrations = try await registry.activeRegistrations(proof: proof, now: now)
        XCTAssertEqual(activeRegistrations.count, 2)

        let inspector = LocalProcessInspector()
        let identity = try XCTUnwrap(inspector.identity())
        XCTAssertEqual(identity.pid, getpid())
        XCTAssertLessThanOrEqual(identity.startTime, Date())
        XCTAssertTrue(inspector.snapshot().records.keys.contains(identity))
    }
}
