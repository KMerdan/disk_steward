import DiskStewardCore
import Foundation

enum MCPToolCatalog {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// TASK-671: the catalogue on the capacity ring, change journal and review
    /// report. get_provenance would be listed only while an Endpoint Security
    /// bridge is active; the app has none, so it is not listed (tools/list is
    /// static, listChanged false).
    static let names = [
        "get_storage_summary",
        "get_health",
        "explain_growth",
        "list_review_items",
        "list_largest_objects",
        "get_review_item_evidence",
        "measure_path",
        "list_active_agent_sessions",
        "get_task_impact",
        "export_evidence",
    ]

    /// Tools whose answer may take the whole measurement budget.
    static let slowTools: Set<String> = ["measure_path"]

    static let resourceURIs = ["disk-steward://status", "disk-steward://evidence-guide"]

    static var tools: [JSONValue] {
        [
            tool("get_storage_summary", "Return bounded current volume and monitored-scope totals with freshness and limitations.", properties: [:]),
            tool("get_health", "Return the stores' sizes and caps, the latest review of each scope, the change journal's state and any legacy evidence.", properties: [:]),
            tool("explain_growth", "Explain growth for a bounded time range: the capacity change, measured object deltas, the unexplained remainder and changed folders.", required: ["from", "through"], properties: [
                "from": .object(["type": .string("string")]),
                "through": .object(["type": .string("string")]),
                "limit": integer(minimum: 1, maximum: 500),
                "cursor": string(maximum: 4_096),
                "path_detail": pathDetail(),
            ]),
            tool("list_review_items", "List the latest review's ranked items with size, evidence state, recreate class and the owning tool's cleanup command; never a deletion instruction.", properties: reviewProperties()),
            tool("list_largest_objects", "List the largest measured objects (build output, environments, caches), optionally within one review scope.", properties: reviewProperties()),
            tool("get_review_item_evidence", "Return one review item's full evidence: why it may be disposable, reasons to keep it, its commands and a live check.", required: ["item_id"], properties: [
                "item_id": string(maximum: 256),
                "path_detail": pathDetail(),
            ]),
            tool("measure_path", "Measure one folder inside the configured scopes within 15 s and 500,000 entries; joins a running review instead of starting a second walk, and stores nothing.", required: ["path"], properties: [
                "path": string(maximum: 4_096),
                "path_detail": pathDetail(),
            ]),
            tool("list_active_agent_sessions", "Return active authenticated agent task contexts and the folders their workspaces saw change, without claiming they are file writers.", properties: [
                "minutes": integer(minimum: 1, maximum: 1_440),
                "limit": integer(minimum: 1, maximum: 200),
                "cursor": string(maximum: 4_096),
            ]),
            tool("get_task_impact", "Summarize the folders that changed in a registered session's workspace during its window, with the objects there; a correlation, never a claim about which process wrote.", required: ["session_id"], properties: [
                "session_id": .object(["type": .string("string"), "maxLength": .integer(256)]),
                "limit": integer(minimum: 1, maximum: 500),
                "from": .object(["type": .string("string")]),
                "through": .object(["type": .string("string")]),
            ]),
            tool("export_evidence", "Return a bounded inline export of the steward evidence for a window, plus the legacy evidence read-only when it fits.", required: ["from", "through"], properties: [
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
                "description": .string("Stores, caps, latest reviews and change-journal state."),
            ]),
            .object([
                "uri": .string("disk-steward://evidence-guide"),
                "name": .string("Disk Steward evidence interpretation guide"),
                "mimeType": .string("text/markdown"),
                "description": .string("Meaning of evidence states, review items, partial reviews and unexplained growth."),
            ]),
        ]
    }

    static func validationError(tool: String, arguments: [String: JSONValue]) -> String? {
        let allowed: Set<String>
        let required: Set<String>
        switch tool {
        case "get_storage_summary", "get_health":
            allowed = []; required = []
        case "explain_growth":
            allowed = ["from", "through", "limit", "cursor", "path_detail"]; required = ["from", "through"]
        case "list_review_items", "list_largest_objects":
            allowed = ["scope", "limit", "cursor", "path_detail"]; required = []
        case "get_review_item_evidence":
            allowed = ["item_id", "path_detail"]; required = ["item_id"]
        case "measure_path":
            allowed = ["path", "path_detail"]; required = ["path"]
        case "list_active_agent_sessions":
            allowed = ["minutes", "limit", "cursor"]; required = []
        case "get_task_impact":
            allowed = ["session_id", "limit", "from", "through"]; required = ["session_id"]
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
            let maximum: Int64 = tool == "list_active_agent_sessions" ? 200 : 500
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
        if let value = arguments["session_id"]?.stringValue, value.isEmpty || value.utf8.count > 256 {
            return "session_id must contain 1...256 UTF-8 bytes"
        } else if arguments["session_id"] != nil, arguments["session_id"]?.stringValue == nil {
            return "session_id must be a string"
        }
        for name in ["cursor", "scope", "path"] where arguments[name] != nil {
            guard let value = arguments[name]?.stringValue, !value.isEmpty, value.utf8.count <= 4_096 else {
                return "\(name) must contain 1...4096 UTF-8 bytes"
            }
        }
        if arguments["item_id"] != nil {
            guard let value = arguments["item_id"]?.stringValue, !value.isEmpty, value.utf8.count <= 256 else {
                return "item_id must contain 1...256 UTF-8 bytes"
            }
        }
        if let detail = arguments["path_detail"]?.stringValue,
           !["full", "basename", "hashed"].contains(detail) {
            return "path_detail must be full, basename, or hashed"
        } else if arguments["path_detail"] != nil, arguments["path_detail"]?.stringValue == nil {
            return "path_detail must be a string"
        }
        if required.contains("from") || arguments["from"] != nil || arguments["through"] != nil {
            guard let from = arguments["from"]?.stringValue,
                  let through = arguments["through"]?.stringValue
            else { return "from and through must be strings" }
            guard let start = parseTimestamp(from), let end = parseTimestamp(through) else {
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

    private static func string(maximum: Int64) -> JSONValue {
        .object(["type": .string("string"), "minLength": .integer(1), "maxLength": .integer(maximum)])
    }

    private static func pathDetail() -> JSONValue {
        .object(["type": .string("string"), "enum": .array([.string("full"), .string("basename"), .string("hashed")])])
    }

    private static func reviewProperties() -> [String: JSONValue] {
        [
            "scope": string(maximum: 4_096),
            "limit": integer(minimum: 1, maximum: 500),
            "cursor": string(maximum: 4_096),
            "path_detail": pathDetail(),
        ]
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
