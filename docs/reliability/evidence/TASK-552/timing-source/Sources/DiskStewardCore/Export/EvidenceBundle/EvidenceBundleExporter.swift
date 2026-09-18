import CSQLite
import Foundation

public struct EvidenceBundleExporter: Sendable {
    public typealias IdentifierSource = @Sendable () -> String
    public typealias DateSource = @Sendable () -> Date

    private let productVersion: String
    private let identifierSource: IdentifierSource
    private let dateSource: DateSource
    private let temporaryDirectory: URL

    public init(
        productVersion: String = "0.1.0",
        identifierSource: @escaping IdentifierSource = { UUID().uuidString.lowercased() },
        dateSource: @escaping DateSource = Date.init,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.productVersion = productVersion
        self.identifierSource = identifierSource
        self.dateSource = dateSource
        self.temporaryDirectory = temporaryDirectory
    }

    public func export(
        store: EvidenceStore,
        options: EvidenceBundleExportOptions,
        to parentDirectory: URL,
        kind: EvidenceExportKind = .manual
    ) async throws -> EvidenceBundleExportResult {
        try Task.checkCancellation()
        guard options.from <= options.through else { throw EvidenceBundleExportError.invalidRange }
        let bundleID = identifierSource()
        guard isSafePathComponent(bundleID) else { throw EvidenceBundleExportError.unsafeBundleIdentifier }
        let bundleURL = parentDirectory.appending(path: "disk-steward-evidence-\(bundleID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        // Reserve before any suspension. A second request cannot overwrite this
        // inventory ID or acquire cleanup authority for an existing destination.
        let destination = try OwnedExportDirectory(exclusive: bundleURL)
        var published = false
        defer { if !published { destination.removeIfOwned() } }
        let createdAt = dateSource()
        let recordPath = kind == .manual ? bundleURL.path : nil
        let creatingRecord = EvidenceExportRecord(
            exportID: bundleID,
            kind: kind,
            requestedFrom: options.from,
            requestedThrough: options.through,
            actualFrom: nil,
            actualThrough: nil,
            precision: "pending",
            pathDetail: options.pathDetail,
            path: recordPath,
            bytes: 0,
            manifestSHA256: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            status: .creating,
            failure: nil
        )
        do {
            try await store.persistExportRecord(creatingRecord)
            // Keep backup sidecars and the raw stream under one private owner.
            // Never put the unredacted database backup in a user-selected (and
            // potentially cloud-synced) export destination.
            let scratch = try OwnedExportDirectory(exclusive: temporaryDirectory.appending(path: "disk-steward-work-\(UUID().uuidString)"))
            defer { scratch.removeIfOwned() }
            let temporaryBackup = scratch.url.appending(path: "evidence.sqlite")
            try await store.backup(to: temporaryBackup)
            try Task.checkCancellation()
            let view = try ConsistentEvidenceView(databaseURL: temporaryBackup, maximumReadBytes: options.limits.maximumReadBytes).read(options: options)
            let encoder = Self.encoder()
            let range = EvidenceBundleManifest.RequestedRange(
                from: Self.timestamp(options.from),
                through: Self.timestamp(options.through)
            )
            var limitations = view.limitations + view.snapshots.flatMap(\.limitations)
            if view.events.isEmpty { limitations.append("No raw events were retained inside the requested period.") }
            if view.snapshots.isEmpty { limitations.append("No storage snapshots were retained inside the requested period.") }
            limitations.append("Creator process and agent session fields are null unless a recorded attribution source established them.")

            let lineEncoder = Self.lineEncoder()
            let rawEventsURL = scratch.url.appending(path: "events.jsonl")
            FileManager.default.createFile(atPath: rawEventsURL.path, contents: nil)
            let rawEventsHandle = try FileHandle(forWritingTo: rawEventsURL)
            var notableEvents: [ExportedEvidenceEvent] = []
            var rawBytes = 0
            defer {
                try? rawEventsHandle.close()
                try? FileManager.default.removeItem(at: rawEventsURL)
            }
            for event in view.events {
                try Task.checkCancellation()
                let exported = exportEvent(event, claim: view.provenance[event.eventID], pathDetail: options.pathDetail)
                let line = try lineEncoder.encode(exported)
                guard line.count < options.limits.maximumPayloadBytes - rawBytes else { throw EvidenceBundleExportError.budgetExceeded }
                rawBytes += line.count + 1
                try rawEventsHandle.write(contentsOf: line)
                try rawEventsHandle.write(contentsOf: Data([0x0a]))
                notableEvents.append(exported)
                notableEvents.sort { lhs, rhs in
                    let leftMagnitude = lhs.size.allocatedDelta.magnitude
                    let rightMagnitude = rhs.size.allocatedDelta.magnitude
                    return leftMagnitude == rightMagnitude ? lhs.path < rhs.path : leftMagnitude > rightMagnitude
                }
                if notableEvents.count > 10 { notableEvents.removeLast(notableEvents.count - 10) }
            }
            try rawEventsHandle.close()
            let categories = try Dictionary(grouping: view.events, by: \.consumerCategory).map { name, events in
                EvidenceBundleSummary.Category(
                    name: name,
                    eventCount: events.count,
                    allocatedDelta: try Self.checkedSum(events.lazy.map(\.allocatedDelta))
                )
            }.sorted { $0.name < $1.name }
            let rollupDelta = try Self.checkedSum((view.hourly + view.daily).lazy.map(\.allocatedDelta))
            let eventDelta = try Self.checkedSum(view.events.lazy.map(\.allocatedDelta))
            let allocatedDelta = try Self.checkedSum([eventDelta, rollupDelta])
            let consumers = try currentConsumers(view.currentState, pathDetail: options.pathDetail)
            let growthAssessment: String
            if view.scope.detailCoverage != "complete"
                || (view.events.isEmpty && view.hourly.isEmpty && view.daily.isEmpty)
            {
                growthAssessment = "unavailable"
            } else if allocatedDelta > 0 {
                growthAssessment = "measured-growth"
            } else if allocatedDelta < 0 {
                growthAssessment = "measured-shrinkage"
            } else {
                growthAssessment = "measured-no-change"
            }
            if view.scope.roots.isEmpty {
                limitations.append("No configured file-detail root was present in the retained evidence view; only volume-capacity evidence may be available.")
            } else if view.scope.detailCoverage != "complete" {
                limitations.append("File-detail coverage is \(view.scope.detailCoverage) for the configured roots; absence cannot be treated as deletion.")
            }
            if growthAssessment == "unavailable" {
                limitations.append("Trustworthy file-detail growth is unavailable because no retained change or rollup rows cover the requested period.")
            }
            limitations = Array(Set(limitations)).sorted()
            let summary = EvidenceBundleSummary(
                schema: "evidence-summary-v1",
                requestedRange: range,
                volumeCapacityScope: "whole-volume-capacity",
                fileDetailRoots: view.scope.roots.map { sanitized(path: $0, detail: options.pathDetail) },
                exclusions: view.scope.exclusions.map { sanitized(path: $0, detail: options.pathDetail) },
                detailCoverage: view.scope.detailCoverage,
                stateAsOf: view.scope.stateAsOf.map(Self.timestamp),
                lastCompleteObservationAt: view.scope.lastCompleteObservationAt.map(Self.timestamp),
                openGapCount: view.scope.openGapCount,
                activeGenerationID: view.scope.activeGeneration?.generationID,
                activeGenerationStartedAt: view.scope.activeGeneration.map { Self.timestamp($0.startedAt) },
                scanCompletedRootCount: view.scope.activeGeneration?.completedRootCount ?? 0,
                scanRootCount: view.scope.activeGeneration?.rootPaths.count ?? 0,
                scanProcessedEntryCount: view.scope.activeGeneration?.processedEntryCount ?? 0,
                scanStagedFileCount: view.scope.activeGeneration?.stagedFileCount ?? 0,
                currentStateCount: view.currentStateCount,
                currentStateAllocatedBytes: view.currentStateAllocatedBytes,
                growthAssessment: growthAssessment,
                rawEventCount: view.events.count,
                snapshotCount: view.snapshots.count,
                hourlySummaryCount: view.hourly.count,
                dailySummaryCount: view.daily.count,
                allocatedDelta: allocatedDelta,
                categories: categories,
                largestCurrentDirectories: consumers.directories,
                largestCurrentFiles: consumers.files,
                cleanupReviewLeads: consumers.cleanupLeads,
                limitations: limitations
            )
            var integrityEntries: [EvidenceBundleIntegrity.Entry] = []
            var manifestEntries: [EvidenceBundleManifest.FileEntry] = []
            var payloadBytes = 0
            func admitPayload(_ bytes: Int) throws {
                try Task.checkCancellation()
                guard bytes >= 0, bytes <= options.limits.maximumPayloadBytes - payloadBytes else {
                    throw EvidenceBundleExportError.budgetExceeded
                }
                payloadBytes += bytes
            }
            func recordPayload(path: String, role: String, data: Data) throws {
                try admitPayload(data.count)
                let url = bundleURL.appending(path: path)
                try data.write(to: url, options: .atomic)
                let digest = SHA256Digest.hex(for: data)
                integrityEntries.append(.init(path: path, sha256: digest, bytes: data.count))
                manifestEntries.append(.init(path: path, role: role, sha256: digest, bytes: data.count))
            }
            func recordFilePayload(path: String, role: String, source: URL) throws {
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
                try admitPayload(bytes)
                let digest = try SHA256Digest.hex(forFileAt: source)
                integrityEntries.append(.init(path: path, sha256: digest, bytes: bytes))
                manifestEntries.append(.init(path: path, role: role, sha256: digest, bytes: bytes))
            }

            try recordPayload(
                path: "codex-brief.md",
                role: "codex-brief",
                data: Data((brief(summary: summary, events: notableEvents, generatedAt: createdAt) + "\n").utf8)
            )
            try recordPayload(path: "summary.json", role: "summary", data: try encoder.encode(summary))
            try recordPayload(
                path: "rollups.json",
                role: "summary",
                data: try encoder.encode(EvidenceBundleRollups(
                    schema: "evidence-rollups-v1",
                    hourly: view.hourly.map { rollupRow($0, pathDetail: options.pathDetail) },
                    daily: view.daily.map { rollupRow($0, pathDetail: options.pathDetail) }
                ))
            )
            let compressedEventsURL = bundleURL.appending(path: "events.jsonl.zlib")
            try ZlibCodec.compressFile(at: rawEventsURL, to: compressedEventsURL,
                                      maximumInputBytes: options.limits.maximumPayloadBytes,
                                      maximumOutputBytes: options.limits.maximumPayloadBytes - payloadBytes)
            try recordFilePayload(path: "events.jsonl.zlib", role: "events", source: compressedEventsURL)
            try recordPayload(
                path: "snapshots.json",
                role: "snapshot",
                data: try encoder.encode(EvidenceBundleSnapshots(schema: "storage-snapshots-v1", snapshots: view.snapshots))
            )
            try recordPayload(
                path: "current-state.json",
                role: "current-state",
                data: try encoder.encode(currentStatePayload(view.currentState, pathDetail: options.pathDetail))
            )
            try recordPayload(
                path: "provenance.json",
                role: "provenance",
                data: try encoder.encode(provenancePayload(view.provenanceChain, pathDetail: options.pathDetail))
            )
            try recordPayload(
                path: "sessions.json",
                role: "agent-sessions",
                data: try encoder.encode(sessionPayload(view.sessions, pathDetail: options.pathDetail))
            )
            try recordPayload(
                path: "coverage.json",
                role: "coverage",
                data: try encoder.encode(coveragePayload(
                    scope: view.scope,
                    observation: view.coverageGaps,
                    retention: view.retentionGaps,
                    pathDetail: options.pathDetail
                ))
            )
            try recordPayload(
                path: "lifecycle.json",
                role: "lifecycle",
                data: try encoder.encode(lifecyclePayload(
                    currentState: view.currentState,
                    events: view.events,
                    hourly: view.hourly,
                    daily: view.daily,
                    snapshots: view.snapshots,
                    retentionGaps: view.retentionGaps,
                    retentionPolicy: view.retentionPolicy,
                    options: options
                ))
            )
            let integrity = EvidenceBundleIntegrity(
                schema: "integrity-v1",
                algorithm: "sha256",
                files: integrityEntries
            )
            let integrityData = try encoder.encode(integrity)
            try recordPayload(path: "integrity.json", role: "integrity", data: integrityData)
            let manifest = EvidenceBundleManifest(
                schema: "export-manifest-v2",
                bundleID: bundleID,
                createdAt: Self.timestamp(createdAt),
                producer: .init(name: ProductIdentity.diskSteward.evidenceProducer, version: productVersion, evidenceSchemaVersion: 2),
                requestedRange: range,
                files: manifestEntries,
                limitations: limitations,
                privacy: .init(containsFileContents: false, containsEnvironment: false, pathDetail: options.pathDetail)
            )
            let manifestData = try encoder.encode(manifest)
            try admitPayload(manifestData.count)
            try manifestData.write(to: bundleURL.appending(path: "manifest.json"), options: .atomic)
            let evidenceDates = view.events.map(\.observedAt)
                + view.hourly.map(\.bucketStart)
                + view.daily.map(\.bucketStart)
                + view.snapshots.compactMap { Self.parseTimestamp($0.observedAt) }
            let precision = [
                view.events.isEmpty ? nil : "event",
                view.hourly.isEmpty ? nil : "hour",
                view.daily.isEmpty ? nil : "day",
            ].compactMap { $0 }.joined(separator: "+")
            let finalRecord = EvidenceExportRecord(
                exportID: bundleID,
                kind: kind,
                requestedFrom: options.from,
                requestedThrough: options.through,
                actualFrom: evidenceDates.min(),
                actualThrough: evidenceDates.max(),
                precision: precision.isEmpty ? "none" : precision,
                pathDetail: options.pathDetail,
                path: recordPath,
                bytes: Int64(payloadBytes),
                manifestSHA256: SHA256Digest.hex(for: manifestData),
                createdAt: createdAt,
                updatedAt: dateSource(),
                status: kind == .manual ? .available : .served,
                failure: nil
            )
            try await store.persistExportRecord(finalRecord)
            try Task.checkCancellation()
            published = true
            return EvidenceBundleExportResult(bundleURL: bundleURL, manifest: manifest, exportID: bundleID, kind: kind, ownership: destination)
        } catch {
            let failedRecord = EvidenceExportRecord(
                exportID: bundleID,
                kind: kind,
                requestedFrom: options.from,
                requestedThrough: options.through,
                actualFrom: nil,
                actualThrough: nil,
                precision: "none",
                pathDetail: options.pathDetail,
                path: recordPath,
                bytes: 0,
                manifestSHA256: nil,
                createdAt: createdAt,
                updatedAt: dateSource(),
                status: .failed,
                failure: error.localizedDescription
            )
            // Cancellation must not strand an inventory record in "creating".
            // This awaited cleanup task does not inherit caller cancellation.
            try? await Task { try await store.persistExportRecord(failedRecord) }.value
            throw error
        }
    }

    private func exportEvent(
        _ event: EvidenceStoreEvent,
        claim: ProvenanceClaim?,
        pathDetail: EvidencePathDetail
    ) -> ExportedEvidenceEvent {
        let method = claim?.method ?? {
            switch event.confidence {
            case .exact: "endpoint-security"
            case .toolLinked: "tool-registration"
            case .inferred: "snapshot-delta"
            case .unknown: "unknown"
            }
        }()
        let classification: (String, String)
        switch event.consumerCategory {
        case "developer-cache": classification = ("reproducible", "yellow")
        case "agent-artifact": classification = ("conditional", "yellow")
        case "downloads": classification = ("user-data", "red")
        default: classification = ("unknown", "unknown")
        }
        return ExportedEvidenceEvent(
            schema: "evidence-event-v2",
            eventID: event.eventID,
            observedAt: Self.timestamp(event.observedAt),
            timing: EvidenceEventTimingPresentation(timing: event.timing),
            operation: event.operation.rawValue,
            path: sanitized(path: event.path, detail: pathDetail),
            size: .init(
                logicalBefore: nil,
                logicalAfter: nil,
                logicalDelta: event.logicalDelta,
                allocatedBefore: nil,
                allocatedAfter: nil,
                allocatedDelta: event.allocatedDelta
            ),
            actor: .init(
                processID: claim?.actor.map { Int($0.process.pid) },
                executable: claim?.actor?.process.executablePath,
                command: nil,
                workingDirectory: nil,
                ancestorExecutables: claim?.observedAncestry.compactMap(\.identity.executablePath) ?? []
            ),
            session: .init(
                provider: claim?.session?.client.rawValue ?? "none",
                sessionID: claim?.session?.sessionID,
                title: nil,
                workingDirectory: nil
            ),
            attribution: .init(
                confidence: claim?.confidence.rawValue ?? event.confidence.rawValue,
                method: method,
                limitations: claim.map { $0.limitations + $0.contradictions.map { "Contradiction: \($0)" } }
                    ?? (event.confidence == .exact ? [] : ["No exact creator-process identity was recorded for this event."])
            ),
            classification: .init(
                consumerCategory: event.consumerCategory,
                reclaimability: classification.0,
                cleanupSafety: classification.1
            ),
            evidence: [.init(kind: "stored-metadata-event", reference: event.eventID)]
                + (claim?.support.map { .init(kind: $0.kind.rawValue, reference: $0.identifier) } ?? [])
        )
    }

    private func rollupRow(_ summary: EvidenceSummary, pathDetail: EvidencePathDetail) -> EvidenceBundleRollups.Row {
        .init(
            bucketStart: Self.timestamp(summary.bucketStart),
            path: sanitized(path: summary.path, detail: pathDetail),
            operation: summary.operation.rawValue,
            eventCount: summary.eventCount,
            logicalDelta: summary.logicalDelta,
            allocatedDelta: summary.allocatedDelta
        )
    }

    private func currentStatePayload(_ records: [CurrentFileStateRecord], pathDetail: EvidencePathDetail) -> JSONValue {
        .object([
            "schema": .string("current-file-state-v1"),
            "items": .array(records.map { record in
                .object([
                    "object_id": .string(record.objectID),
                    "identity_method": .string(record.identityMethod.rawValue),
                    "path": .string(sanitized(path: record.path, detail: pathDetail)),
                    "root_path": .string(sanitized(path: record.rootPath, detail: pathDetail)),
                    "consumer_category": .string(Self.consumerCategory(for: record.path)),
                    "logical_bytes": .integer(record.logicalBytes),
                    "allocated_bytes": .integer(record.allocatedBytes),
                    "modified_at": record.modifiedAt.map { .string(Self.timestamp($0)) } ?? .null,
                    "presence": .string(record.presence.rawValue),
                    "state_as_of_observation_id": .string(record.stateAsOfObservationID),
                    "observed_at": .string(Self.timestamp(record.observedAt)),
                    "actionable": .bool(record.actionable),
                ])
            }),
        ])
    }

    private func currentConsumers(
        _ records: [CurrentFileStateRecord],
        pathDetail: EvidencePathDetail
    ) throws -> (
        directories: [EvidenceBundleSummary.CurrentConsumer],
        files: [EvidenceBundleSummary.CurrentConsumer],
        cleanupLeads: [EvidenceBundleSummary.CurrentConsumer]
    ) {
        let present = records.filter { $0.presence == .present }
        let files = present
            .sorted { lhs, rhs in
                lhs.allocatedBytes == rhs.allocatedBytes ? lhs.path < rhs.path : lhs.allocatedBytes > rhs.allocatedBytes
            }
            .prefix(20)
            .map { record in
                EvidenceBundleSummary.CurrentConsumer(
                    path: sanitized(path: record.path, detail: pathDetail),
                    kind: "file",
                    itemCount: 1,
                    logicalBytes: record.logicalBytes,
                    allocatedBytes: record.allocatedBytes,
                    actionable: record.actionable
                )
            }
        let cleanup = present
            .filter(\.actionable)
            .sorted { lhs, rhs in
                lhs.allocatedBytes == rhs.allocatedBytes ? lhs.path < rhs.path : lhs.allocatedBytes > rhs.allocatedBytes
            }
            .prefix(20)
            .map { record in
                EvidenceBundleSummary.CurrentConsumer(
                    path: sanitized(path: record.path, detail: pathDetail),
                    kind: "file",
                    itemCount: 1,
                    logicalBytes: record.logicalBytes,
                    allocatedBytes: record.allocatedBytes,
                    actionable: true
                )
            }
        let grouped = Dictionary(grouping: present) {
            URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL.path
        }
        var directories: [EvidenceBundleSummary.CurrentConsumer] = []
        directories.reserveCapacity(grouped.count)
        for (path, children) in grouped {
            let logicalBytes = try Self.checkedSum(children.lazy.map(\.logicalBytes))
            let allocatedBytes = try Self.checkedSum(children.lazy.map(\.allocatedBytes))
            directories.append(EvidenceBundleSummary.CurrentConsumer(
                path: sanitized(path: path, detail: pathDetail),
                kind: "directory",
                itemCount: children.count,
                logicalBytes: logicalBytes,
                allocatedBytes: allocatedBytes,
                actionable: children.allSatisfy(\.actionable)
            ))
        }
        directories.sort { lhs, rhs in
            lhs.allocatedBytes == rhs.allocatedBytes ? lhs.path < rhs.path : lhs.allocatedBytes > rhs.allocatedBytes
        }

        return (Array(directories.prefix(20)), Array(files), Array(cleanup))
    }

    private func provenancePayload(_ claims: [ProvenanceClaim], pathDetail: EvidencePathDetail) -> JSONValue {
        let values: [JSONValue] = claims.map { claim in
            let actorPID: JSONValue = claim.actor.map { .integer(Int64($0.process.pid)) } ?? .null
            let actorExecutable: JSONValue = claim.actor?.process.executablePath.map {
                .string(sanitized(path: $0, detail: pathDetail))
            } ?? .null
            let sessionID: JSONValue = claim.session.map { .string($0.sessionID) } ?? .null
            let sessionClient: JSONValue = claim.session.map { .string($0.client.rawValue) } ?? .null
            let support: [JSONValue] = claim.support.map { source in
                .object(["kind": .string(source.kind.rawValue), "identifier": .string(source.identifier), "supports": .string(source.supports)])
            }
            return .object([
                "claim_id": .string(claim.claimID),
                "event_id": .string(claim.event.eventID),
                "path": .string(sanitized(path: claim.event.path, detail: pathDetail)),
                "confidence": .string(claim.confidence.rawValue),
                "method": .string(claim.method),
                "detected_at": .string(Self.timestamp(claim.detectedAt)),
                "occurred_start": .string(Self.timestamp(claim.occurredStart)),
                "occurred_end": .string(Self.timestamp(claim.occurredEnd)),
                "actor_pid": actorPID,
                "actor_executable": actorExecutable,
                "session_id": sessionID,
                "session_client": sessionClient,
                "support": .array(support),
                "limitations": .array(claim.limitations.map(JSONValue.string)),
                "contradictions": .array(claim.contradictions.map(JSONValue.string)),
                "supersedes_claim_id": claim.supersedesClaimID.map(JSONValue.string) ?? .null,
                "superseded_by_claim_id": claim.supersededByClaimID.map(JSONValue.string) ?? .null,
            ])
        }
        return .object([
            "schema": .string("provenance-chain-v2"),
            "claims": .array(values),
        ])
    }

    private func sessionPayload(_ sessions: [AgentSessionRegistration], pathDetail: EvidencePathDetail) -> JSONValue {
        .object([
            "schema": .string("agent-session-history-v1"),
            "sessions": .array(sessions.map { session in
                .object([
                    "registration_id": .string(session.registrationID.uuidString.lowercased()),
                    "session_id": .string(session.sessionID),
                    "client": .string(session.client.rawValue),
                    "lifecycle": .string(session.lifecycle.rawValue),
                    "pid": .integer(Int64(session.process.pid)),
                    "process_start_time": .string(Self.timestamp(session.process.startTime)),
                    "executable": session.process.executablePath.map { .string(sanitized(path: $0, detail: pathDetail)) } ?? .null,
                    "workspace_roots": .array(session.workspaceRoots.map { .string(sanitized(path: $0, detail: pathDetail)) }),
                    "registered_at": .string(Self.timestamp(session.registeredAt)),
                    "last_heartbeat_at": .string(Self.timestamp(session.lastHeartbeatAt)),
                    "expires_at": .string(Self.timestamp(session.expiresAt)),
                    "ended_at": session.endedAt.map { .string(Self.timestamp($0)) } ?? .null,
                    "task_context": session.taskContext.map(JSONValue.string) ?? .null,
                ])
            }),
        ])
    }

    private func coveragePayload(
        scope: ExportScopeSnapshot,
        observation: [EvidenceCoverageGap],
        retention: [RetentionCoverageGap],
        pathDetail: EvidencePathDetail
    ) -> JSONValue {
        .object([
            "schema": .string("evidence-coverage-v1"),
            "volume_capacity_scope": .string("whole-volume-capacity"),
            "file_detail_roots": .array(scope.roots.map { .string(sanitized(path: $0, detail: pathDetail)) }),
            "exclusions": .array(scope.exclusions.map { .string(sanitized(path: $0, detail: pathDetail)) }),
            "detail_coverage": .string(scope.detailCoverage),
            "state_as_of": scope.stateAsOf.map { .string(Self.timestamp($0)) } ?? .null,
            "last_complete_observation_at": scope.lastCompleteObservationAt.map { .string(Self.timestamp($0)) } ?? .null,
            "active_generation": scope.activeGeneration.map { generation in
                .object([
                    "generation_id": .string(generation.generationID),
                    "status": .string(generation.status.rawValue),
                    "started_at": .string(Self.timestamp(generation.startedAt)),
                    "updated_at": .string(Self.timestamp(generation.updatedAt)),
                    "processed_entry_count": .integer(Int64(generation.processedEntryCount)),
                    "staged_file_count": .integer(Int64(generation.stagedFileCount)),
                    "completed_root_count": .integer(Int64(generation.completedRootCount)),
                    "root_count": .integer(Int64(generation.rootPaths.count)),
                    "roots": .array(generation.roots.map { root in
                        .object([
                            "root_path": .string(sanitized(path: root.rootPath, detail: pathDetail)),
                            "status": .string(root.status.rawValue),
                            "processed_entry_count": .integer(Int64(root.processedEntryCount)),
                            "observed_file_count": .integer(Int64(root.observedFileCount)),
                            "limitations": .array(root.limitations.map(JSONValue.string)),
                        ])
                    }),
                    "limitations": .array(generation.limitations.map(JSONValue.string)),
                ])
            } ?? .null,
            "open_gap_count": .integer(Int64(scope.openGapCount)),
            "observation_gaps": .array(observation.map { gap in
                .object([
                    "gap_id": .string(gap.gapID),
                    "observation_id": .string(gap.observationID),
                    "root_path": .string(sanitized(path: gap.rootPath, detail: pathDetail)),
                    "reason": .string(gap.reason),
                    "started_at": .string(Self.timestamp(gap.startedAt)),
                    "ended_at": gap.endedAt.map { .string(Self.timestamp($0)) } ?? .null,
                ])
            }),
            "retention_gaps": .array(retention.map { gap in
                .object([
                    "gap_id": .string(gap.gapID),
                    "retention_run_id": .string(gap.retentionRunID),
                    "reason": .string(gap.reason),
                    "affected_precision": .string(gap.affectedPrecision),
                    "started_at": .string(Self.timestamp(gap.startedAt)),
                    "rows_removed": .integer(Int64(gap.rowsRemoved)),
                ])
            }),
        ])
    }

    private func lifecyclePayload(
        currentState: [CurrentFileStateRecord],
        events: [EvidenceStoreEvent],
        hourly: [EvidenceSummary],
        daily: [EvidenceSummary],
        snapshots: [StorageSnapshot],
        retentionGaps: [RetentionCoverageGap],
        retentionPolicy: EvidenceStoreRetentionPolicy?,
        options: EvidenceBundleExportOptions
    ) -> JSONValue {
        let dates = events.map(\.observedAt) + hourly.map(\.bucketStart) + daily.map(\.bucketStart)
            + snapshots.compactMap { Self.parseTimestamp($0.observedAt) }
        let actual: JSONValue = dates.isEmpty ? .null : .object([
            "from": .string(Self.timestamp(dates.min()!)),
            "through": .string(Self.timestamp(dates.max()!)),
        ])
        let precision: [JSONValue] = [
            events.isEmpty ? nil : JSONValue.string("raw"),
            hourly.isEmpty ? nil : JSONValue.string("hourly"),
            daily.isEmpty ? nil : JSONValue.string("daily"),
        ].compactMap { $0 }
        let counts: JSONValue = .object([
            "current_state": .integer(Int64(currentState.count)),
            "raw_events": .integer(Int64(events.count)),
            "hourly_rows": .integer(Int64(hourly.count)),
            "daily_rows": .integer(Int64(daily.count)),
            "snapshots": .integer(Int64(snapshots.count)),
            "retention_gaps": .integer(Int64(retentionGaps.count)),
        ])
        let effectivePolicy = retentionPolicy ?? (try? EvidenceStoreRetentionPolicy())
        let policy: JSONValue = .object([
            "source": .string(retentionPolicy == nil ? "application-default-no-retention-run-recorded" : "latest-recorded-retention-run"),
            "raw_event_days": .integer(Int64(effectivePolicy?.rawEventDays ?? 7)),
            "anomaly_detail_days": .integer(Int64(effectivePolicy?.anomalyDetailDays ?? 30)),
            "hourly_summary_days": .integer(Int64(effectivePolicy?.hourlySummaryDays ?? 30)),
            "daily_summary_days": .integer(Int64(effectivePolicy?.dailySummaryDays ?? 365)),
            "max_database_bytes": .integer(effectivePolicy?.maxDatabaseBytes ?? Int64(512 * 1_024 * 1_024)),
            "write_coalesce_seconds": .integer(Int64(effectivePolicy?.writeCoalesceSeconds ?? 15)),
            "preserve_unreviewed_anomalies": .bool(effectivePolicy?.preserveUnreviewedAnomalies ?? true),
        ])
        return .object([
            "schema": .string("exported-evidence-lifecycle-v1"),
            "requested_interval": .object(["from": .string(Self.timestamp(options.from)), "through": .string(Self.timestamp(options.through))]),
            "actual_interval": actual,
            "precision": .array(precision),
            "counts": counts,
            "policy": policy,
        ])
    }

    private func sanitized(path: String, detail: EvidencePathDetail) -> String {
        let shaped: String
        switch detail {
        case .full: shaped = path
        case .basename: shaped = URL(fileURLWithPath: path).lastPathComponent
        case .hashed: return "sha256:" + SHA256Digest.hex(for: Data(path.utf8))
        }
        let pattern = #"(?i)(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|AKIA[A-Z0-9]{16}|(?:token|password|secret|api[_-]?key)=[^/\\s]+)"#
        return shaped.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
    }

    private func brief(summary: EvidenceBundleSummary, events: [ExportedEvidenceEvent], generatedAt: Date) -> String {
        let categoryRows = summary.categories.isEmpty
            ? "| None retained | 0 | 0 |"
            : summary.categories.map { "| \($0.name) | \($0.eventCount) | \($0.allocatedDelta) |" }.joined(separator: "\n")
        let roots = summary.fileDetailRoots.isEmpty
            ? "- No configured file-detail roots are represented in this view."
            : summary.fileDetailRoots.map { "- `\($0)`" }.joined(separator: "\n")
        let exclusions = summary.exclusions.isEmpty
            ? "- No retained exclusion list was available."
            : summary.exclusions.map { "- `\($0)`" }.joined(separator: "\n")
        let directories = consumerRows(summary.largestCurrentDirectories)
        let files = consumerRows(summary.largestCurrentFiles)
        let cleanup = summary.cleanupReviewLeads.isEmpty
            ? "- No present, actionable cleanup-review leads are available."
            : summary.cleanupReviewLeads.prefix(10).map {
                "- `\($0.path)` — \(Self.byteCount($0.allocatedBytes)) allocated; review only, never auto-delete."
            }.joined(separator: "\n")
        let notableEvents = events.isEmpty
            ? "- No exact retained events are available for this period."
            : events.sorted { lhs, rhs in
                let leftMagnitude = lhs.size.allocatedDelta.magnitude
                let rightMagnitude = rhs.size.allocatedDelta.magnitude
                return leftMagnitude == rightMagnitude ? lhs.path < rhs.path : leftMagnitude > rightMagnitude
            }.prefix(10).map {
                "- `\($0.path)` — \($0.operation), \(Self.byteCount($0.size.allocatedDelta)) allocated delta; \($0.attribution.confidence) via \($0.attribution.method)."
            }.joined(separator: "\n")
        let growth: String
        switch summary.growthAssessment {
        case "measured-growth":
            growth = "Measured file-detail growth: +\(Self.byteCount(summary.allocatedDelta)) across retained changes and rollups."
        case "measured-shrinkage":
            growth = "Measured file-detail shrinkage: \(Self.byteCount(summary.allocatedDelta)) across retained changes and rollups."
        case "measured-no-change":
            growth = "Measured file-detail change is zero for the retained comparable interval."
        default:
            growth = "File-detail growth is unavailable; empty change history is not interpreted as zero growth."
        }
        let limitations = summary.limitations.map { "- \($0)" }.joined(separator: "\n")
        return """
        # Disk Steward Evidence Brief

        Generated: \(Self.timestamp(generatedAt))

        Requested period: \(summary.requestedRange.from) through \(summary.requestedRange.through)

        This bundle is a consistent, time-bounded view of previously recorded metadata. It does not rescan the disk.

        ## Scope and evidence age

        - Volume capacity scope: \(summary.volumeCapacityScope)
        - File-detail coverage: \(summary.detailCoverage)
        - Current state as of: \(summary.stateAsOf ?? "unavailable")
        - Last complete file-detail observation: \(summary.lastCompleteObservationAt ?? "none retained")
        - Open coverage gaps: \(summary.openGapCount)

        Active scan generation: \(summary.activeGenerationID ?? "none")
        - Started at: \(summary.activeGenerationStartedAt ?? "not active")
        - Root progress: \(summary.scanCompletedRootCount)/\(summary.scanRootCount)
        - Files staged: \(summary.scanStagedFileCount)
        - Filesystem entries processed: \(summary.scanProcessedEntryCount)

        File-detail roots:

        \(roots)

        Exclusions:

        \(exclusions)

        Whole-volume capacity does not imply whole-disk file, provenance, or cleanup coverage.

        ## Current consumers

        - Present current-state objects: \(summary.currentStateCount)
        - Present allocated bytes inside file-detail roots: \(Self.byteCount(summary.currentStateAllocatedBytes))

        Largest current directories:

        | Directory | Files | Allocated bytes |
        |---|---:|---:|
        \(directories)

        Largest current files:

        | File | Allocated bytes | Actionable |
        |---|---:|---:|
        \(files)

        ## Recent growth

        \(growth)

        - Raw events: \(summary.rawEventCount)
        - Hourly rollup rows: \(summary.hourlySummaryCount)
        - Daily rollup rows: \(summary.dailySummaryCount)
        - Storage snapshots: \(summary.snapshotCount)

        | Consumer category | Events | Allocated-byte delta |
        |---|---:|---:|
        \(categoryRows)

        ## Largest retained events

        \(notableEvents)

        ## Cleanup-review leads

        \(cleanup)

        These are present metadata records to investigate. Disk Steward does not claim that their allocated bytes are fully reclaimable and does not delete them.

        ## Provenance

        Read `provenance.json` and `sessions.json`. Missing actor or session evidence remains unknown and is never synthesized from timestamps or paths.

        ## Limitations

        \(limitations)

        ## How to inspect

        1. Verify every `manifest.json` byte count and SHA-256 digest against `integrity.json`.
        2. Read `coverage.json` before treating absence, growth, or cleanup leads as trustworthy.
        3. Read `current-state.json` for exact bounded present, stale, unknown, and out-of-scope records.
        4. Read `summary.json`, `rollups.json`, and `snapshots.json` for retained growth and capacity context.
        5. Decompress `events.jsonl.zlib` as zlib-compressed JSON Lines for exact retained changes.
        6. Read `provenance.json`, `sessions.json`, and `lifecycle.json` for attribution confidence and retained precision.

        Every attribution includes confidence and method. No file contents or environment variables are included.
        """
    }

    private func consumerRows(_ consumers: [EvidenceBundleSummary.CurrentConsumer]) -> String {
        guard !consumers.isEmpty else { return "| None available | 0 | 0 |" }
        return consumers.prefix(10).map { consumer in
            if consumer.kind == "directory" {
                return "| `\(consumer.path)` | \(consumer.itemCount) | \(Self.byteCount(consumer.allocatedBytes)) |"
            }
            return "| `\(consumer.path)` | \(Self.byteCount(consumer.allocatedBytes)) | \(consumer.actionable ? "yes" : "no") |"
        }.joined(separator: "\n")
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static func checkedSum<Values: Sequence>(_ values: Values) throws -> Int64 where Values.Element == Int64 {
        var total: Int64 = 0
        for value in values {
            try Task.checkCancellation()
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { throw EvidenceBundleExportError.invalidEvidence }
            total = sum.partialValue
        }
        return total
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func timestamp(_ date: Date) -> String {
        EvidenceTimestamp.format(date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        EvidenceTimestamp.parse(value)
    }

    private static func consumerCategory(for path: String) -> String {
        let lower = path.lowercased()
        if lower.contains("/documents/codex/") || lower.contains("/.claude/") { return "agent-artifact" }
        if lower.contains("/downloads/") { return "downloads" }
        if lower.contains("/deriveddata/") || lower.contains("/.build/") || lower.contains("/node_modules/") || lower.contains("/caches/") { return "developer-cache" }
        return "watched-root"
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func lineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct ExportScopeSnapshot {
    let roots: [String]
    let exclusions: [String]
    let detailCoverage: String
    let stateAsOf: Date?
    let lastCompleteObservationAt: Date?
    let openGapCount: Int
    let activeGeneration: MetadataScanGeneration?
}

private final class ExportReadBudget {
    var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

private struct ConsistentEvidenceView {
    private static let maximumRelatedRows = 25_000
    let databaseURL: URL
    private let budget: ExportReadBudget

    init(databaseURL: URL, maximumReadBytes: Int) {
        self.databaseURL = databaseURL
        budget = ExportReadBudget(remaining: maximumReadBytes)
    }

    /// Admit serialized bytes before copying or decoding each row. Also reject
    /// SQL errors instead of silently exporting the prefix before a failed step.
    private func step(_ statement: OpaquePointer, connection: SQLiteConnection) throws -> Int32 {
        try Task.checkCancellation()
        sqlite3_limit(sqlite3_db_handle(statement), SQLITE_LIMIT_LENGTH, 1_024 * 1_024)
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else {
            try Task.checkCancellation()
            if status == SQLITE_TOOBIG { throw EvidenceBundleExportError.budgetExceeded }
            throw connection.lastError(status)
        }
        if status == SQLITE_ROW {
            for column in 0..<sqlite3_column_count(statement) {
                let type = sqlite3_column_type(statement, column)
                let bytes = type == SQLITE_TEXT || type == SQLITE_BLOB ? Int(sqlite3_column_bytes(statement, column)) : 8
                guard bytes >= 0, bytes <= budget.remaining else { throw EvidenceBundleExportError.budgetExceeded }
                budget.remaining -= bytes
            }
        }
        return status
    }

    func read(options: EvidenceBundleExportOptions) throws -> (
        events: [EvidenceStoreEvent],
        snapshots: [StorageSnapshot],
        hourly: [EvidenceSummary],
        daily: [EvidenceSummary],
        provenance: [String: ProvenanceClaim],
        currentState: [CurrentFileStateRecord],
        currentStateCount: Int,
        currentStateAllocatedBytes: Int64,
        provenanceChain: [ProvenanceClaim],
        sessions: [AgentSessionRegistration],
        coverageGaps: [EvidenceCoverageGap],
        retentionGaps: [RetentionCoverageGap],
        retentionPolicy: EvidenceStoreRetentionPolicy?,
        scope: ExportScopeSnapshot,
        limitations: [String]
    ) {
        let connection = try SQLiteConnection(url: databaseURL)
        defer { connection.close() }
        let events = try readEvents(connection, options: options)
        let snapshots = try readSnapshots(connection, options: options)
        let hourly = try readSummaries(connection, table: "hourly_summaries", bucketSeconds: 3_600, options: options)
        let daily = try readSummaries(connection, table: "daily_summaries", bucketSeconds: 86_400, options: options)
        let provenance = try readCurrentProvenance(connection, options: options)
        let currentState = try readCurrentState(connection)
        let currentStateAggregate = try readCurrentStateAggregate(connection)
        let provenanceChain = try readProvenanceChain(connection, options: options)
        let sessions = try readSessions(connection, options: options)
        let coverageGaps = try readCoverageGaps(connection, options: options)
        let retentionGaps = try readRetentionGaps(connection, options: options)
        let retentionPolicy = try readLatestRetentionPolicy(connection)
        let scope = try readScope(connection, currentState: currentState, coverageGaps: coverageGaps)
        var limitations: [String] = []
        if events.truncated {
            limitations.append("Raw event detail was truncated at the requested \(options.maximumEvents)-event export limit.")
        }
        if !hourly.isEmpty || !daily.isEmpty {
            limitations.append("Rollup rows represent complete hour or day buckets and may overlap an exact requested-range boundary.")
        }
        if [snapshots.count, hourly.count, daily.count, provenance.count, currentState.count,
            provenanceChain.count, sessions.count, coverageGaps.count, retentionGaps.count]
            .contains(Self.maximumRelatedRows)
        {
            limitations.append("One or more related evidence tables reached the 25,000-row export cap; the bundle is explicitly truncated to preserve bounded memory.")
        }
        if let active = scope.activeGeneration {
            limitations.append(
                "File-detail scan generation \(active.generationID) is still active; current state remains as of the preceding complete observation and absence is not reconciled."
            )
        }
        return (
            events.values, snapshots, hourly, daily, provenance, currentState,
            currentStateAggregate.count, currentStateAggregate.allocatedBytes,
            provenanceChain, sessions, coverageGaps, retentionGaps, retentionPolicy, scope, limitations
        )
    }

    private func readScope(
        _ connection: SQLiteConnection,
        currentState: [CurrentFileStateRecord],
        coverageGaps: [EvidenceCoverageGap]
    ) throws -> ExportScopeSnapshot {
        struct LatestScope {
            let roots: [String]
            let exclusions: [String]
            let coverage: String
            let completedAt: Date
        }

        let latest: LatestScope? = try connection.withStatement(
            "SELECT s.roots_json, s.exclusions_json, o.coverage, o.completed_at FROM observation_runs o JOIN scope_versions s ON s.scope_version_id = o.scope_version_id ORDER BY o.completed_at DESC, o.observation_id DESC LIMIT 1"
        ) { statement in
            guard try step(statement, connection: connection) == SQLITE_ROW,
                  let rootsJSON = text(statement, 0),
                  let exclusionsJSON = text(statement, 1),
                  let coverage = text(statement, 2)
            else { return nil }
            let decoder = JSONDecoder()
            let roots = try decoder.decode([String].self, from: Data(rootsJSON.utf8))
            let exclusions = try decoder.decode([String].self, from: Data(exclusionsJSON.utf8))
            return LatestScope(
                roots: roots,
                exclusions: exclusions,
                coverage: coverage,
                completedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            )
        }

        let activeGeneration: MetadataScanGeneration? = try connection.withStatement(
            "SELECT progress FROM scan_generations WHERE status = 'active' ORDER BY updated_at DESC, generation_id DESC LIMIT 1"
        ) { statement in
            guard try step(statement, connection: connection) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(statement, 0)
            else { return nil }
            return try JSONDecoder().decode(
                MetadataScanGeneration.self,
                from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            )
        }

        let lastComplete: Date? = try connection.withStatement(
            "SELECT MAX(completed_at) FROM observation_runs WHERE coverage = 'complete'"
        ) { statement in
            guard try step(statement, connection: connection) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) != SQLITE_NULL
            else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
        let activeRootGapCount = activeGeneration?.roots.filter { $0.status != .completed }.count ?? 0
        let openGapCount = coverageGaps.filter { $0.endedAt == nil }.count + activeRootGapCount
        let fallbackRoots = Set(currentState.map(\.rootPath) + coverageGaps.map(\.rootPath)).sorted()
        let rawCoverage = latest?.coverage ?? (fallbackRoots.isEmpty ? "unavailable" : "stale")
        let detailCoverage = activeGeneration != nil
            ? "partial"
            : (openGapCount > 0 && rawCoverage == "complete" ? "partial" : rawCoverage)
        return ExportScopeSnapshot(
            roots: (activeGeneration?.rootPaths ?? (latest?.roots.isEmpty == false ? latest!.roots : fallbackRoots)).sorted(),
            exclusions: (activeGeneration?.excludedPaths ?? latest?.exclusions ?? []).sorted(),
            detailCoverage: ["complete", "partial", "stale", "unavailable"].contains(detailCoverage) ? detailCoverage : "unavailable",
            stateAsOf: currentState.map(\.observedAt).max() ?? latest?.completedAt,
            lastCompleteObservationAt: lastComplete,
            openGapCount: openGapCount,
            activeGeneration: activeGeneration
        )
    }

    private func readCurrentState(_ connection: SQLiteConnection) throws -> [CurrentFileStateRecord] {
        try connection.withStatement(
            "SELECT object_id, identity_method, path, root_path, scope_version_id, logical_bytes, allocated_bytes, modified_at, presence, state_as_of_observation_id, observed_at, actionable FROM current_file_state ORDER BY allocated_bytes DESC, path, object_id LIMIT ?"
        ) { statement in
            try connection.bind(Int64(Self.maximumRelatedRows), at: 1, in: statement)
            var values: [CurrentFileStateRecord] = []
            while try step(statement, connection: connection) == SQLITE_ROW {
                guard let objectID = text(statement, 0),
                      let identityText = text(statement, 1),
                      let identity = FileIdentityMethod(rawValue: identityText),
                      let path = text(statement, 2),
                      let root = text(statement, 3),
                      let scope = text(statement, 4),
                      let presenceText = text(statement, 8),
                      let presence = CurrentFilePresence(rawValue: presenceText),
                      let observationID = text(statement, 9)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    objectID: objectID,
                    identityMethod: identity,
                    path: path,
                    rootPath: root,
                    scopeVersionID: scope,
                    logicalBytes: sqlite3_column_int64(statement, 5),
                    allocatedBytes: sqlite3_column_int64(statement, 6),
                    modifiedAt: date(statement, 7),
                    presence: presence,
                    stateAsOfObservationID: observationID,
                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                    actionable: sqlite3_column_int64(statement, 11) != 0
                ))
            }
            return values
        }
    }

    private func readCurrentStateAggregate(_ connection: SQLiteConnection) throws -> (count: Int, allocatedBytes: Int64) {
        try connection.withStatement(
            "SELECT COUNT(*), COALESCE(SUM(allocated_bytes), 0) FROM current_file_state WHERE presence = 'present'"
        ) { statement in
            guard try step(statement, connection: connection) == SQLITE_ROW else { throw connection.lastError(SQLITE_CORRUPT) }
            return (Int(sqlite3_column_int64(statement, 0)), sqlite3_column_int64(statement, 1))
        }
    }

    private func readProvenanceChain(_ connection: SQLiteConnection, options: EvidenceBundleExportOptions) throws -> [ProvenanceClaim] {
        try connection.withStatement(
            "SELECT payload, superseded_by_claim_id FROM provenance_claims WHERE occurred_end >= ? AND occurred_start <= ? ORDER BY occurred_start, occurred_end, detected_at, claim_id LIMIT ?"
        ) { statement in
            try connection.bind(options.from.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(options.through.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(Self.maximumRelatedRows), at: 3, in: statement)
            var values: [ProvenanceClaim] = []
            while try step(statement, connection: connection) == SQLITE_ROW {
                var claim = try JSONDecoder().decode(ProvenanceClaim.self, from: try blob(statement, 0, connection: connection))
                if let superseded = text(statement, 1), claim.supersededByClaimID != superseded {
                    claim = ProvenanceClaim(
                        event: claim.event,
                        actor: claim.actor,
                        session: claim.session,
                        confidence: claim.confidence,
                        method: claim.method,
                        support: claim.support,
                        limitations: claim.limitations,
                        claimID: claim.claimID,
                        detectedAt: claim.detectedAt,
                        occurredStart: claim.occurredStart,
                        occurredEnd: claim.occurredEnd,
                        observedAncestry: claim.observedAncestry,
                        contradictions: claim.contradictions,
                        supersedesClaimID: claim.supersedesClaimID,
                        supersededByClaimID: superseded
                    )
                }
                values.append(claim)
            }
            return values
        }
    }

    private func readSessions(_ connection: SQLiteConnection, options: EvidenceBundleExportOptions) throws -> [AgentSessionRegistration] {
        try connection.withStatement(
            "SELECT payload FROM agent_sessions WHERE registered_at <= ? AND COALESCE(ended_at, expires_at) >= ? ORDER BY registered_at, registration_id LIMIT ?"
        ) { statement in
            try connection.bind(options.through.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(options.from.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(Self.maximumRelatedRows), at: 3, in: statement)
            var values: [AgentSessionRegistration] = []
            while try step(statement, connection: connection) == SQLITE_ROW {
                values.append(try JSONDecoder().decode(AgentSessionRegistration.self, from: try blob(statement, 0, connection: connection)))
            }
            return values
        }
    }

    private func readCoverageGaps(_ connection: SQLiteConnection, options: EvidenceBundleExportOptions) throws -> [EvidenceCoverageGap] {
        try connection.withStatement(
            "SELECT gap_id, observation_id, root_path, reason, started_at, ended_at FROM coverage_gaps WHERE started_at <= ? AND (ended_at IS NULL OR ended_at >= ?) ORDER BY started_at, gap_id LIMIT ?"
        ) { statement in
            try connection.bind(options.through.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(options.from.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(Self.maximumRelatedRows), at: 3, in: statement)
            var values: [EvidenceCoverageGap] = []
            while try step(statement, connection: connection) == SQLITE_ROW {
                guard let gapID = text(statement, 0), let observationID = text(statement, 1),
                      let root = text(statement, 2), let reason = text(statement, 3)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    gapID: gapID,
                    observationID: observationID,
                    rootPath: root,
                    reason: reason,
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    endedAt: date(statement, 5)
                ))
            }
            return values
        }
    }

    private func readRetentionGaps(_ connection: SQLiteConnection, options: EvidenceBundleExportOptions) throws -> [RetentionCoverageGap] {
        try connection.withStatement(
            "SELECT gap_id, retention_run_id, reason, affected_precision, started_at, rows_removed FROM retention_coverage_gaps WHERE started_at <= ? ORDER BY started_at, gap_id LIMIT ?"
        ) { statement in
            try connection.bind(options.through.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(Int64(Self.maximumRelatedRows), at: 2, in: statement)
            var values: [RetentionCoverageGap] = []
            while try step(statement, connection: connection) == SQLITE_ROW {
                guard let gapID = text(statement, 0), let runID = text(statement, 1),
                      let reason = text(statement, 2), let precision = text(statement, 3)
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    gapID: gapID,
                    retentionRunID: runID,
                    reason: reason,
                    affectedPrecision: precision,
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    rowsRemoved: Int(sqlite3_column_int64(statement, 5))
                ))
            }
            return values
        }
    }

    private func readLatestRetentionPolicy(_ connection: SQLiteConnection) throws -> EvidenceStoreRetentionPolicy? {
        try connection.withStatement(
            "SELECT policy FROM retention_runs ORDER BY started_at DESC, run_id DESC LIMIT 1"
        ) { statement in
            guard try step(statement, connection: connection) == SQLITE_ROW else { return nil }
            return try JSONDecoder().decode(
                EvidenceStoreRetentionPolicy.self,
                from: try blob(statement, 0, connection: connection)
            )
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func date(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32, connection: SQLiteConnection) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0 else { throw connection.lastError(SQLITE_CORRUPT) }
        if count == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { throw connection.lastError(SQLITE_CORRUPT) }
        return Data(bytes: bytes, count: count)
    }

    private func readCurrentProvenance(
        _ connection: SQLiteConnection,
        options: EvidenceBundleExportOptions
    ) throws -> [String: ProvenanceClaim] {
        try connection.withStatement(
            "SELECT event_id, payload FROM provenance_claims WHERE superseded_by_claim_id IS NULL AND occurred_end >= ? AND occurred_start <= ? ORDER BY detected_at, claim_id LIMIT ?"
        ) { statement in
            try connection.bind(options.from.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(options.through.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(Self.maximumRelatedRows), at: 3, in: statement)
            var values: [String: ProvenanceClaim] = [:]
            while try step(statement, connection: connection) == SQLITE_ROW {
                guard let eventID = sqlite3_column_text(statement, 0) else { throw connection.lastError(SQLITE_CORRUPT) }
                let byteCount = Int(sqlite3_column_bytes(statement, 1))
                guard byteCount >= 0, let bytes = sqlite3_column_blob(statement, 1) else {
                    throw connection.lastError(SQLITE_CORRUPT)
                }
                values[String(cString: eventID)] = try JSONDecoder().decode(
                    ProvenanceClaim.self,
                    from: Data(bytes: bytes, count: byteCount)
                )
            }
            return values
        }
    }

    private func readEvents(
        _ connection: SQLiteConnection,
        options: EvidenceBundleExportOptions
    ) throws -> (values: [EvidenceStoreEvent], truncated: Bool) {
        try connection.withStatement(
            """
            SELECT event_id, observed_at, operation, path, logical_delta, allocated_delta,
                   consumer_category, confidence, is_anomaly, is_reviewed,
                   occurred_start, occurred_end, detected_at
            FROM event_evidence WHERE observed_at >= ? AND observed_at <= ?
            ORDER BY observed_at, event_id LIMIT ?
            """
        ) { statement in
            try connection.bind(options.from.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(options.through.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(options.maximumEvents + 1), at: 3, in: statement)
            var values: [EvidenceStoreEvent] = []
            while try step(statement, connection: connection) == SQLITE_ROW {
                guard let eventID = sqlite3_column_text(statement, 0),
                      let operation = sqlite3_column_text(statement, 2),
                      let path = sqlite3_column_text(statement, 3),
                      let category = sqlite3_column_text(statement, 6),
                      let confidence = sqlite3_column_text(statement, 7),
                      let operationValue = EvidenceStoreEvent.Operation(rawValue: String(cString: operation)),
                      let confidenceValue = EvidenceStoreEvent.Confidence(rawValue: String(cString: confidence))
                else { throw connection.lastError(SQLITE_CORRUPT) }
                values.append(.init(
                    eventID: String(cString: eventID),
                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    operation: operationValue,
                    path: String(cString: path),
                    logicalDelta: sqlite3_column_int64(statement, 4),
                    allocatedDelta: sqlite3_column_int64(statement, 5),
                    consumerCategory: String(cString: category),
                    confidence: confidenceValue,
                    isAnomaly: sqlite3_column_int64(statement, 8) != 0,
                    isReviewed: sqlite3_column_int64(statement, 9) != 0
                ).withTiming(try EvidenceEventTiming.read(statement)))
            }
            let truncated = values.count > options.maximumEvents
            return (Array(values.prefix(options.maximumEvents)), truncated)
        }
    }

    private func readSnapshots(_ connection: SQLiteConnection, options: EvidenceBundleExportOptions) throws -> [StorageSnapshot] {
        try connection.withStatement(
            "SELECT payload FROM snapshots WHERE observed_at >= ? AND observed_at <= ? ORDER BY observed_at, snapshot_id LIMIT ?"
        ) { statement in
            try connection.bind(options.from.timeIntervalSince1970, at: 1, in: statement)
            try connection.bind(options.through.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(Self.maximumRelatedRows), at: 3, in: statement)
            var snapshots: [StorageSnapshot] = []
            while try step(statement, connection: connection) == SQLITE_ROW {
                let byteCount = Int(sqlite3_column_bytes(statement, 0))
                guard byteCount >= 0, let bytes = sqlite3_column_blob(statement, 0) else {
                    throw connection.lastError(SQLITE_CORRUPT)
                }
                let snapshot = try JSONDecoder().decode(StorageSnapshot.self, from: Data(bytes: bytes, count: byteCount))
                guard EvidenceTimestamp.parse(snapshot.observedAt) != nil else { throw EvidenceBundleExportError.invalidEvidence }
                snapshots.append(snapshot)
            }
            return snapshots
        }
    }

    private func readSummaries(
        _ connection: SQLiteConnection,
        table: String,
        bucketSeconds: TimeInterval,
        options: EvidenceBundleExportOptions
    ) throws -> [EvidenceSummary] {
        let firstBucket = floor(options.from.timeIntervalSince1970 / bucketSeconds) * bucketSeconds
        return try connection.withStatement(
            "SELECT bucket_start, path, operation, event_count, logical_delta, allocated_delta FROM \(table) WHERE bucket_start >= ? AND bucket_start <= ? ORDER BY bucket_start, path, operation LIMIT ?"
        ) { statement in
            try connection.bind(firstBucket, at: 1, in: statement)
            try connection.bind(options.through.timeIntervalSince1970, at: 2, in: statement)
            try connection.bind(Int64(Self.maximumRelatedRows), at: 3, in: statement)
            var rows: [EvidenceSummary] = []
            while try step(statement, connection: connection) == SQLITE_ROW {
                guard let path = sqlite3_column_text(statement, 1),
                      let operation = sqlite3_column_text(statement, 2),
                      let operationValue = EvidenceStoreEvent.Operation(rawValue: String(cString: operation))
                else { throw connection.lastError(SQLITE_CORRUPT) }
                rows.append(.init(
                    bucketStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    path: String(cString: path),
                    operation: operationValue,
                    eventCount: Int(sqlite3_column_int64(statement, 3)),
                    logicalDelta: sqlite3_column_int64(statement, 4),
                    allocatedDelta: sqlite3_column_int64(statement, 5)
                ))
            }
            return rows
        }
    }
}
