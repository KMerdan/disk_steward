import DiskStewardCore
@testable import DiskStewardEndpoint
import Foundation
import XCTest

final class EndpointDeliveryRegressionTests: XCTestCase {
    func testDelayedFirstDeliveryPreservesOrderIncludingExcludedMiddle() async throws {
        let fixture = DeliveryFixture(), runtime = RetainedCallbackRuntime(), gate = DeliveryGate()
        defer { gate.release() }
        let observer = fixture.observer(runtime, hooks: .init(beforeDelivery: { event in
            if event.sequence == 1 { await gate.wait() }
        }))
        await observer.start()
        runtime.emit(fixture.raw(1))
        await fulfillment(of: [gate.entered], timeout: 3)
        runtime.emit(fixture.raw(2, path: "/excluded/b"))
        runtime.emit(fixture.raw(3))
        let held = await observer.deliverySnapshot()
        XCTAssertTrue(held.inFlight)
        XCTAssertEqual(held.retainedEvents, 3)
        gate.release()
        let idle = await observer.waitUntilIdle()
        XCTAssertTrue(idle)
        let events = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertEqual(events.map(\.raw.sequence), [1, 3])
        XCTAssertEqual(events.map(\.confidence), [.exact, .exact])
        XCTAssertEqual(events.map(\.gapBefore), [false, false])
        await observer.stop()
    }

    func testOverflowIsBoundedIncludingInFlightAndReportsLossWithoutAnotherEvent() async throws {
        let fixture = DeliveryFixture(), runtime = RetainedCallbackRuntime(), gate = DeliveryGate()
        defer { gate.release() }
        let observer = fixture.observer(runtime, limits: .init(events: 2, bytes: 8_192), hooks: .init(beforeDelivery: { event in
            if event.sequence == 1 { await gate.wait() }
        }))
        await observer.start()
        runtime.emit(fixture.raw(1))
        await fulfillment(of: [gate.entered], timeout: 3)
        runtime.emit(fixture.raw(2))
        for sequence in 3 ... 10_002 { runtime.emit(fixture.raw(UInt64(sequence))) }
        let held = await observer.deliverySnapshot()
        XCTAssertTrue(held.inFlight)
        XCTAssertEqual(held.retainedEvents, 2)
        XCTAssertEqual(held.retainedBytes, fixture.raw(1).estimatedRetainedBytes + fixture.raw(2).estimatedRetainedBytes)
        XCTAssertEqual(held.pendingDrops, 10_000)
        gate.release()
        let idle = await observer.waitUntilIdle()
        XCTAssertTrue(idle)
        let status = await fixture.bridge.status()
        XCTAssertEqual(status.state, .overloaded)
        XCTAssertEqual(status.droppedEvents, 10_000)
        XCTAssertTrue(status.eventGap && status.fallbackActive)
        XCTAssertEqual(status.maximumConfidence, .unknown)
        let empty = await observer.deliverySnapshot()
        XCTAssertEqual(empty.retainedEvents, 0)
        XCTAssertEqual(empty.retainedBytes, 0)
        let events = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertEqual(events.map(\.raw.sequence), [1, 2])
        runtime.emit(fixture.raw(10_003))
        let resumed = await observer.waitUntilIdle()
        XCTAssertTrue(resumed)
        let afterGap = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertEqual(afterGap.first?.confidence, .unknown)
        await observer.stop()
    }

    func testEveryVariableFieldCountsTowardByteLimit() async throws {
        for field in 0 ..< 7 {
            let fixture = DeliveryFixture(), runtime = RetainedCallbackRuntime()
            let observer = fixture.observer(runtime, limits: .init(events: 10, bytes: 2_048))
            await observer.start()
            let oversized = fixture.raw(1, oversizedField: field)
            XCTAssertGreaterThan(oversized.estimatedRetainedBytes, 2_048)
            runtime.emit(oversized)
            let idle = await observer.waitUntilIdle()
            XCTAssertTrue(idle)
            let events = try await fixture.bridge.drain(proof: fixture.proof)
            XCTAssertTrue(events.isEmpty)
            let status = await fixture.bridge.status()
            XCTAssertEqual(status.droppedEvents, 1)
            XCTAssertEqual(status.state, .overloaded)
            await observer.stop()
        }
    }

