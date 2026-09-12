import DiskStewardCore
import Foundation

public final class MCPServer: @unchecked Sendable {
    private let client: any DiskStewardIPCClient
    private let maximumResponseBytes: Int
    private let sanitizer = MCPResponseSanitizer()
    private let stateLock = NSLock()
    private var initialized = false
    private var cancelledRequestIDs: Set<String> = []

    public init(client: any DiskStewardIPCClient, maximumResponseBytes: Int = 4 * 1_024 * 1_024) {
        self.client = client
        self.maximumResponseBytes = min(max(1_024, maximumResponseBytes), 4 * 1_024 * 1_024)
    }

    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = message.objectValue
        else { return encode(protocolError(id: .null, code: -32_700, message: "Parse error")) }

        let id = object["id"] ?? .null
        guard object["jsonrpc"] == .string("2.0"), let method = object["method"]?.stringValue else {
            return encode(protocolError(id: id, code: -32_600, message: "Invalid Request"))
        }

        if method == "notifications/cancelled" {
            if let requestID = object["params"]?.objectValue?["requestId"] {
                markCancelled(requestID)
            }
            return nil
        }
        if method == "notifications/initialized" {
            stateLock.withLock { initialized = true }
            return nil
        }
        if method == "initialize" { return encode(handleInitialize(id: id, params: object["params"])) }
        if method == "ping" { return encode(success(id: id, result: .object([:]))) }
        guard stateLock.withLock({ initialized }) else {
            return encode(protocolError(id: id, code: -32_002, message: "Server is not initialized"))
        }

