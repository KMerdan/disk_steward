import DiskStewardCore
import Foundation

let environment = ProcessInfo.processInfo.environment
let overriddenSocketPath = environment["DISK_STEWARD_SOCKET_PATH"]
let socketPath = overriddenSocketPath ?? UnixSocketDiskStewardIPCClient.defaultSocketPath()
let stateURL = environment["DISK_STEWARD_AGENT_ACCESS_STATE_PATH"].map(URL.init(fileURLWithPath:))
    ?? (overriddenSocketPath == nil ? AgentAccessStateFile.defaultURL() : nil)
let server = MCPServer(client: UnixSocketDiskStewardIPCClient(socketPath: socketPath, accessStateURL: stateURL))

if CommandLine.arguments.contains("--self-check") {
    let response = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"self-check","version":"1"}}}"#)
    if let response { print(response) }
    exit(response == nil ? 1 : 0)
}

while let line = readLine() {
    if let response = server.handle(line: line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