    func testByteBudgetIncludesOldInFlightReservationAcrossRestart() async throws {
        let fixture = DeliveryFixture(), runtime = RetainedCallbackRuntime(), gate = DeliveryGate()
        defer { gate.release() }
        let event = fixture.raw(1)
        let observer = fixture.observer(runtime, limits: .init(events: 10, bytes: event.estimatedRetainedBytes), hooks: .init(beforeDelivery: { event in
            if event.sequence == 1 { await gate.wait() }
        }))
        await observer.start()
        runtime.emit(event)
        await fulfillment(of: [gate.entered], timeout: 3)
        await observer.stop()
        await observer.start()
        runtime.emit(fixture.raw(2))
        let held = await observer.deliverySnapshot()
        XCTAssertEqual(held.retainedEvents, 1)
        XCTAssertEqual(held.retainedBytes, event.estimatedRetainedBytes)
        XCTAssertEqual(held.pendingDrops, 1)
        gate.release()
        let idle = await observer.waitUntilIdle()
        XCTAssertTrue(idle)
        let events = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertTrue(events.isEmpty, "Old epoch cannot commit and new data cannot exceed the held byte budget")
        let status = await fixture.bridge.status()
        XCTAssertEqual(status.droppedEvents, 1)
        await observer.stop()
    }

    func testStopAndCrashFenceHeldDeliveriesAndRetainedCallbacks() async throws {
        for crash in [false, true] {
            let fixture = DeliveryFixture(), runtime = RetainedCallbackRuntime(), gate = DeliveryGate()
            defer { gate.release() }
            let observer = fixture.observer(runtime, hooks: .init(beforeDelivery: { event in
                if event.sequence == 1 { await gate.wait() }
            }))
            await observer.start()
            let previous = try XCTUnwrap(runtime.capture())
            runtime.emit(fixture.raw(1))
            await fulfillment(of: [gate.entered], timeout: 3)
            runtime.emit(fixture.raw(2))
            if crash { await observer.runtimeDidCrash() } else { await observer.stop() }
            previous(fixture.raw(3))
            let held = await observer.deliverySnapshot()
            XCTAssertEqual(held.retainedEvents, 1, "Only the still-held consumer reservation survives stop")
            let stopped = await fixture.bridge.status()
            XCTAssertEqual(stopped.state, .unavailable)
            await observer.start()
            runtime.emit(fixture.raw(10, stream: "new"))
            runtime.emit(fixture.raw(11, stream: "new"))
            previous(fixture.raw(4))
            gate.release()
            let idle = await observer.waitUntilIdle()
            XCTAssertTrue(idle)
            let events = try await fixture.bridge.drain(proof: fixture.proof)
            XCTAssertEqual(events.map(\.raw.sequence), [10, 11])
            XCTAssertEqual(events.map(\.confidence), [.unknown, .exact], "Only the real monitoring downtime is a gap")
            await observer.stop()
            previous(fixture.raw(5))
            let finalIdle = await observer.waitUntilIdle()
            XCTAssertTrue(finalIdle)
            let final = await fixture.bridge.status()
            XCTAssertEqual(final.state, .unavailable)
        }
    }

    func testOldActivationCannotResumeAfterStopOrReplaceNewSession() async throws {
        let fixture = DeliveryFixture(), runtime = RetainedCallbackRuntime(), gate = DeliveryGate()
        defer { gate.release() }
        let observer = fixture.observer(runtime, hooks: .init(beforeActivation: { await gate.waitFirst() }))
        let first = Task { await observer.start() }
        await fulfillment(of: [gate.entered], timeout: 3)
        await observer.stop()
        await observer.start()
        XCTAssertEqual(runtime.startCount, 1)
        gate.release()
        await first.value
        XCTAssertEqual(runtime.startCount, 1)
        runtime.emit(fixture.raw(1))
        let idle = await observer.waitUntilIdle()
        XCTAssertTrue(idle)
        let events = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertEqual(events.map(\.confidence), [.exact])
        await observer.stop()
    }

