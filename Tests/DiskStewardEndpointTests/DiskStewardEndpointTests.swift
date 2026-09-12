import DiskStewardCore
@testable import DiskStewardEndpoint
import Foundation
import XCTest

final class DiskStewardEndpointTests: XCTestCase {
    func testFixtureRuntimeFiltersNormalizesAndDeliversWithoutAuthorizationEvents() async throws {
        let fixture = Fixture()
        let runtime = FixtureEndpointSecurityRuntime()
        let observer = EndpointSecurityObserver(runtime: runtime, bridge: fixture.bridge, proof: fixture.proof)
        XCTAssertEqual(EndpointSecurityObserver.notificationOnlySubscriptions, ["NOTIFY_CREATE", "NOTIFY_RENAME", "NOTIFY_WRITE", "NOTIFY_CLOSE"])
        await observer.start()
        runtime.emit(fixture.raw(path: "/watched/output.bin", sequence: 1))
        runtime.emit(fixture.raw(path: "/private/excluded.bin", sequence: 2))
        try await Task.sleep(for: .milliseconds(20))
        let events = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertEqual(events.map(\.raw.path), ["/watched/output.bin"])
        XCTAssertEqual(events.first?.confidence, .exact)
        let available = await fixture.bridge.status()
        XCTAssertEqual(available.state, .available)
    }

    func testBridgeRejectsSpoofedPeerAndDetectsSequenceLoss() async throws {
        let fixture = Fixture()
        var spoof = fixture.proof
        spoof = EndpointBridgePeerProof(teamID: "ATTACKER", bundleID: spoof.bundleID, appGroupContainer: spoof.appGroupContainer, designatedRequirementSatisfied: true, challengeDigest: spoof.challengeDigest)
        await XCTAssertThrowsErrorAsync { _ = try await fixture.bridge.receive(fixture.raw(path: "/watched/a", sequence: 1), proof: spoof) }

        _ = try await fixture.bridge.receive(fixture.raw(path: "/watched/a", sequence: 1), proof: fixture.proof)
        _ = try await fixture.bridge.receive(fixture.raw(path: "/watched/b", sequence: 3), proof: fixture.proof)
        let events = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertEqual(events.last?.confidence, .unknown)
        XCTAssertTrue(events.last?.gapBefore == true)
        let gapStatus = await fixture.bridge.status()
        XCTAssertTrue(gapStatus.eventGap)
    }

    func testWritesCoalesceWithinBoundsAndOverloadSignalsFallback() async throws {
        var buffer = BoundedEndpointEventBuffer(maximumEvents: 1, maximumEstimatedBytes: 2_000, coalescingWindow: 1)
        let fixture = Fixture()
        let normalizer = EndpointEventNormalizer()
        let first = try XCTUnwrap(normalizer.normalize(fixture.raw(path: "/watched/a", sequence: 1), scope: fixture.scope, gapBefore: false))
        let second = try XCTUnwrap(normalizer.normalize(fixture.raw(path: "/watched/a", sequence: 2, observedAt: Date().addingTimeInterval(0.2)), scope: fixture.scope, gapBefore: false))
        XCTAssertEqual(buffer.append(first), .accepted)
        XCTAssertEqual(buffer.append(second), .coalesced)
        XCTAssertEqual(buffer.drain().first?.coalescedCount, 2)

        XCTAssertEqual(buffer.append(first), .accepted)
        let other = try XCTUnwrap(normalizer.normalize(fixture.raw(path: "/watched/b", sequence: 3, fileID: 2), scope: fixture.scope, gapBefore: false))
        XCTAssertEqual(buffer.append(other), .dropped(total: 1))
        XCTAssertTrue(buffer.hasGap)
    }

    func testDenialCrashAndMissingEntitlementKeepFallbackVisible() async {
        for error in [EndpointSecurityStartupError.notEntitled, .notPermitted, .pendingUserApproval, .tooManyClients] {
            let fixture = Fixture()
            let observer = EndpointSecurityObserver(runtime: FixtureEndpointSecurityRuntime(startupError: error), bridge: fixture.bridge, proof: fixture.proof)
            await observer.start()
            let status = await fixture.bridge.status()
            XCTAssertEqual(status.fallbackActive, true)
            XCTAssertNotEqual(status.maximumConfidence, .exact)
            XCTAssertFalse(status.limitations.isEmpty)
        }
        let fixture = Fixture()
        let observer = EndpointSecurityObserver(runtime: FixtureEndpointSecurityRuntime(), bridge: fixture.bridge, proof: fixture.proof)
        await observer.start()
        await observer.runtimeDidCrash()
        let crashed = await fixture.bridge.status()
        XCTAssertEqual(crashed.state, .unavailable)
        XCTAssertTrue(crashed.automaticRetry)
    }
}

private struct Fixture {
    let scope = EndpointMonitoringScope(watchedRoots: ["/watched"], excludedRoots: ["/private"])
    let proof = EndpointBridgePeerProof(teamID: "TEAM", bundleID: "com.disksteward.endpoint", appGroupContainer: "group.com.disksteward.shared", designatedRequirementSatisfied: true, challengeDigest: String(repeating: "a", count: 64))
    let bridge: ProtectedEndpointBridge

    init() {
        bridge = ProtectedEndpointBridge(expectedTeamID: "TEAM", expectedBundleID: "com.disksteward.endpoint", expectedContainer: "group.com.disksteward.shared", expectedChallengeDigest: String(repeating: "a", count: 64), scope: scope, buffer: .init(maximumEvents: 4, maximumEstimatedBytes: 4_096))
    }

    func raw(path: String, sequence: UInt64, observedAt: Date = Date(), fileID: UInt64 = 1) -> RawPrivilegedNotification {
        RawPrivilegedNotification(
            eventID: "event-\(sequence)", streamID: "stream", sequence: sequence, observedAt: observedAt,
            operation: .writeClose, path: path,
            process: ProcessIdentity(pid: 100, startTime: Date(timeIntervalSince1970: 100), executablePath: "/usr/bin/writer"),
            fileIdentity: PrivilegedFileIdentity(volumeID: "volume", fileID: fileID),
            size: PrivilegedSizeObservation(logicalBefore: 0, logicalAfter: 10, allocatedBefore: 0, allocatedAfter: 4096, method: "close-stat")
        )
    }
}

private func XCTAssertThrowsErrorAsync(_ expression: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
