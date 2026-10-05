import DiskStewardCore

/// TASK-713: each tool's `outputSchema`, the typed contract of its
/// `structuredContent` on success. Fields every answer carries are required;
/// fields that depend on the evidence available are described but optional, so
/// a degraded answer still conforms. Schemas use the default JSON Schema
/// dialect (2020-12 for MCP 2025-11-25 and later) and name no `$schema`.
/// Error results carry no `structuredContent` and are not covered here.
enum MCPOutputSchemas {
    static func schema(for tool: String) -> JSONValue {
        switch tool {
        case "get_storage_summary":
            return answer(["storage-summary-v1"], required: ["volumes"], properties: [
                "volumes": array(object([
                    "mount_path": string, "total_bytes": integer, "used_bytes": integer, "available_bytes": integer,
                ])),
                "reserve_bytes": nullable("integer"),
                "free_above_reserve_bytes": nullable("integer"),
                "capacity_history": nullable("object"),
                "detail_status": string,
                "freshness": nullable("string"),
            ])
        case "get_health":
            return answer(["health-v1"], required: ["stores", "reviews"], properties: [
                "observed_at": string,
                "detail_store": string,
                "stores": .object(["type": .string("object")]),
                "reviews": array(object([
                    "scope": string, "state": string, "status": string, "coverage": string,
                    "item_count": integer, "worth_reviewing_bytes": integer,
                    "started_at": string, "completed_at": string, "limitations": strings,
                ])),
                "running": nullable("object"),
                "journal": nullable("object"),
                "growth_attribution": nullable("object"),
                "legacy_evidence": .object(["type": .string("array")]),
            ])
        case "explain_growth":
            return answer(["evidence-query-page-v1"], required: ["capacity_change"], page: true, properties: [
                "detail_status": string,
                "capacity_change": .object(["type": .string("object"), "required": .array([.string("status")]),
                                            "properties": .object(["status": string, "used_delta_bytes": integer])]),
                "measured_growth": nullable("object"),
                "changed_directories": .object(["type": .array([.string("object"), .string("null")]), "properties": .object([
                    "items": array(object(["path": string, "changes": integer, "measured": boolean])),
                    "total": integer, "truncated": boolean,
                ])]),
                "journal_gaps": .object(["type": .string("array")]),
                "journal_coverage_start": nullable("string"),
                "journal_limitations": strings,
            ])
        case "list_review_items":
            return answer(["review-items-v1"], required: ["report", "items", "safety"], page: true, properties: [
                "report": nullable("object", properties: [
                    "report_id": string, "scope": string, "state": string, "coverage": string, "status": string,
                    "item_count": integer, "worth_reviewing_bytes": integer, "completed_at": string, "limitations": strings,
                ]),
                "items": array(reviewItem(full: false)),
                "safety": string,
                "available_scopes": strings,
            ])
        case "list_largest_objects":
            return answer(["largest-objects-v1"], required: ["items"], page: true, properties: [
                "scope": nullable("string"),
                "items": array(object([
                    "name": string, "path": string, "kind": string, "recreate_class": string,
                    "allocated_bytes": integer, "file_count": integer, "measured_at": string, "last_activity": string,
                ])),
                "available_scopes": strings,
            ])
        case "get_review_item_evidence":
            return answer(["review-item-evidence-v1"], required: ["item", "report", "safety"], properties: [
                "observed_at": string,
                "report": .object(["type": .string("object")]),
                "item": reviewItem(full: true),
                "safety": string,
            ])
        case "measure_path":
            return answer(["measure-path-v1"], properties: [
                "observed_at": string,
                "path": string,
                "status": string,
                "stop_reason": nullable("string"),
                "allocated_bytes": nullable("integer"),
                "entries_visited": nullable("integer"),
                "objects": array(object(["name": string, "path": string, "kind": string, "allocated_bytes": integer])),
                "joined_review": nullable("object"),
            ])
        case "list_active_agent_sessions":
            return answer(["active-agent-sessions-v1"], required: ["sessions"], page: true, properties: [
                "sessions": .object(["type": .string("array")]),
            ])
        case "get_task_impact":
            return answer(["task-impact-v2", "task-impact-v1"], properties: [
                "session_id": string,
                "observed_at": string,
                "coverage": string,
                "confidence": string,
                "directories": nullable("object"),
                "sessions": .object(["type": .string("array")]),
            ])
        case "export_evidence":
            return answer(["evidence-export-v2", "inline-evidence-bundle-v1"], properties: [
                "observed_at": string,
                "requested_interval": nullable("object"),
                "steward": nullable("object"),
                "legacy": nullable("object"),
            ])
        default:
            return .object(["type": .string("object")])
        }
    }

    // MARK: Building blocks

    private static let string: JSONValue = .object(["type": .string("string")])
    private static let integer: JSONValue = .object(["type": .string("integer")])
    private static let boolean: JSONValue = .object(["type": .string("boolean")])
    private static let strings: JSONValue = .object(["type": .string("array"), "items": .object(["type": .string("string")])])

    /// Every answer names its schema and states its limitations.
    private static func answer(_ schemas: [String], required: [String] = [], page: Bool = false, properties: [String: JSONValue]) -> JSONValue {
        var all = properties
        all["schema"] = .object(["type": .string("string"), "enum": .array(schemas.map(JSONValue.string))])
        all["limitations"] = strings
        var needed = ["schema", "limitations"] + required
        if page {
            // A degraded explain_growth page has no count or budget to report.
            all["matched_count"] = nullable("integer")
            all["returned_count"] = integer
            all["truncated"] = boolean
            all["next_cursor"] = nullable("string")
            all["budget"] = nullable("object")
            needed += ["returned_count", "truncated", "next_cursor"]
        }
        return .object(["type": .string("object"), "required": .array(needed.map(JSONValue.string)), "properties": .object(all)])
    }

    private static func object(_ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties)])
    }

    private static func array(_ items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": items])
    }

    private static func nullable(_ type: String, properties: [String: JSONValue]? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .array([.string(type), .string("null")])]
        if let properties { schema["properties"] = .object(properties) }
        return .object(schema)
    }

    private static func reviewItem(full: Bool) -> JSONValue {
        var properties: [String: JSONValue] = [
            "item_id": string, "rank": integer, "name": string, "path": string, "kind": string, "recreate_class": string,
            "allocated_bytes": integer,
            "evidence": .object(["type": .string("string"), "enum": .array(["Verified now", "Stale", "Partial", "Unknown"].map(JSONValue.string))]),
            "verified_at": string, "origin": string, "rebuild_command": string, "cleanup_command": nullable("string"),
        ]
        if full {
            properties["why_it_may_be_disposable"] = strings
            properties["reasons_to_keep"] = strings
            properties["rebuild_command_known"] = boolean
            properties["present"] = boolean
            properties["size_is_lower_bound"] = boolean
            properties["reclaimable_bytes"] = integer
            properties["state"] = string
        }
        return .object(["type": .string("object"), "required": .array(["item_id", "path", "allocated_bytes", "evidence"].map(JSONValue.string)),
                        "properties": .object(properties)])
    }
}