    func testSynchronousStartupCallbacksPublishOnlyAfterSuccessfulStart() async throws {
        for fails in [false, true] {
            let fixture = DeliveryFixture()
            let runtime = RetainedCallbackRuntime(startupEvent: fixture.raw(1), startupError: fails ? .notPermitted : nil)
            let observer = fixture.observer(runtime)
            await observer.start()
            let idle = await observer.waitUntilIdle()
            XCTAssertTrue(idle)
            let events = try await fixture.bridge.drain(proof: fixture.proof)
            XCTAssertEqual(events.count, fails ? 0 : 1)
            let status = await fixture.bridge.status()
            XCTAssertEqual(status.state, fails ? .notPermitted : .available)
            await observer.stop()
        }
    }

    func testGapOnExcludedOrInvalidEventRemainsVisibleAndWrapDoesNotTrap() async throws {
        let fixture = DeliveryFixture()
        _ = try await fixture.bridge.receive(fixture.raw(1), proof: fixture.proof)
        _ = try await fixture.bridge.receive(fixture.raw(3, path: "/excluded/gap"), proof: fixture.proof)
        let excludedGap = await fixture.bridge.status()
        XCTAssertTrue(excludedGap.eventGap)
        _ = try await fixture.bridge.receive(fixture.raw(4), proof: fixture.proof)
        do {
            _ = try await fixture.bridge.receive(fixture.raw(0), proof: fixture.proof)
            XCTFail("Invalid notification must throw")
        } catch EndpointBridgeError.invalidNotification {}
        _ = try await fixture.bridge.receive(fixture.raw(5), proof: fixture.proof)
        _ = try await fixture.bridge.receive(fixture.raw(.max), proof: fixture.proof)
        _ = try await fixture.bridge.receive(fixture.raw(1), proof: fixture.proof)
        let events = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertEqual(events.map(\.confidence), [.exact, .unknown, .unknown, .unknown, .unknown])
    }

