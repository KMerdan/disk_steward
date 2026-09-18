import DiskStewardCore
import Foundation

public enum EndpointSecurityStartupError: Error, Equatable, Sendable {
    case pendingUserApproval
    case notEntitled
    case notPermitted
    case tooManyClients
    case unavailable

    public var bridgeState: EndpointBridgeState {
        switch self {
        case .pendingUserApproval: .pendingUserApproval
        case .notEntitled: .notEntitled
        case .notPermitted: .notPermitted
        case .tooManyClients: .tooManyClients
        case .unavailable: .unavailable
        }
    }
}

public protocol EndpointSecurityNotificationRuntime: Sendable {
    func start(handler: @escaping @Sendable (RawPrivilegedNotification) -> Void) throws
    func stop()
}

public actor EndpointSecurityObserver {
    public static let notificationOnlySubscriptions = ["NOTIFY_CREATE", "NOTIFY_RENAME", "NOTIFY_WRITE", "NOTIFY_CLOSE"]

    private let runtime: any EndpointSecurityNotificationRuntime
    private let bridge: ProtectedEndpointBridge
    private let proof: EndpointBridgePeerProof
    private let inbox: EndpointNotificationInbox
    private let worker: Task<Void, Never>
    private let hooks: EndpointDeliveryHooks
    private var epoch: EndpointDeliveryEpoch?

    public init(runtime: any EndpointSecurityNotificationRuntime, bridge: ProtectedEndpointBridge, proof: EndpointBridgePeerProof) {
        self.init(runtime: runtime, bridge: bridge, proof: proof, limits: .init(), hooks: .init())
    }

    init(runtime: any EndpointSecurityNotificationRuntime, bridge: ProtectedEndpointBridge, proof: EndpointBridgePeerProof, limits: EndpointDeliveryLimits, hooks: EndpointDeliveryHooks = .init()) {
        self.runtime = runtime
        self.bridge = bridge
        self.proof = proof
        self.hooks = hooks
        let inbox = EndpointNotificationInbox(limits: limits)
        self.inbox = inbox
        // Exactly one consumer for this observer's entire lifetime, not one task per event/start.
        // Capture collaborators, never the observer itself, so deinit can revoke and finish it.
        worker = Task {
            for await _ in inbox.signals {
                while !Task.isCancelled, let job = inbox.next() {
                    if let notification = job.notification {
                        await hooks.beforeDelivery(notification)
                        do { _ = try await bridge.receive(notification, proof: proof, epoch: job.epoch) }
                        catch { /* Authentication refuses mutation; invalid input records a bridge gap. */ }
                    } else {
                        try? await bridge.recordDeliveryLoss(job.drops, epoch: job.epoch, proof: proof)
                    }
                    inbox.complete(job)
                }
            }
        }
    }

    public func start() async {
        // Runtime calls are serialized by this actor. Async continuations also carry revocable epochs.
        epoch?.invalidate()
        runtime.stop()
        let attempt = EndpointDeliveryEpoch()
        epoch = attempt
        inbox.reset(to: nil)
        await hooks.beforeActivation()
        guard attempt.isCurrent else { return }
        do {
            guard try await bridge.setDeliveryState(.unavailable, epoch: attempt, proof: proof), attempt.isCurrent else { return }
            inbox.reset(to: attempt)
            try runtime.start { [inbox] notification in
                inbox.offer(notification, epoch: attempt)
            }
            // Synchronous startup callbacks are staged; a throwing startup cannot publish them.
            guard try await bridge.setDeliveryState(.available, epoch: attempt, proof: proof), attempt.isCurrent else { return }
            inbox.enableDelivery(for: attempt)
        } catch let error as EndpointSecurityStartupError {
            await finishAttempt(attempt, state: error.bridgeState)
        } catch {
            await finishAttempt(attempt, state: .unavailable)
        }
    }

    public func stop() async {
        epoch?.invalidate()
        let stopped = EndpointDeliveryEpoch()
        epoch = stopped
        inbox.reset(to: nil)
        runtime.stop()
        _ = try? await bridge.setDeliveryState(.unavailable, epoch: stopped, proof: proof)
    }

    public func runtimeDidCrash() async { await stop() }

    private func finishAttempt(_ attempt: EndpointDeliveryEpoch, state: EndpointBridgeState) async {
        guard attempt.isCurrent else { return }
        attempt.invalidate()
        let failed = EndpointDeliveryEpoch()
        epoch = failed
        inbox.reset(to: nil)
        runtime.stop()
        _ = try? await bridge.setDeliveryState(state, epoch: failed, proof: proof)
    }

    // A single bounded acknowledgment slot for deterministic fixture verification.
    func waitUntilIdle() async -> Bool { await inbox.waitUntilIdle() }
    func deliverySnapshot() -> EndpointDeliverySnapshot { inbox.snapshot() }

    deinit {
        epoch?.invalidate()
        runtime.stop()
        inbox.shutdown()
        worker.cancel()
    }
}

struct EndpointDeliveryLimits: Sendable {
    let events: Int
    let bytes: Int
    init(events: Int = 4_096, bytes: Int = 4 * 1_024 * 1_024) {
        self.events = min(max(events, 1), 4_096)
        self.bytes = min(max(bytes, 1_024), 4 * 1_024 * 1_024)
    }
}

struct EndpointDeliveryHooks: Sendable {
    var beforeActivation: @Sendable () async -> Void = {}
    var beforeDelivery: @Sendable (RawPrivilegedNotification) async -> Void = { _ in }
}

