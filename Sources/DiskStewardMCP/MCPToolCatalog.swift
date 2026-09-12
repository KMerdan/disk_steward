import DiskStewardCore
import Foundation

enum MCPToolCatalog {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let names = [
        "get_storage_summary",
        "explain_growth",
        "get_provenance",
        "list_active_writers",
        "get_task_impact",
        "find_cleanup_candidates",
        "export_evidence",
    ]

    static let resourceURIs = ["disk-steward://status", "disk-steward://evidence-guide"]

    static var tools: [JSONValue] {
        [
            tool("get_storage_summary", "Return bounded current volume and monitored-scope totals with freshness and limitations.", properties: [:]),
            tool("explain_growth", "Explain growth for a bounded time range without unsupported attribution.", required: ["from", "through"], properties: [
                "from": .object(["type": .string("string")]),
                "through": .object(["type": .string("string")]),
                "limit": integer(minimum: 1, maximum: 500),
            ]),
            tool("get_provenance", "Return sanitized provenance observations for a bounded path query.", required: ["path_query"], properties: [
                "path_query": .object(["type": .string("string"), "maxLength": .integer(4_096)]),
                "limit": integer(minimum: 1, maximum: 500),
            ]),
            tool("list_active_writers", "Return recently observed writer identities and confidence within a bounded window.", properties: [
                "minutes": integer(minimum: 1, maximum: 1_440),
                "limit": integer(minimum: 1, maximum: 200),
            ]),
            tool("get_task_impact", "Summarize evidence correlated to one registered local agent session.", required: ["session_id"], properties: [
                "session_id": .object(["type": .string("string"), "maxLength": .integer(256)]),
                "limit": integer(minimum: 1, maximum: 500),
            ]),
            tool("find_cleanup_candidates", "List evidence-based review candidates without declaring any path safe to delete.", properties: [
                "minimum_bytes": integer(minimum: 0, maximum: Int64.max),
                "older_than_days": integer(minimum: 0, maximum: 3_650),
                "limit": integer(minimum: 1, maximum: 500),
            ]),
            tool("export_evidence", "Return a bounded inline evidence bundle equivalent to app export without modifying evidence.", required: ["from", "through"], properties: [
                "from": .object(["type": .string("string")]),
                "through": .object(["type": .string("string")]),
                "path_detail": .object(["type": .string("string"), "enum": .array([.string("full"), .string("basename"), .string("hashed")])]),
                "max_events": integer(minimum: 1, maximum: 10_000),
            ]),
        ]
    }

    static var resources: [JSONValue] {
        [
            .object([
                "uri": .string("disk-steward://status"),
                "name": .string("Disk Steward service status"),
                "mimeType": .string("application/json"),
                "description": .string("Current local evidence-service health, freshness, and limitations."),
            ]),
            .object([
                "uri": .string("disk-steward://evidence-guide"),
                "name": .string("Disk Steward evidence interpretation guide"),
                "mimeType": .string("text/markdown"),
                "description": .string("Meaning of confidence, methods, unknown deltas, and cleanup candidates."),
            ]),
        ]
    }

    static func validationError(tool: String, arguments: [String: JSONValue]) -> String? {
        let allowed: Set<String>
        let required: Set<String>
        switch tool {
        case "get_storage_summary":
            allowed = []; required = []
        case "explain_growth":
            allowed = ["from", "through", "limit"]; required = ["from", "through"]
        case "get_provenance":
            allowed = ["path_query", "limit"]; required = ["path_query"]
        case "list_active_writers":
            allowed = ["minutes", "limit"]; required = []
        case "get_task_impact":
            allowed = ["session_id", "limit"]; required = ["session_id"]
        case "find_cleanup_candidates":
            allowed = ["minimum_bytes", "older_than_days", "limit"]; required = []
        case "export_evidence":
            allowed = ["from", "through", "path_detail", "max_events"]; required = ["from", "through"]
        default:
            return "Unknown tool: \(tool)"
        }
        if let unknown = arguments.keys.first(where: { !allowed.contains($0) }) {
            return "Unknown argument: \(unknown)"
        }
        if let missing = required.first(where: { arguments[$0] == nil }) {
            return "Missing required argument: \(missing)"
        }
        if let limit = arguments["limit"]?.integerValue {
            let maximum: Int64 = tool == "list_active_writers" ? 200 : 500
            if !(1 ... maximum).contains(limit) { return "limit must be between 1 and \(maximum)" }
        } else if arguments["limit"] != nil {
            return "limit must be an integer"
        }
        if let value = arguments["max_events"]?.integerValue, !(1 ... 10_000).contains(value) {
            return "max_events must be between 1 and 10000"
        } else if arguments["max_events"] != nil, arguments["max_events"]?.integerValue == nil {
            return "max_events must be an integer"
        }
        if let value = arguments["minutes"]?.integerValue, !(1 ... 1_440).contains(value) {
            return "minutes must be between 1 and 1440"
        } else if arguments["minutes"] != nil, arguments["minutes"]?.integerValue == nil {
            return "minutes must be an integer"
        }
        if let value = arguments["older_than_days"]?.integerValue, !(0 ... 3_650).contains(value) {
            return "older_than_days must be between 0 and 3650"
        } else if arguments["older_than_days"] != nil, arguments["older_than_days"]?.integerValue == nil {
            return "older_than_days must be an integer"
        }
        if let value = arguments["minimum_bytes"]?.integerValue, value < 0 {
            return "minimum_bytes must be nonnegative"
        } else if arguments["minimum_bytes"] != nil, arguments["minimum_bytes"]?.integerValue == nil {
            return "minimum_bytes must be an integer"
        }
        if let value = arguments["path_query"]?.stringValue, value.isEmpty || value.utf8.count > 4_096 {
            return "path_query must contain 1...4096 UTF-8 bytes"
        } else if arguments["path_query"] != nil, arguments["path_query"]?.stringValue == nil {
            return "path_query must be a string"
        }
        if let value = arguments["session_id"]?.stringValue, value.isEmpty || value.utf8.count > 256 {
            return "session_id must contain 1...256 UTF-8 bytes"
        } else if arguments["session_id"] != nil, arguments["session_id"]?.stringValue == nil {
            return "session_id must be a string"
        }
        if let detail = arguments["path_detail"]?.stringValue,
           !["full", "basename", "hashed"].contains(detail) {
            return "path_detail must be full, basename, or hashed"
        } else if arguments["path_detail"] != nil, arguments["path_detail"]?.stringValue == nil {
            return "path_detail must be a string"
        }
        if required.contains("from") {
            guard let from = arguments["from"]?.stringValue,
                  let through = arguments["through"]?.stringValue
            else { return "from and through must be strings" }
            let formatter = ISO8601DateFormatter()
            guard let start = formatter.date(from: from), let end = formatter.date(from: through) else {
                return "from and through must be ISO-8601 timestamps"
            }
            if start >= end { return "through must be later than from" }
        }
        return nil
    }

    private static func tool(
        _ name: String,
        _ description: String,
        required: [String] = [],
        properties: [String: JSONValue]
    ) -> JSONValue {
        var input: [String: JSONValue] = [
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
        ]
        if !required.isEmpty { input["required"] = .array(required.map(JSONValue.string)) }
        return .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object(input),
            "annotations": .object([
                "readOnlyHint": .bool(true),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(true),
                "openWorldHint": .bool(false),
            ]),
        ])
    }

    private static func integer(minimum: Int64, maximum: Int64) -> JSONValue {
        .object(["type": .string("integer"), "minimum": .integer(minimum), "maximum": .integer(maximum)])
    }
}