    func testManagedBridgeRejectsSpoofAndRevokedEpochWithoutStateMutation() async throws {
        let fixture = DeliveryFixture()
        let old = EndpointDeliveryEpoch(), current = EndpointDeliveryEpoch()
        _ = try await fixture.bridge.setDeliveryState(.available, epoch: old, proof: fixture.proof)
        old.invalidate()
        _ = try await fixture.bridge.setDeliveryState(.unavailable, epoch: current, proof: fixture.proof)
        let ignored = try await fixture.bridge.setDeliveryState(.available, epoch: old, proof: fixture.proof)
        XCTAssertFalse(ignored)
        _ = try await fixture.bridge.receive(fixture.raw(1), proof: fixture.proof, epoch: old)
        try await fixture.bridge.recordDeliveryLoss(10, epoch: old, proof: fixture.proof)
        let spoof = EndpointBridgePeerProof(teamID: "wrong", bundleID: "B", appGroupContainer: "C", designatedRequirementSatisfied: true, challengeDigest: "D")
        do {
            _ = try await fixture.bridge.setDeliveryState(.available, epoch: EndpointDeliveryEpoch(), proof: spoof)
            XCTFail("Spoofed lifecycle must throw")
        } catch EndpointBridgeError.unauthenticated {}
        let events = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertTrue(events.isEmpty)
        let status = await fixture.bridge.status()
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.droppedEvents, 0)
    }

    func testNormalizedBufferRejectsOversizedCoalescedReplacement() throws {
        let fixture = DeliveryFixture(), normalizer = EndpointEventNormalizer()
        var buffer = BoundedEndpointEventBuffer(maximumEvents: 2, maximumEstimatedBytes: 2_048)
        let first = try XCTUnwrap(normalizer.normalize(fixture.raw(1, operation: .writeClose), scope: fixture.scope, gapBefore: false))
        let large = try XCTUnwrap(normalizer.normalize(fixture.raw(2, path: "/watched/1", oversizedField: 6, operation: .writeClose, fileID: 1), scope: fixture.scope, gapBefore: false))
        XCTAssertEqual(buffer.append(first), .accepted)
        XCTAssertEqual(buffer.append(large), .dropped(total: 1))
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.drain().first?.raw.sequence, 1)
        XCTAssertTrue(buffer.hasGap)
    }

    func testRepeatedRestartDrainsAndDeinitRevokesRetainedHandler() async throws {
        let fixture = DeliveryFixture(), runtime = RetainedCallbackRuntime()
        var observer: EndpointSecurityObserver? = fixture.observer(runtime)
        weak var reference = observer
        for cycle in 0 ..< 30 {
            await observer!.start()
            runtime.emit(fixture.raw(1, stream: "cycle-\(cycle)"))
            let idle = await observer!.waitUntilIdle()
            XCTAssertTrue(idle)
            let events = try await fixture.bridge.drain(proof: fixture.proof)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.confidence, cycle == 0 ? .exact : .unknown)
            let snapshot = await observer!.deliverySnapshot()
            XCTAssertEqual(snapshot.retainedEvents, 0)
            XCTAssertEqual(snapshot.retainedBytes, 0)
            XCTAssertFalse(snapshot.inFlight)
            if cycle < 29 { await observer!.stop() }
        }
        let retained = try XCTUnwrap(runtime.capture())
        observer = nil
        XCTAssertNil(reference, "The persistent worker must not retain its observer")
        retained(fixture.raw(2))
        let status = await fixture.bridge.status()
        XCTAssertEqual(status.state, .unavailable)
        let events = try await fixture.bridge.drain(proof: fixture.proof)
        XCTAssertTrue(events.isEmpty)
    }

    func testChallengeLengthMismatchCannotAuthenticateThroughByteTruncation() async throws {
        let fixture = DeliveryFixture()
        let spoof = EndpointBridgePeerProof(teamID: "T", bundleID: "B", appGroupContainer: "C", designatedRequirementSatisfied: true, challengeDigest: "D" + String(repeating: "\0", count: 256))
        do {
            _ = try await fixture.bridge.receive(fixture.raw(1), proof: spoof)
            XCTFail("Challenge length comparison must not wrap to zero")
        } catch EndpointBridgeError.unauthenticated {}
    }

    func testMalformedSizeAndCoalescedArithmeticOverflowBecomeGapsNotTraps() async throws {
        let fixture = DeliveryFixture(), normalizer = EndpointEventNormalizer()
        let raw = fixture.raw(1, operation: .writeClose)
        let malformed = RawPrivilegedNotification(eventID: raw.eventID, streamID: raw.streamID, sequence: raw.sequence, observedAt: raw.observedAt, operation: raw.operation, path: raw.path, process: raw.process, fileIdentity: raw.fileIdentity, size: .init(logicalBefore: .min, logicalAfter: .max, allocatedBefore: 0, allocatedAfter: 1, method: "fixture"))
        do {
            _ = try await fixture.bridge.receive(malformed, proof: fixture.proof)
            XCTFail("Unrepresentable size must throw")
        } catch EndpointBridgeError.invalidNotification {}
        let status = await fixture.bridge.status()
        XCTAssertTrue(status.eventGap)
        var buffer = BoundedEndpointEventBuffer()
        let normalized = try XCTUnwrap(normalizer.normalize(raw, scope: fixture.scope, gapBefore: false))
        let maximum = NormalizedPrivilegedEvent(raw: raw, watchedRoot: "/watched", logicalDelta: .max, allocatedDelta: .max, coalescedCount: .max, gapBefore: false, confidence: .exact, method: "fixture", limitations: [])
        XCTAssertEqual(buffer.append(maximum), .accepted)
        XCTAssertEqual(buffer.append(normalized), .dropped(total: 1))
        XCTAssertTrue(buffer.hasGap)
        XCTAssertEqual(buffer.drain().first?.logicalDelta, .max)
    }
}