struct EndpointDeliverySnapshot: Sendable {
    let retainedEvents: Int
    let retainedBytes: Int
    let inFlight: Bool
    let pendingDrops: Int
}

/// The callback's only handoff: synchronous FIFO admission, with no callback-created Tasks.
/// The stream carries wakeups, NOT notifications. Payload and loss state live in this bounded owner.
private final class EndpointNotificationInbox: @unchecked Sendable {
    struct Job: Sendable {
        let epoch: EndpointDeliveryEpoch
        let notification: RawPrivilegedNotification?
        let bytes: Int
        let drops: Int
    }

    let signals: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private let limits: EndpointDeliveryLimits
    private var ring: [Job?]
    private var head = 0
    private var count = 0
    private var reservedEvents = 0
    private var reservedBytes = 0
    private var inFlight = false
    private var pendingDrops = 0
    private var epoch: EndpointDeliveryEpoch?
    private var deliveryEnabled = false
    private var idleWaiter: CheckedContinuation<Bool, Never>?

    init(limits: EndpointDeliveryLimits) {
        self.limits = limits
        ring = Array(repeating: nil, count: limits.events)
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = stream.stream
        wake = stream.continuation
    }

    func reset(to next: EndpointDeliveryEpoch?) {
        lock.lock()
        epoch?.invalidate()
        epoch = next
        deliveryEnabled = false
        for index in ring.indices {
            if let job = ring[index] { reservedEvents -= 1; reservedBytes -= job.bytes; ring[index] = nil }
        }
        head = 0; count = 0; pendingDrops = 0
        // A held old-epoch delivery still owns its reservation until the consumer releases it.
        let waiter = takeIdleWaiter()
        lock.unlock()
        waiter?.resume(returning: true)
    }

    func enableDelivery(for readyEpoch: EndpointDeliveryEpoch) {
        lock.lock()
        guard epoch === readyEpoch, readyEpoch.isCurrent else { lock.unlock(); return }
        deliveryEnabled = true
        lock.unlock()
        wake.yield(())
    }

    func offer(_ event: RawPrivilegedNotification, epoch offeredEpoch: EndpointDeliveryEpoch) {
        lock.lock()
        guard epoch === offeredEpoch, offeredEpoch.isCurrent else { lock.unlock(); return }
        let bytes = event.estimatedRetainedBytes
        if pendingDrops > 0 || reservedEvents >= limits.events || bytes > limits.bytes - reservedBytes {
            if pendingDrops < .max { pendingDrops += 1 }
        } else {
            ring[(head + count) % ring.count] = Job(epoch: offeredEpoch, notification: event, bytes: bytes, drops: 0)
            count += 1; reservedEvents += 1; reservedBytes += bytes
        }
        lock.unlock()
        wake.yield(())
    }

    func next() -> Job? {
        lock.lock(); defer { lock.unlock() }
        precondition(!inFlight)
        guard deliveryEnabled else { return nil }
        if count > 0 {
            let job = ring[head]
            ring[head] = nil; head = (head + 1) % ring.count; count -= 1
            inFlight = true
            return job
        }
        if pendingDrops > 0, let epoch {
            let job = Job(epoch: epoch, notification: nil, bytes: 0, drops: pendingDrops)
            pendingDrops = 0; inFlight = true
            return job
        }
        return nil
    }

    func complete(_ job: Job) {
        lock.lock()
        if job.notification != nil { reservedEvents -= 1; reservedBytes -= job.bytes }
        inFlight = false
        let waiter = takeIdleWaiter()
        lock.unlock()
        waiter?.resume(returning: true)
    }

    func waitUntilIdle() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !inFlight && count == 0 && pendingDrops == 0 {
                lock.unlock(); continuation.resume(returning: true)
            } else if idleWaiter != nil {
                lock.unlock(); continuation.resume(returning: false)
            } else {
                idleWaiter = continuation
                lock.unlock()
            }
        }
    }

    private func takeIdleWaiter() -> CheckedContinuation<Bool, Never>? {
        guard !inFlight && count == 0 && pendingDrops == 0 else { return nil }
        defer { idleWaiter = nil }
        return idleWaiter
    }

    func snapshot() -> EndpointDeliverySnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(retainedEvents: reservedEvents, retainedBytes: reservedBytes, inFlight: inFlight, pendingDrops: pendingDrops)
    }

    func shutdown() { reset(to: nil); wake.finish() }
}

public final class FixtureEndpointSecurityRuntime: EndpointSecurityNotificationRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (RawPrivilegedNotification) -> Void)?
    public var startupError: EndpointSecurityStartupError?

    public init(startupError: EndpointSecurityStartupError? = nil) { self.startupError = startupError }

    public func start(handler: @escaping @Sendable (RawPrivilegedNotification) -> Void) throws {
        if let startupError { throw startupError }
        lock.lock(); self.handler = handler; lock.unlock()
    }

    public func emit(_ notification: RawPrivilegedNotification) {
        lock.lock(); let callback = handler; lock.unlock()
        callback?(notification)
    }

    public func stop() {
        lock.lock(); handler = nil; lock.unlock()
    }
}

public struct UnavailableSystemEndpointSecurityRuntime: EndpointSecurityNotificationRuntime {
    public init() {}
    public func start(handler: @escaping @Sendable (RawPrivilegedNotification) -> Void) throws {
        throw EndpointSecurityStartupError.notEntitled
    }
    public func stop() {}
}
