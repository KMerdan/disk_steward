import Foundation

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
        let discontinuity = streamID != nil && (streamID != notification.streamID || lastSequence.map { $0 + 1 != notification.sequence } == true)
        streamID = notification.streamID
        lastSequence = notification.sequence
        guard let event = try normalizer.normalize(notification, scope: scope, gapBefore: discontinuity || buffer.hasGap) else { return nil }
        let result = buffer.append(event)
        switch result {
        case .dropped:
            statusValue = Self.status(for: .overloaded, dropped: buffer.droppedEvents, gap: true)
        default:
            statusValue = Self.status(for: .available, dropped: buffer.droppedEvents, gap: discontinuity || buffer.hasGap)
        }
        return result
    }

    public func drain(proof: EndpointBridgePeerProof) throws -> [NormalizedPrivilegedEvent] {
        try authenticate(proof)
        return buffer.drain()
    }

    public func transition(to state: EndpointBridgeState) {
        statusValue = Self.status(for: state, dropped: buffer.droppedEvents, gap: state != .available || buffer.hasGap)
    }

    public func status() -> EndpointBridgeStatus { statusValue }

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
        var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
        for index in 0 ..< max(lhs.count, rhs.count) {
            difference |= (index < lhs.count ? lhs[index] : 0) ^ (index < rhs.count ? rhs[index] : 0)
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
