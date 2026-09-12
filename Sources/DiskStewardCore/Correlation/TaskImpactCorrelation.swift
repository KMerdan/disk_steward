import Foundation

public struct CorrelationObservation: Equatable, Sendable {
    public let event: EvidenceStoreEvent
    public let writer: ProcessIdentity?

    public init(event: EvidenceStoreEvent, writer: ProcessIdentity?) {
        self.event = event
        self.writer = writer
    }
}

public struct CorrelatedEvidence: Equatable, Sendable {
    public let event: EvidenceStoreEvent
    public let sessionID: String?
    public let confidence: EvidenceStoreEvent.Confidence
    public let method: String
    public let limitations: [String]
}

public struct TaskImpact: Equatable, Sendable {
    public let sessionID: String
    public let eventIDs: [String]
    public let logicalDelta: Int64
    public let allocatedDelta: Int64
    public let confidence: EvidenceStoreEvent.Confidence
    public let limitations: [String]
}

public struct TaskImpactCorrelationEngine: Sendable {
    public init() {}

    public func correlate(
        _ observations: [CorrelationObservation],
        registrations: [AgentSessionRegistration],
        ancestry: ProcessAncestrySnapshot
    ) -> [CorrelatedEvidence] {
        observations.map { observation in
            let valid = registrations.filter { $0.covers(observation.event.observedAt) }

            if let writer = observation.writer {
                let processMatches = valid.filter { ancestry.contains(writer, inTreeRootedAt: $0.process) }
                if processMatches.count == 1, let match = processMatches.first {
                    return CorrelatedEvidence(
                        event: observation.event,
                        sessionID: match.sessionID,
                        confidence: .toolLinked,
                        method: "registered-process-tree",
                        limitations: ["Process ancestry links the writer to the registered task but does not independently prove the file operation."]
                    )
                }
                if processMatches.count > 1 {
                    return unknown(observation.event, reason: "The observed process tree matches multiple active task registrations.")
                }
            }

            let workspaceMatches = valid.filter { registration in
                registration.workspaceRoots.contains { contains(observation.event.path, root: $0) }
            }
            if workspaceMatches.count == 1, let match = workspaceMatches.first {
                return CorrelatedEvidence(
                    event: observation.event,
                    sessionID: match.sessionID,
                    confidence: .inferred,
                    method: "workspace-temporal-correlation",
                    limitations: ["The path and time overlap one registered workspace, but process ancestry did not identify the writer."]
                )
            }
            if workspaceMatches.count > 1 {
                return unknown(observation.event, reason: "The path and time overlap multiple agent tasks; no task was selected.")
            }
            return unknown(observation.event, reason: "No active registered process tree or unique workspace matched this event.")
        }
    }

    public func impact(for sessionID: String, correlated: [CorrelatedEvidence]) -> TaskImpact {
        let events = correlated.filter { $0.sessionID == sessionID }
        let order: [EvidenceStoreEvent.Confidence] = [.exact, .toolLinked, .inferred, .unknown]
        let weakest = events.map(\.confidence).max {
            (order.firstIndex(of: $0) ?? 3) < (order.firstIndex(of: $1) ?? 3)
        } ?? .unknown
        return TaskImpact(
            sessionID: sessionID,
            eventIDs: events.map(\.event.eventID).sorted(),
            logicalDelta: events.reduce(0) { $0 + $1.event.logicalDelta },
            allocatedDelta: events.reduce(0) { $0 + $1.event.allocatedDelta },
            confidence: weakest,
            limitations: Array(Set(events.flatMap(\.limitations))).sorted()
        )
    }

    private func unknown(_ event: EvidenceStoreEvent, reason: String) -> CorrelatedEvidence {
        CorrelatedEvidence(
            event: event,
            sessionID: nil,
            confidence: .unknown,
            method: "unavailable",
            limitations: [reason]
        )
    }

    private func contains(_ path: String, root: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot == "/" ? "/" : normalizedRoot + "/")
    }
}
