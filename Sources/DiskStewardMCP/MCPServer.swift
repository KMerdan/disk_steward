import DiskStewardCore
import Foundation
import CryptoKit

public final class MCPServer: @unchecked Sendable {
    private let client: any DiskStewardIPCClient
    private let maximumResponseBytes: Int
    private let sanitizer = MCPResponseSanitizer()
    private let stateLock = NSLock()
    private var initialized = false
    final class Request: @unchecked Sendable {
        let id: JSONValue
        let key: String
        let method: String
        let params: JSONValue?
        fileprivate var cancelled = false
        fileprivate var terminal = false
        fileprivate init(id: JSONValue, key: String, method: String, params: JSONValue?) {
            self.id = id; self.key = key; self.method = method; self.params = params
        }
    }
    enum Admission {
        case response(String?)
        case request(Request)
    }
    private var activeRequests: [String: Request] = [:]
    private var accepting = true
    private let beforeTerminalClaim: @Sendable () -> Void

    var activeRequestCount: Int { stateLock.withLock { activeRequests.count } }

    public convenience init(client: any DiskStewardIPCClient, maximumResponseBytes: Int = 4 * 1_024 * 1_024) {
        self.init(client: client, maximumResponseBytes: maximumResponseBytes, beforeTerminalClaim: {})
    }

    init(client: any DiskStewardIPCClient, maximumResponseBytes: Int = 4 * 1_024 * 1_024,
         beforeTerminalClaim: @escaping @Sendable () -> Void) {
        self.client = client
        self.maximumResponseBytes = min(max(1_024, maximumResponseBytes), 4 * 1_024 * 1_024)
        self.beforeTerminalClaim = beforeTerminalClaim
    }

    public func handle(line: String) -> String? {
        switch prepare(line: line) {
        case .response(let response): return response
        case .request(let request): return perform(request)
        }
    }

    // Admission happens on stdin before work is dispatched. Cancellation can
    // therefore find every accepted request, without future-ID tombstones.
    func prepare(line: String) -> Admission {
        guard line.utf8.count <= 1_024 * 1_024 else {
            return .response(encode(protocolError(id: .null, code: -32_600, message: "Request exceeds 1 MiB")))
        }
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = message.objectValue
        else { return .response(encode(protocolError(id: .null, code: -32_700, message: "Parse error"))) }

        let id = object["id"] ?? .null
        guard object["jsonrpc"] == .string("2.0"), let method = object["method"]?.stringValue else {
            return .response(encode(protocolError(id: id, code: -32_600, message: "Invalid Request")))
        }

        if method == "notifications/cancelled" {
            if let requestID = object["params"]?.objectValue?["requestId"] {
                markCancelled(requestID)
            }
            return .response(nil)
        }
        if method == "notifications/initialized" {
            stateLock.withLock { initialized = true }
            return .response(nil)
        }
        // Notifications cannot invoke evidence work or generate a response.
        guard object["id"] != nil else { return .response(nil) }
        guard id.stringValue != nil || id.integerValue != nil else {
            return .response(encode(protocolError(id: .null, code: -32_600, message: "Invalid request ID")))
        }
        if stateLock.withLock({ activeRequests[idKey(id)] != nil }) {
            return .response(encode(protocolError(id: id, code: -32_600, message: "Duplicate active request ID")))
        }
        if method == "initialize" { return .response(encode(handleInitialize(id: id, params: object["params"]))) }
        if method == "ping" { return .response(encode(success(id: id, result: .object([:])))) }
        guard stateLock.withLock({ initialized }) else {
            return .response(encode(protocolError(id: id, code: -32_002, message: "Server is not initialized")))
        }

        switch method {
        case "tools/list":
            return .response(encode(success(id: id, result: .object(["tools": .array(MCPToolCatalog.tools)]))))
        case "resources/list":
            return .response(encode(success(id: id, result: .object(["resources": .array(MCPToolCatalog.resources)]))))
        case "resources/read", "tools/call":
            return stateLock.withLock {
                let key = idKey(id)
                guard activeRequests[key] == nil else {
                    return .response(encode(protocolError(id: id, code: -32_600, message: "Duplicate active request ID")))
                }
                guard accepting, activeRequests.count < 4 else {
                    return .response(encode(protocolError(id: id, code: -32_000, message: "Too many evidence requests in flight; retry after a response.")))
                }
                let request = Request(id: id, key: key, method: method, params: object["params"])
                activeRequests[key] = request
                return .request(request)
            }
        default:
            return .response(encode(protocolError(id: id, code: -32_601, message: "Method not found: \(method)")))
        }
    }

    func perform(_ request: Request) -> String? {
        defer {
            stateLock.withLock {
                if activeRequests[request.key] === request { activeRequests.removeValue(forKey: request.key) }
            }
        }
        guard !isCancelled(request) else { return nil }
        let value = request.method == "tools/call"
            ? handleToolCall(request: request)
            : handleResourceRead(request: request)
        guard !isCancelled(request) else { return nil }
        let response = encode(value)
        beforeTerminalClaim()
        // This is the terminal-response boundary: a later cancel may race with
        // transport delivery, but a cancel that wins here suppresses all output.
        return stateLock.withLock {
            guard !request.cancelled, !request.terminal else { return nil }
            request.terminal = true
            return response
        }
    }

    func cancelAll() {
        stateLock.withLock {
            accepting = false
            for request in activeRequests.values where !request.terminal { request.cancelled = true }
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

    private func handleResourceRead(request: Request) -> JSONValue {
        let id = request.id
        let params = request.params
        guard let uri = params?.objectValue?["uri"]?.stringValue,
              MCPToolCatalog.resourceURIs.contains(uri)
        else { return protocolError(id: id, code: -32_602, message: "Unknown or missing resource URI") }
        do {
            let rawValue = try client.readResource(uri: uri) { self.isCancelled(request) }
            guard !isCancelled(request) else { throw DiskStewardIPCError.cancelled }
            let value = sanitizer.sanitize(rawValue)
            guard !isCancelled(request) else { throw DiskStewardIPCError.cancelled }
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

    private func handleToolCall(request: Request) -> JSONValue {
        let id = request.id
        let params = request.params
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
        if isCancelled(request) { return toolError(id: id, code: "cancelled", message: "The evidence query was cancelled.", retryable: true, recovery: "Retry if the result is still needed.") }
        do {
            let rawValue = try client.call(tool: name, arguments: arguments) { self.isCancelled(request) }
            guard !isCancelled(request) else { throw DiskStewardIPCError.cancelled }
            let value = sanitizer.sanitize(rawValue)
            guard !isCancelled(request) else { throw DiskStewardIPCError.cancelled }
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
        case DiskStewardIPCError.agentAccessDisabled:
            return toolError(id: id, code: "agent_access_disabled", message: "Disk Steward Agent Access is off. No evidence was queried or fabricated.", retryable: false, recovery: "Open Disk Steward and turn on Agent Access, then retry.")
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
        stateLock.withLock {
            if let request = activeRequests[idKey(id)], !request.terminal { request.cancelled = true }
        }
    }

    private func isCancelled(_ request: Request) -> Bool {
        stateLock.withLock { request.cancelled }
    }

    private func idKey(_ id: JSONValue) -> String {
        SHA256.hash(data: (try? JSONEncoder.diskSteward.encode(id)) ?? Data()).map { String(format: "%02x", $0) }.joined()
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
