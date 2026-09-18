import Foundation

/// One lifecycle attempt. Revocation is synchronous, including while the bridge is busy.
public final class EndpointDeliveryEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true

    public init() {}
    public func invalidate() { lock.lock(); current = false; lock.unlock() }
    public var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return current }
}

public actor ProtectedEndpointBridge {
    private let expectedTeamID: String
    private let expectedBundleID: String
    private let expectedContainer: String
    private let expectedChallengeDigest: String
    private let scope: EndpointMonitoringScope
    private let normalizer = EndpointEventNormalizer()
    private var buffer: BoundedEndpointEventBuffer
    private var streamID: String?
    private var lastSequence: UInt64?
    private var statusValue: EndpointBridgeStatus
    private var deliveryEpoch: EndpointDeliveryEpoch?
    private var acceptsDelivery = false
    private var hasStarted = false
    private var pendingGap = false
    private var observedGap = false
    private var ingressDrops = 0

    public init(expectedTeamID: String, expectedBundleID: String, expectedContainer: String, expectedChallengeDigest: String, scope: EndpointMonitoringScope, buffer: BoundedEndpointEventBuffer = .init()) {
        self.expectedTeamID = expectedTeamID
        self.expectedBundleID = expectedBundleID
        self.expectedContainer = expectedContainer
        self.expectedChallengeDigest = expectedChallengeDigest
        self.scope = scope
        self.buffer = buffer
        statusValue = Self.status(for: .unavailable, dropped: 0, gap: true)
    }

    @discardableResult
    public func receive(_ notification: RawPrivilegedNotification, proof: EndpointBridgePeerProof) throws -> EndpointBufferResult? {
        try authenticate(proof)
        // Legacy direct fixtures may use an unmanaged bridge. Managed delivery must carry its epoch.
        guard deliveryEpoch == nil else { throw EndpointBridgeError.unavailable(statusValue.state) }
        return try ingest(notification)
    }

    @discardableResult
    public func receive(_ notification: RawPrivilegedNotification, proof: EndpointBridgePeerProof, epoch: EndpointDeliveryEpoch) throws -> EndpointBufferResult? {
        try authenticate(proof)
        guard acceptsDelivery, deliveryEpoch === epoch, epoch.isCurrent else { return nil }
        // No suspension between the epoch check and sequence/buffer/status mutation.
        return try ingest(notification)
    }

    @discardableResult
    public func setDeliveryState(_ state: EndpointBridgeState, epoch: EndpointDeliveryEpoch, proof: EndpointBridgePeerProof) throws -> Bool {
        try authenticate(proof)
        guard epoch.isCurrent else { return false }
        deliveryEpoch = epoch
        acceptsDelivery = state == .available
        if acceptsDelivery {
            streamID = nil
            lastSequence = nil
            pendingGap = hasStarted
            observedGap = hasStarted || buffer.hasGap
            hasStarted = true
        }
        statusValue = Self.status(for: state, dropped: totalDrops, gap: state != .available || pendingGap || observedGap || buffer.hasGap)
        return true
    }

    public func recordDeliveryLoss(_ count: Int, epoch: EndpointDeliveryEpoch, proof: EndpointBridgePeerProof) throws {
        try authenticate(proof)
        guard acceptsDelivery, deliveryEpoch === epoch, epoch.isCurrent, count > 0 else { return }
        ingressDrops = saturatingAdd(ingressDrops, count)
        pendingGap = true
        observedGap = true
        statusValue = Self.status(for: .overloaded, dropped: totalDrops, gap: true)
    }

    private func ingest(_ notification: RawPrivilegedNotification) throws -> EndpointBufferResult? {
        let discontinuity = streamID != nil && (streamID != notification.streamID || lastSequence.map { $0 == .max || $0 + 1 != notification.sequence } == true)
        let gap = pendingGap || discontinuity || buffer.hasGap
        let event: NormalizedPrivilegedEvent?
        do {
            event = try normalizer.normalize(notification, scope: scope, gapBefore: gap)
        } catch {
            pendingGap = true
            observedGap = true
            statusValue = Self.status(for: .droppedEvents, dropped: totalDrops, gap: true)
            throw error
        }
        streamID = notification.streamID
        lastSequence = notification.sequence
        pendingGap = gap
        observedGap = observedGap || gap
        // An excluded event still advances source sequence, but cannot hide a preceding gap.
        guard let event else {
            if gap { statusValue = Self.status(for: .droppedEvents, dropped: totalDrops, gap: true) }
            return nil
        }
        let result = buffer.append(event)
        switch result {
        case .dropped:
            pendingGap = true
            observedGap = true
            statusValue = Self.status(for: .overloaded, dropped: totalDrops, gap: true)
        default:
            pendingGap = false
            statusValue = Self.status(for: .available, dropped: totalDrops, gap: observedGap || buffer.hasGap)
        }
        return result
    }

    private var totalDrops: Int { saturatingAdd(ingressDrops, buffer.droppedEvents) }

    private func saturatingAdd(_ left: Int, _ right: Int) -> Int {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? .max : result.partialValue
    }

    public func drain(proof: EndpointBridgePeerProof) throws -> [NormalizedPrivilegedEvent] {
        try authenticate(proof)
        return buffer.drain()
    }

    public func transition(to state: EndpointBridgeState) {
        // Managed epochs cannot be resurrected by an unrelated legacy status update.
        guard deliveryEpoch == nil else { return }
        statusValue = Self.status(for: state, dropped: totalDrops, gap: state != .available || observedGap || buffer.hasGap)
    }

    public func status() -> EndpointBridgeStatus {
        if let deliveryEpoch, !deliveryEpoch.isCurrent {
            return Self.status(for: .unavailable, dropped: totalDrops, gap: true)
        }
        return statusValue
    }

    private func authenticate(_ proof: EndpointBridgePeerProof) throws {
        guard proof.teamID == expectedTeamID,
              proof.bundleID == expectedBundleID,
              proof.appGroupContainer == expectedContainer,
              proof.designatedRequirementSatisfied,
              constantTimeEqual(proof.challengeDigest, expectedChallengeDigest)
        else { throw EndpointBridgeError.unauthenticated }
    }

    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left.utf8), rhs = Array(right.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    public static func status(for state: EndpointBridgeState, dropped: Int, gap: Bool) -> EndpointBridgeStatus {
        let userAction = [.pendingUserApproval, .notEntitled, .notPermitted].contains(state)
        let transient = [.tooManyClients, .overloaded, .droppedEvents, .unavailable].contains(state)
        let limitation: String
        switch state {
        case .available: limitation = gap ? "Privileged events resumed after an evidence gap; exact claims remain event-local." : "Privileged metadata is available for complete events."
        case .pendingUserApproval: limitation = "System-extension approval is pending; fallback monitoring remains active."
        case .notEntitled: limitation = "The restricted Endpoint Security entitlement is absent; fallback monitoring remains active."
        case .notPermitted: limitation = "Full Disk Access is not granted; fallback monitoring remains active."
        case .tooManyClients: limitation = "Endpoint Security rejected another client; fallback monitoring remains active."
        case .overloaded: limitation = "The bounded bridge queue dropped metadata; exact attribution is unavailable across the gap."
        case .droppedEvents: limitation = "A sequence gap was detected; exact attribution is unavailable across the gap."
        case .unavailable: limitation = "The privileged observer is unavailable; fallback monitoring remains active."
        }
        return EndpointBridgeStatus(
            state: state,
            eventGap: gap,
            droppedEvents: dropped,
            fallbackActive: true,
            maximumConfidence: state == .available && !gap ? .exact : (userAction ? .inferred : .unknown),
            automaticRetry: transient,
            retryAfter: transient ? 5 : 60,
            requiresUserAction: userAction,
            limitations: [limitation]
        )
    }
}
