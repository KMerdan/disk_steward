import Foundation
struct Echo: DiskStewardIPCRequestHandling {
    func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue { .string("alive") }
}
@main struct Collision {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ds512-red-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "s").path
        let first = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        let second = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        try first.start()
        defer { second.stop(); first.stop() }
        try second.start()
        print("DEFECT: second server replaced live same-owner socket")
        first.stop()
        print("DEFECT: first stop removed successor: \(!FileManager.default.fileExists(atPath: path))")
    }
}