private struct DeliveryFixture {
    let scope = EndpointMonitoringScope(watchedRoots: ["/watched"], excludedRoots: ["/excluded"])
    let proof = EndpointBridgePeerProof(teamID: "T", bundleID: "B", appGroupContainer: "C", designatedRequirementSatisfied: true, challengeDigest: "D")
    let bridge: ProtectedEndpointBridge

    init() {
        bridge = ProtectedEndpointBridge(expectedTeamID: "T", expectedBundleID: "B", expectedContainer: "C", expectedChallengeDigest: "D", scope: scope, buffer: .init(maximumEvents: 32, maximumEstimatedBytes: 65_536))
    }

    func observer(_ runtime: RetainedCallbackRuntime, limits: EndpointDeliveryLimits = .init(), hooks: EndpointDeliveryHooks = .init()) -> EndpointSecurityObserver {
        EndpointSecurityObserver(runtime: runtime, bridge: bridge, proof: proof, limits: limits, hooks: hooks)
    }

    func raw(_ sequence: UInt64, path: String? = nil, stream: String = "s", oversizedField: Int? = nil, operation: PrivilegedFileOperation = .create, fileID: UInt64? = nil) -> RawPrivilegedNotification {
        let huge = String(repeating: "x", count: 2_048)
        return .init(eventID: oversizedField == 0 ? huge : "e\(sequence)", streamID: oversizedField == 1 ? huge : stream, sequence: sequence, observedAt: Date(timeIntervalSince1970: 100), operation: operation, path: oversizedField == 2 ? "/watched/" + huge : path ?? "/watched/\(sequence)", destinationPath: oversizedField == 3 ? "/watched/" + huge : nil, process: .init(pid: 1, startTime: Date(timeIntervalSince1970: 0), executablePath: oversizedField == 4 ? huge : "/writer"), fileIdentity: .init(volumeID: oversizedField == 5 ? huge : "v", fileID: fileID ?? sequence), size: .init(logicalBefore: 0, logicalAfter: 1, allocatedBefore: 0, allocatedAfter: 1, method: oversizedField == 6 ? huge : "fixture"))
    }
}

private final class DeliveryGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "consumer entered deterministic gate")
    private let lock = NSLock()
    private var open = false
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func waitFirst() async {
        let first = lock.withLock { calls += 1; return calls == 1 }
        if first { await wait() }
    }

    func wait() async {
        await withCheckedContinuation { value in
            lock.lock()
            if open { lock.unlock(); value.resume(); return }
            precondition(continuation == nil, "One consumer only")
            continuation = value
            lock.unlock()
            entered.fulfill()
        }
    }

    func release() {
        lock.lock(); open = true; let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume()
    }
}

private final class RetainedCallbackRuntime: EndpointSecurityNotificationRuntime, @unchecked Sendable {
    typealias Handler = @Sendable (RawPrivilegedNotification) -> Void
    private let lock = NSLock()
    private var handler: Handler?
    private var starts = 0
    private let startupEvent: RawPrivilegedNotification?
    private let startupError: EndpointSecurityStartupError?
    init(startupEvent: RawPrivilegedNotification? = nil, startupError: EndpointSecurityStartupError? = nil) {
        self.startupEvent = startupEvent; self.startupError = startupError
    }
    var startCount: Int { lock.withLock { starts } }
    func start(handler: @escaping Handler) throws {
        lock.withLock { self.handler = handler; starts += 1 }
        if let startupEvent { handler(startupEvent) }
        if let startupError { throw startupError }
    }
    func stop() { lock.withLock { handler = nil } }
    func capture() -> Handler? { lock.withLock { handler } }
    func emit(_ event: RawPrivilegedNotification) { capture()?(event) }
}
