import Foundation

public struct ProvenanceEngine: Sendable {
    public let matchingTolerance: TimeInterval

    public init(matchingTolerance: TimeInterval = 5) {
        self.matchingTolerance = min(60, max(0, matchingTolerance))
    }

    public func attribute(_ input: ProvenanceInput) -> ProvenanceClaim {
        let matchingHints = input.fsevents.filter { hint in
            samePath(hint.path, input.event.path)
                && abs(hint.observedAt.timeIntervalSince(input.event.observedAt)) <= matchingTolerance
        }
        var support = matchingHints.map {
            ProvenanceSourceReference(
                kind: .fsevents,
                identifier: String($0.eventID),
                supports: "Path activity was reported as \($0.kind.rawValue); the hint does not identify a writer."
            )
        }
        support.append(
            ProvenanceSourceReference(
                kind: .metadataSnapshot,
                identifier: input.event.eventID,
                supports: "Metadata comparison measured the operation and byte delta."
            )
        )

        if let privileged = input.privilegedEvent, privilegedMatches(privileged, event: input.event) {
            return claimFromPrivileged(privileged, input: input, support: support)
        }

        var limitations: [String] = []
        if input.privilegedEvent != nil {
            limitations.append("A privileged notification was present but did not match this path, operation, time, and measured size change.")
        } else {
            limitations.append("No matching privileged process/file notification was available.")
        }
        if input.fseventGap {
            limitations.append("FSEvents reported a history gap; activity may be incomplete.")
        }
        if input.isHistorical {
            support.append(.init(kind: .historicalRecord, identifier: input.event.eventID, supports: "The event predates direct provenance capture."))
            limitations.append("Historical metadata cannot establish the process that performed the operation.")
        }

        let workspaceMatches = activeRegistrations(input).filter { registration in
            registration.workspaceRoots.contains { contains(input.event.path, root: $0) }
        }
        if workspaceMatches.count == 1, let registration = workspaceMatches.first, !input.fseventGap {
            support.append(sessionReference(registration, supports: "One authenticated active task covered this path and observation time."))
            return ProvenanceClaim(
                event: input.event,
                actor: nil,
                session: ProvenanceSession(registration: registration, relationship: "unique-workspace-and-time-overlap"),
                confidence: .inferred,
                method: input.isHistorical ? "historical-workspace-correlation" : "workspace-temporal-correlation",
                support: support,
                limitations: limitations + ["Workspace and time correlation is a hypothesis; it does not identify the writer process."]
            )
        }

        if workspaceMatches.count > 1 {
            limitations.append("Multiple active task workspaces matched; selecting one would create a false attribution.")
        } else if input.fseventGap, !workspaceMatches.isEmpty {
            limitations.append("A task workspace matched, but the event-stream gap prevents a task attribution.")
        } else {
            limitations.append("No unique active task context supports an actor claim.")
        }
        return ProvenanceClaim(
            event: input.event,
            actor: nil,
            session: nil,
            confidence: .unknown,
            method: "insufficient-causal-evidence",
            support: support,
            limitations: limitations
        )
    }

    private func claimFromPrivileged(
        _ privileged: NormalizedPrivilegedEvent,
        input: ProvenanceInput,
        support initialSupport: [ProvenanceSourceReference]
    ) -> ProvenanceClaim {
        var support = initialSupport
        support.append(
            .init(
                kind: .endpointSecurity,
                identifier: privileged.raw.eventID,
                supports: "A notification-only observer linked this process identity and file identity to the operation."
            )
        )
        support.append(
            .init(
                kind: .processAncestry,
                identifier: processReference(privileged.raw.process),
                supports: "Process identity uses PID and start time to resist PID reuse."
            )
        )

        let processMatches = activeRegistrations(input).filter {
            input.ancestry.contains(privileged.raw.process, inTreeRootedAt: $0.process)
        }
        let registration = !input.isHistorical && processMatches.count == 1 ? processMatches.first : nil
        if let registration {
            support.append(sessionReference(registration, supports: "Authenticated process ancestry linked the writer to one active task."))
        }

        var limitations = privileged.limitations
        if !input.isHistorical, processMatches.count > 1 {
            limitations.append("The process tree matched multiple active task sessions; no task was selected.")
        }
        if input.ancestry.truncated {
            limitations.append("The process ancestry snapshot was truncated.")
        }
        if input.fseventGap || privileged.gapBefore {
            limitations.append("A source sequence gap means the observed activity may be incomplete.")
        }
        if input.isHistorical {
            limitations.append("The record is historical, so current task/process context cannot upgrade it to exact.")
            support.append(.init(kind: .historicalRecord, identifier: input.event.eventID, supports: "The record was reconstructed after its observation window."))
        }

        let isExact = privileged.confidence == .exact
            && !privileged.gapBefore
            && !input.fseventGap
            && !input.isHistorical

        let confidence: EvidenceStoreEvent.Confidence
        let method: String
        if isExact {
            confidence = .exact
            method = registration == nil ? "direct-process-file-observation" : "direct-process-file-and-task-observation"
        } else if registration != nil && !input.isHistorical {
            confidence = .toolLinked
            method = "registered-process-tree-with-incomplete-operation"
            limitations.append("The task/process link is supported, but incomplete or gapped operation evidence prevents an exact claim.")
        } else {
            confidence = .inferred
            method = input.isHistorical ? "historical-privileged-correlation" : "incomplete-privileged-correlation"
            limitations.append("The observer evidence is incomplete; the attribution is retained only as a supported hypothesis.")
        }

        return ProvenanceClaim(
            event: input.event,
            actor: ProvenanceActor(process: privileged.raw.process, relationship: "observed-file-operator"),
            session: registration.map { ProvenanceSession(registration: $0, relationship: "registered-process-ancestor") },
            confidence: confidence,
            method: method,
            support: support,
            limitations: limitations
        )
    }

    private func activeRegistrations(_ input: ProvenanceInput) -> [AgentSessionRegistration] {
        input.registrations.filter { $0.covers(input.event.observedAt) }
    }

    private func privilegedMatches(_ privileged: NormalizedPrivilegedEvent, event: EvidenceStoreEvent) -> Bool {
        guard abs(privileged.raw.observedAt.timeIntervalSince(event.observedAt)) <= matchingTolerance,
              samePath(privileged.raw.destinationPath ?? privileged.raw.path, event.path),
              privileged.logicalDelta == event.logicalDelta,
              privileged.allocatedDelta == event.allocatedDelta
        else { return false }
        switch (privileged.raw.operation, event.operation) {
        case (.create, .create), (.rename, .rename), (.writeClose, .writeSummary), (.writeSummary, .writeSummary):
            return true
        default:
            return false
        }
    }

    private func sessionReference(_ registration: AgentSessionRegistration, supports: String) -> ProvenanceSourceReference {
        .init(kind: .agentSession, identifier: registration.registrationID.uuidString.lowercased(), supports: supports)
    }

    private func processReference(_ process: ProcessIdentity) -> String {
        "\(process.pid)@\(process.startTime.timeIntervalSince1970)"
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    private func contains(_ path: String, root: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot == "/" ? "/" : normalizedRoot + "/")
    }
}
