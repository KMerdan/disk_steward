import Foundation

public struct ProvenanceEngine: Sendable {
    public let matchingTolerance: TimeInterval

    public init(matchingTolerance: TimeInterval = 5) {
        self.matchingTolerance = min(60, max(0, matchingTolerance))
    }

    /// Re-evaluate workspace hypotheses against all retained registrations.
    /// A stored inference is not direct writer evidence and must not bypass a
    /// newly available competing session or an unknown observation bound.
    public func taskAttribution(
        for event: EvidenceStoreEvent, currentClaim: ProvenanceClaim?,
        registrations: [AgentSessionRegistration], hasObservationGap: Bool
    ) -> ProvenanceClaim? {
        if let claim = currentClaim {
            guard claim.timingBasis == "observation-bounds", claim.hasValidChronology,
                  claim.contradictions.isEmpty, claim.event.eventID == event.eventID,
                  claim.event.path == event.path, claim.event.operation == event.operation,
                  claim.event.logicalDelta == event.logicalDelta,
                  claim.event.allocatedDelta == event.allocatedDelta,
                  // Codable Date retains reference-date seconds; SQLite stores
                  // Unix seconds. Converting between the two bases can move the
                  // last binary digit, so exact equality intermittently rejected
                  // the same observation and silently reported the task as
                  // unknown. Tolerate representation error only; a microsecond
                  // is far below any occurrence bound and does not widen the
                  // attribution interval.
                  abs(claim.event.observedAt.timeIntervalSince1970 - event.observedAt.timeIntervalSince1970) < Self.observedAtTolerance
            else { return nil }
            let directMethods = ["direct-process-file-and-task-observation", "registered-process-tree-with-incomplete-operation"]
            if directMethods.contains(claim.method), claim.actor != nil,
               claim.confidence == .exact || claim.confidence == .toolLinked,
               claim.support.contains(where: { $0.kind == .endpointSecurity }),
               claim.support.contains(where: { $0.kind == .processAncestry }),
               let session = claim.session, session.relationship == "registered-process-ancestor",
               registrations.contains(where: { $0.registrationID == session.registrationID && $0.sessionID == session.sessionID }) {
                return claim
            }
            // A known operator with no task link, or an explicitly unknown
            // claim, must not be upgraded merely because some competing
            // registration history was later retired.
            guard claim.actor == nil, claim.session != nil, claim.confidence == .inferred else { return nil }
        }
        let input: ProvenanceInput
        if let currentClaim {
            input = .init(event: event, retainingOccurrenceOf: currentClaim,
                registrations: registrations, fseventGap: hasObservationGap)
        } else {
            guard event.timing != nil else { return nil }
            input = .init(event: event, fseventGap: hasObservationGap,
                registrations: registrations, isHistorical: true)
        }
        let claim = attribute(input)
        if let previous = currentClaim?.session,
           claim.session?.registrationID != previous.registrationID { return nil }
        return claim.session == nil ? nil : claim
    }

    /// Maximum representation error accepted when matching a retained claim's
    /// observation time against the persisted event (seconds).
    public static let observedAtTolerance: TimeInterval = 1e-6

    public func attribute(_ input: ProvenanceInput) -> ProvenanceClaim {
        guard input.hasValidChronology else {
            return ProvenanceClaim(
                event: input.event, actor: nil, session: nil, confidence: .unknown,
                method: "invalid-evidence-chronology", support: [],
                limitations: ["Contradictory or non-finite timestamps cannot support writer or task attribution."],
                claimID: input.claimID, detectedAt: input.detectedAt,
                occurredStart: input.occurredStart, occurredEnd: input.occurredEnd,
                contradictions: input.contradictions + ["Evidence chronology is invalid; original endpoints were not reordered."],
                supersedesClaimID: input.supersedesClaimID
            )
        }
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

        if let privileged = input.privilegedEvent, privilegedMatches(privileged, input: input) {
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

        // Even a task that covers only part of the possible interval competes
        // with a full-interval match. Looking only at discovery time, or first
        // discarding partial matches, can falsely select a unique task.
        let workspaceMatches = input.registrations.filter { registration in
            registration.registeredAt <= input.occurredEnd
                && (input.occurredStart.map { min(registration.endedAt ?? registration.expiresAt, registration.expiresAt) >= $0 } ?? true)
        }.filter { registration in
            registration.workspaceRoots.contains { contains(input.event.path, root: $0) }
        }
        if let start = input.occurredStart, workspaceMatches.count == 1, let registration = workspaceMatches.first,
           registration.covers(start), registration.covers(input.occurredEnd), !input.fseventGap {
            support.append(sessionReference(registration, supports: "One authenticated task covered this path and the complete possible occurrence interval."))
            return ProvenanceClaim(
                event: input.event,
                actor: nil,
                session: ProvenanceSession(registration: registration, relationship: "unique-workspace-and-time-overlap"),
                confidence: .inferred,
                method: input.isHistorical ? "historical-workspace-correlation" : "workspace-temporal-correlation",
                support: support,
                limitations: limitations + ["Workspace and time correlation is a hypothesis; it does not identify the writer process."],
                claimID: input.claimID,
                detectedAt: input.detectedAt,
                occurredStart: input.occurredStart,
                occurredEnd: input.occurredEnd,
                contradictions: input.contradictions,
                supersedesClaimID: input.supersedesClaimID
            )
        }

        if workspaceMatches.count > 1 {
            limitations.append("Multiple active task workspaces matched; selecting one would create a false attribution.")
        } else if input.fseventGap, !workspaceMatches.isEmpty {
            limitations.append("A task workspace matched, but the event-stream gap prevents a task attribution.")
        } else if input.occurredStart == nil {
            limitations.append("An unknown occurrence lower bound prevents workspace/time task attribution.")
        } else if !workspaceMatches.isEmpty {
            limitations.append("The task workspace overlapped only part of the possible occurrence interval; discovery-time activity cannot establish task attribution.")
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
            limitations: limitations,
            claimID: input.claimID,
            detectedAt: input.detectedAt,
            occurredStart: input.occurredStart,
            occurredEnd: input.occurredEnd,
            contradictions: input.contradictions,
            supersedesClaimID: input.supersedesClaimID
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

        let processMatches = input.registrations.filter { $0.covers(privileged.raw.observedAt) }.filter {
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
            limitations: limitations,
            claimID: input.claimID,
            detectedAt: input.detectedAt,
            occurredStart: input.occurredStart,
            occurredEnd: input.occurredEnd,
            observedAncestry: input.ancestry.records.values.sorted {
                ($0.identity.pid, $0.identity.startTime) < ($1.identity.pid, $1.identity.startTime)
            },
            contradictions: input.contradictions,
            supersedesClaimID: input.supersedesClaimID
        )
    }

    private func privilegedMatches(_ privileged: NormalizedPrivilegedEvent, input: ProvenanceInput) -> Bool {
        let event = input.event
        guard input.occurredStart.map({ privileged.raw.observedAt >= $0 }) ?? true,
              privileged.raw.observedAt <= input.occurredEnd,
              abs(privileged.raw.observedAt.timeIntervalSince(event.observedAt)) <= matchingTolerance,
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