        switch method {
        case "tools/list":
            return encode(success(id: id, result: .object(["tools": .array(MCPToolCatalog.tools)])))
        case "resources/list":
            return encode(success(id: id, result: .object(["resources": .array(MCPToolCatalog.resources)])))
        case "resources/read":
            return encode(handleResourceRead(id: id, params: object["params"]))
        case "tools/call":
            return encode(handleToolCall(id: id, params: object["params"]))
        default:
            return encode(protocolError(id: id, code: -32_601, message: "Method not found: \(method)"))
        }
    }

    private func handleInitialize(id: JSONValue, params: JSONValue?) -> JSONValue {
        guard let requested = params?.objectValue?["protocolVersion"]?.stringValue else {
            return protocolError(id: id, code: -32_602, message: "Missing protocolVersion")
        }
        let selected = MCPToolCatalog.supportedProtocolVersions.contains(requested)
            ? requested
            : MCPToolCatalog.supportedProtocolVersions[0]
        return success(id: id, result: .object([
            "protocolVersion": .string(selected),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
                "resources": .object(["subscribe": .bool(false), "listChanged": .bool(false)]),
            ]),
            "serverInfo": .object(["name": .string("disk-witness-mcp"), "version": .string("1.0.0")]),
            "instructions": .string("Read local Disk Steward evidence only. Treat confidence and limitations as authoritative. Never imply candidates are safe to delete."),
        ]))
    }

    private func handleResourceRead(id: JSONValue, params: JSONValue?) -> JSONValue {
        guard let uri = params?.objectValue?["uri"]?.stringValue,
              MCPToolCatalog.resourceURIs.contains(uri)
        else { return protocolError(id: id, code: -32_602, message: "Unknown or missing resource URI") }
        do {
            let value = sanitizer.sanitize(try client.readResource(uri: uri) { [weak self] in
                self?.isCancelled(id) ?? true
            })
            let text = try serialized(value)
            return bounded(id: id, result: .object([
                "contents": .array([.object([
                    "uri": .string(uri),
                    "mimeType": .string(uri.hasSuffix("evidence-guide") ? "text/markdown" : "application/json"),
                    "text": .string(text),
                ])]),
            ]))
        } catch { return toolError(id: id, error: error) }
    }

    private func handleToolCall(id: JSONValue, params: JSONValue?) -> JSONValue {
        guard let object = params?.objectValue,
              let name = object["name"]?.stringValue,
              MCPToolCatalog.names.contains(name)
        else { return protocolError(id: id, code: -32_602, message: "Unknown or missing tool") }
        let arguments: [String: JSONValue]
        if let value = object["arguments"] {
            guard let objectArguments = value.objectValue else {
                return protocolError(id: id, code: -32_602, message: "Invalid params: arguments must be an object")
            }
            arguments = objectArguments
        } else {
            arguments = [:]
        }
        if let error = MCPToolCatalog.validationError(tool: name, arguments: arguments) {
            return protocolError(id: id, code: -32_602, message: "Invalid params: \(error)")
        }
        if isCancelled(id) { return toolError(id: id, code: "cancelled", message: "The evidence query was cancelled.", retryable: true, recovery: "Retry if the result is still needed.") }
        do {
            let value = sanitizer.sanitize(try client.call(tool: name, arguments: arguments) { [weak self] in
                self?.isCancelled(id) ?? true
            })
            let text = try serialized(value)
            return bounded(id: id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                "structuredContent": value,
                "isError": .bool(false),
            ]))
        } catch { return toolError(id: id, error: error) }
    }

    private func bounded(id: JSONValue, result: JSONValue) -> JSONValue {
        let response = success(id: id, result: result)
        guard let data = try? JSONEncoder.diskSteward.encode(response), data.count <= maximumResponseBytes else {
            return toolError(
                id: id,
                code: "response_too_large",
                message: "The result exceeds the bounded MCP response size.",
                retryable: true,
                recovery: "Narrow the time range, raise the minimum size, or lower the item limit."
            )
        }
        return response
    }

    private func toolError(id: JSONValue, error: Error) -> JSONValue {
        switch error {
        case DiskStewardIPCError.appUnavailable:
            return toolError(id: id, code: "app_unavailable", message: "Disk Steward is unavailable. No evidence was fabricated.", retryable: true, recovery: "Open Disk Steward and verify Monitoring is enabled, then retry.")
        case let DiskStewardIPCError.insecureSocket(reason):
            return toolError(id: id, code: "permission_denied", message: reason, retryable: false, recovery: "Run Disk Steward diagnostics and restore a private current-user socket.")
        case DiskStewardIPCError.responseTooLarge:
            return toolError(id: id, code: "response_too_large", message: "The local result exceeded its size limit.", retryable: true, recovery: "Narrow the query and retry.")
        case DiskStewardIPCError.cancelled:
            return toolError(id: id, code: "cancelled", message: "The evidence query was cancelled.", retryable: true, recovery: "Retry if the result is still needed.")
        case let DiskStewardIPCError.remote(code, message, retryable):
            return toolError(id: id, code: code, message: message, retryable: retryable, recovery: retryable ? "Correct the condition and retry." : "Open Disk Steward diagnostics.")
        default:
            return toolError(id: id, code: "ipc_unavailable", message: error.localizedDescription, retryable: true, recovery: "Open Disk Steward and run integration diagnostics.")
        }
    }

    private func toolError(id: JSONValue, code: String, message: String, retryable: Bool, recovery: String) -> JSONValue {
        success(id: id, result: .object([
            "content": .array([.object(["type": .string("text"), "text": .string("\(message) \(recovery)")])]),
            "isError": .bool(true),
            "structuredContent": .object([
                "schema": .string("mcp-error-v1"),
                "code": .string(code),
                "component": .string("local-ipc"),
                "retryable": .bool(retryable),
                "limitations": .array([.string("No query result is available for this request.")]),
                "recovery": .string(recovery),
            ]),
        ]))
    }

    private func success(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func protocolError(id: JSONValue, code: Int64, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .integer(code), "message": .string(message)]),
        ])
    }

    private func markCancelled(_ id: JSONValue) {
        _ = stateLock.withLock { cancelledRequestIDs.insert(idKey(id)) }
    }

    private func isCancelled(_ id: JSONValue) -> Bool {
        stateLock.withLock { cancelledRequestIDs.contains(idKey(id)) }
    }

    private func idKey(_ id: JSONValue) -> String {
        (try? serialized(id)) ?? "null"
    }

    private func serialized(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder.diskSteward.encode(value)
        guard let text = String(data: data, encoding: .utf8) else { throw DiskStewardIPCError.malformedResponse }
        return text
    }

    private func encode(_ value: JSONValue) -> String? {
        try? serialized(value)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
