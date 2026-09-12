import Compression
import CryptoKit
import DiskStewardCore
import Foundation

actor AppEvidenceQueryBackend: DiskStewardIPCRequestHandling {
    private let store: EvidenceStore
    private let exporter = EvidenceBundleExporter()
    private let registry: AgentSessionRegistry
    private let challengeDigest: String
    private let processInspector = LocalProcessInspector()

    init(databaseURL: URL) throws {
        store = try EvidenceStore(url: databaseURL)
        let seed = Data(UUID().uuidString.utf8)
        challengeDigest = SHA256.hash(data: seed).map { String(format: "%02x", $0) }.joined()
        registry = AgentSessionRegistry(expectedPeerUID: getuid(), expectedChallengeDigest: challengeDigest)
    }

    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        switch method {
        case "tools/call":
            guard let object = payload.objectValue,
                  let name = object["name"]?.stringValue,
                  let arguments = object["arguments"]?.objectValue
            else { throw DiskStewardIPCError.remote(code: "invalid_request", message: "Missing tool name or arguments.", retryable: false) }
            return try await query(tool: name, arguments: arguments)
        case "resources/read":
            guard let uri = payload.objectValue?["uri"]?.stringValue else {
                throw DiskStewardIPCError.remote(code: "invalid_request", message: "Missing resource URI.", retryable: false)
            }
            return try await resource(uri: uri)
        case "sessions/register":
            return try await registerSession(payload: payload, peer: peer)
        case "sessions/end":
            return try await endSession(payload: payload, peer: peer)
        default:
            throw DiskStewardIPCError.remote(code: "unknown_method", message: "Unsupported local IPC method: \(method)", retryable: false)
        }
    }

    private func query(tool: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        switch tool {
        case "get_storage_summary":
            let snapshot = try VolumeSnapshotService().capture()
            let diagnostics = try await store.diagnostics()
            let volumes = snapshot.volumes.map { volume in
                JSONValue.object([
                    "mount_path": .string(volume.mountPath),
                    "total_bytes": .integer(volume.totalBytes),
                    "used_bytes": .integer(volume.usedBytes),
                    "available_bytes": .integer(volume.availableBytes),
                ])
            }
            return .object([
                "schema": .string("storage-summary-v1"),
                "observed_at": .string(snapshot.observedAt),
                "volumes": .array(volumes),
                "evidence_event_count": .integer(Int64(diagnostics.eventCount)),
                "database_bytes": .integer(diagnostics.storageBytes),
                "freshness": .string("live-volume-and-retained-evidence"),
                "limitations": .array(snapshot.limitations.map(JSONValue.string)),
            ])
        case "export_evidence":
            return try await inlineBundle(arguments: arguments)
        case "explain_growth":
            let bundle = try await inlineBundle(arguments: arguments)
            let object = bundle.objectValue ?? [:]
            return .object([
                "schema": .string("growth-explanation-v1"),
                "summary": object["summary"] ?? .null,
                "items": object["events"] ?? .array([]),
                "truncated": object["truncated"] ?? .bool(false),
                "limitations": limitations(from: object["manifest"]),
            ])
        case "get_provenance":
            let range = broadRange(arguments)
            let bundle = try await inlineBundle(arguments: range.merging(arguments) { _, new in new })
            let query = arguments["path_query"]?.stringValue?.lowercased() ?? ""
            let limit = Int(arguments["limit"]?.integerValue ?? 100)
            let events = eventArray(bundle).filter {
                $0.objectValue?["path"]?.stringValue?.lowercased().contains(query) == true
            }
            return .object([
                "schema": .string("provenance-query-v1"),
                "items": .array(Array(events.prefix(limit))),
                "truncated": .bool(events.count > limit),
                "limitations": limitations(from: bundle.objectValue?["manifest"]),
            ])
        case "find_cleanup_candidates":
            let range = broadRange(arguments)
            let bundle = try await inlineBundle(arguments: range.merging(arguments) { _, new in new })
            let minimum = arguments["minimum_bytes"]?.integerValue ?? 0
            let olderThanDays = Int(arguments["older_than_days"]?.integerValue ?? 0)
            let cutoff = Date().addingTimeInterval(-TimeInterval(olderThanDays) * 86_400)
            let limit = Int(arguments["limit"]?.integerValue ?? 100)
            let candidates = eventArray(bundle).filter {
                allocatedDelta($0) >= minimum
                    && allocatedDelta($0) > 0
                    && (olderThanDays == 0 || observedDate($0).map { $0 <= cutoff } == true)
            }
                .sorted { allocatedDelta($0) > allocatedDelta($1) }
            return .object([
                "schema": .string("cleanup-candidates-v1"),
                "items": .array(Array(candidates.prefix(limit))),
                "truncated": .bool(candidates.count > limit),
                "safety": .string("review-required-never-safe-to-delete-claim"),
                "limitations": .array([.string("Candidates are evidence for human review, not deletion instructions.")]),
            ])
        case "list_active_writers":
            let now = Date()
            let minutes = Int(arguments["minutes"]?.integerValue ?? 60)
            let limit = Int(arguments["limit"]?.integerValue ?? 100)
            let cutoff = now.addingTimeInterval(-TimeInterval(minutes) * 60)
            let registrations = try await registry.activeRegistrations(proof: proof(), now: now)
                .filter { $0.registeredAt >= cutoff }
                .prefix(limit)
            return .object([
                "schema": .string("active-writers-v1"),
                "writers": .array(registrations.map { registration in
                    .object([
                        "session_id": .string(registration.sessionID),
                        "client": .string(registration.client.rawValue),
                        "pid": .integer(Int64(registration.process.pid)),
                        "executable": registration.process.executablePath.map(JSONValue.string) ?? .null,
                        "confidence": .string("tool-linked"),
                        "method": .string("registered-process-tree"),
                    ])
                }),
                "limitations": .array([.string("Registered process trees are active task contexts; without direct provenance they are not proven file writers.")]),
            ])
        case "get_task_impact":
            return try await taskImpact(arguments: arguments)
        default:
            throw DiskStewardIPCError.remote(code: "unknown_tool", message: "Unknown read-only tool: \(tool)", retryable: false)
        }
    }

    private func resource(uri: String) async throws -> JSONValue {
        switch uri {
        case "disk-steward://status":
            let diagnostics = try await store.diagnostics()
            return .object([
                "schema": .string("service-status-v1"),
                "state": .string(diagnostics.integrity == "ok" ? "active" : "degraded"),
                "component": .string("evidence-store"),
                "detail": .string("SQLite schema \(diagnostics.schemaVersion), \(diagnostics.eventCount) retained raw events."),
                "limitations": .array([]),
            ])
        case "disk-steward://evidence-guide":
            return .object([
                "schema": .string("evidence-guide-v1"),
                "text": .string("Exact means a direct observer linked an operation to a process. Tool-linked means authenticated process ancestry linked a local task. Inferred is a supported hypothesis. Unknown means no actor claim is justified. Cleanup candidates always require human review."),
            ])
        default:
            throw DiskStewardIPCError.remote(code: "unknown_resource", message: "Unknown evidence resource.", retryable: false)
        }
    }

    private func registerSession(payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        guard let object = payload.objectValue,
              let sessionID = object["session_id"]?.stringValue,
              let clientName = object["client"]?.stringValue,
              let client = AgentClientKind(rawValue: clientName),
              case let .array(rootValues)? = object["workspace_roots"]
        else { throw DiskStewardIPCError.remote(code: "invalid_registration", message: "Session registration is incomplete.", retryable: false) }
        let roots = rootValues.compactMap(\.stringValue)
        guard roots.count == rootValues.count else {
            throw DiskStewardIPCError.remote(code: "invalid_registration", message: "Workspace roots must be strings.", retryable: false)
        }
        let requestedPID = Int32(object["process_pid"]?.integerValue ?? Int64(peer.pid))
        let ancestry = processInspector.snapshot(startingAt: peer.pid)
        guard let process = ancestry.records.keys.first(where: { $0.pid == requestedPID }) else {
            throw DiskStewardIPCError.remote(code: "invalid_registration", message: "The requested process is not the authenticated peer or one of its ancestors.", retryable: false)
        }
        let now = Date()
        let lease = min(max(TimeInterval(object["lease_seconds"]?.integerValue ?? 7_200), 60), 86_400)
        let registration = try await registry.register(
            SessionRegistrationRequest(
                client: client,
                sessionID: sessionID,
                process: process,
                workspaceRoots: roots,
                registeredAt: now,
                expiresAt: now.addingTimeInterval(lease)
            ),
            proof: proof(uid: peer.uid),
            now: now
        )
        return .object([
            "schema": .string("session-registration-result-v1"),
            "registration_id": .string(registration.registrationID.uuidString.lowercased()),
            "session_id": .string(registration.sessionID),
            "process_pid": .integer(Int64(registration.process.pid)),
            "confidence": .string("tool-linked"),
            "limitations": .array([.string("Registration links a local process tree to a task but does not prove individual file operations.")]),
        ])
    }

    private func endSession(payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue {
        guard let value = payload.objectValue?["registration_id"]?.stringValue,
              let id = UUID(uuidString: value)
        else { throw DiskStewardIPCError.remote(code: "invalid_registration", message: "registration_id is invalid.", retryable: false) }
        let ended = try await registry.end(registrationID: id, proof: proof(uid: peer.uid), now: Date())
        return .object([
            "schema": .string("session-end-result-v1"),
            "registration_id": .string(ended.registrationID.uuidString.lowercased()),
            "lifecycle": .string(ended.lifecycle.rawValue),
        ])
    }

    private func taskImpact(arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let sessionID = arguments["session_id"]?.stringValue else {
            throw DiskStewardIPCError.remote(code: "invalid_request", message: "session_id is required.", retryable: false)
        }
        let registrations = try await registry.activeRegistrations(proof: proof(), now: Date())
        guard registrations.contains(where: { $0.sessionID == sessionID }) else {
            throw DiskStewardIPCError.remote(code: "session_unavailable", message: "The session is not active or has expired.", retryable: false)
        }
        var queryArguments = broadRange(arguments)
        queryArguments["path_detail"] = .string("full")
        let bundle = try await inlineBundle(arguments: queryArguments)
        let events = eventArray(bundle).compactMap(evidenceEvent)
        let correlated = TaskImpactCorrelationEngine().correlate(
            events.map { CorrelationObservation(event: $0, writer: nil) },
            registrations: registrations,
            ancestry: .init(records: [])
        )
        let impact = TaskImpactCorrelationEngine().impact(for: sessionID, correlated: correlated)
        return .object([
            "schema": .string("task-impact-v1"),
            "session_id": .string(sessionID),
            "event_ids": .array(impact.eventIDs.map(JSONValue.string)),
            "logical_delta": .integer(impact.logicalDelta),
            "allocated_delta": .integer(impact.allocatedDelta),
            "confidence": .string(impact.confidence.rawValue),
            "limitations": .array(impact.limitations.map(JSONValue.string)),
        ])
    }

    private func inlineBundle(arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let fromText = arguments["from"]?.stringValue,
              let throughText = arguments["through"]?.stringValue,
              let from = ISO8601DateFormatter().date(from: fromText),
              let through = ISO8601DateFormatter().date(from: throughText),
              from < through
        else { throw DiskStewardIPCError.remote(code: "invalid_range", message: "A valid from/through range is required.", retryable: false) }
        let detail = EvidencePathDetail(rawValue: arguments["path_detail"]?.stringValue ?? "basename") ?? .basename
        let maximumEvents = Int(arguments["max_events"]?.integerValue ?? arguments["limit"]?.integerValue ?? 500)
        let parent = FileManager.default.temporaryDirectory.appending(path: "DiskStewardIPCExports", directoryHint: .isDirectory)
        let result = try await exporter.export(
            store: store,
            options: .init(from: from, through: through, pathDetail: detail, maximumEvents: min(max(maximumEvents, 1), 10_000)),
            to: parent
        )
        defer { try? FileManager.default.removeItem(at: result.bundleURL) }
        let manifest = try decodeJSON(result.bundleURL.appending(path: "manifest.json"))
        let summary = try decodeJSON(result.bundleURL.appending(path: "summary.json"))
        let rollups = try decodeJSON(result.bundleURL.appending(path: "rollups.json"))
        let snapshots = try decodeJSON(result.bundleURL.appending(path: "snapshots.json"))
        let brief = try String(contentsOf: result.bundleURL.appending(path: "codex-brief.md"), encoding: .utf8)
        let compressed = try Data(contentsOf: result.bundleURL.appending(path: "events.jsonl.zlib"))
        let eventData = try decompress(compressed)
        let events = String(decoding: eventData, as: UTF8.self).split(separator: "\n").map { line in
            try! JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        }
        let manifestObject = manifest.objectValue ?? [:]
        let limitations = manifestObject["limitations"] ?? .array([])
        let truncated = limitationsContainsTruncation(limitations)
        return .object([
            "schema": .string("inline-evidence-bundle-v1"),
            "manifest": manifest,
            "summary": summary,
            "rollups": rollups,
            "snapshots": snapshots,
            "events": .array(events),
            "brief": .string(brief),
            "truncated": .bool(truncated),
        ])
    }

    private func broadRange(_ arguments: [String: JSONValue]) -> [String: JSONValue] {
        var result = arguments
        result["from"] = result["from"] ?? .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86_400)))
        result["through"] = result["through"] ?? .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(1)))
        result["max_events"] = result["max_events"] ?? result["limit"] ?? .integer(500)
        return result
    }

    private func eventArray(_ bundle: JSONValue) -> [JSONValue] {
        guard case let .array(events)? = bundle.objectValue?["events"] else { return [] }
        return events
    }

    private func allocatedDelta(_ event: JSONValue) -> Int64 {
        event.objectValue?["size"]?.objectValue?["allocated_delta"]?.integerValue ?? 0
    }

    private func observedDate(_ event: JSONValue) -> Date? {
        event.objectValue?["observed_at"]?.stringValue.flatMap(parseTimestamp)
    }

    private func limitations(from manifest: JSONValue?) -> JSONValue {
        manifest?.objectValue?["limitations"] ?? .array([])
    }

    private func limitationsContainsTruncation(_ value: JSONValue) -> Bool {
        guard case let .array(values) = value else { return false }
        return values.contains { $0.stringValue?.lowercased().contains("truncat") == true }
    }

    private func evidenceEvent(_ value: JSONValue) -> EvidenceStoreEvent? {
        guard let object = value.objectValue,
              let id = object["event_id"]?.stringValue,
              let observedText = object["observed_at"]?.stringValue,
              let observed = parseTimestamp(observedText),
              let operationText = object["operation"]?.stringValue,
              let operation = EvidenceStoreEvent.Operation(rawValue: operationText),
              let path = object["path"]?.stringValue,
              let sizes = object["size"]?.objectValue,
              let logical = sizes["logical_delta"]?.integerValue,
              let allocated = sizes["allocated_delta"]?.integerValue,
              let classification = object["classification"]?.objectValue,
              let category = classification["consumer_category"]?.stringValue,
              let attribution = object["attribution"]?.objectValue,
              let confidenceText = attribution["confidence"]?.stringValue,
              let confidence = EvidenceStoreEvent.Confidence(rawValue: confidenceText)
        else { return nil }
        return EvidenceStoreEvent(
            eventID: id,
            observedAt: observed,
            operation: operation,
            path: path,
            logicalDelta: logical,
            allocatedDelta: allocated,
            consumerCategory: category,
            confidence: confidence
        )
    }

    private func proof(uid: uid_t = getuid()) -> SessionAuthenticationProof {
        SessionAuthenticationProof(peerUID: uid, socketMode: 0o600, challengeDigest: challengeDigest)
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func decodeJSON(_ url: URL) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var capacity = max(1_024, data.count * 4)
        for _ in 0 ..< 12 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0, written < capacity {
                output.count = written
                return output
            }
            capacity *= 2
        }
        throw DiskStewardIPCError.remote(code: "export_decode_failed", message: "Inline export detail could not be decoded.", retryable: false)
    }
}
