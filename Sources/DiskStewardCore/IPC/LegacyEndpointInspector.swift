import Darwin
import Foundation

/// Decides whether a socket without an ownership record is a leftover from an
/// earlier Disk Steward. Versions up to 1.1 never removed their socket on quit
/// and never wrote the lifetime-lease record, so every upgrade found an
/// "unowned" endpoint and Agent Access could not start.
///
/// The decision never connects to the socket: a probe could disturb an older
/// app that is still running. Instead it reads the process table. The endpoint
/// is stale only when no process holds a Unix socket bound to that path and no
/// other Disk Steward application process is running. Anything it cannot read
/// counts as "in use", so the endpoint is preserved.
struct LegacyEndpointInspector: Sendable {
    /// PIDs holding an AF_UNIX socket bound to the path, or nil when the
    /// process table could not be read.
    var listeners: @Sendable (String) -> [Int32]?
    /// Whether another Disk Steward application process is running.
    var otherApplicationRunning: @Sendable () -> Bool

    static let system = LegacyEndpointInspector(
        listeners: ProcessSocketTable.pids(boundTo:),
        otherApplicationRunning: { ProcessSocketTable.otherProcessRunning(executableSuffix: "/Disk Steward.app/Contents/MacOS/Disk Steward") }
    )

    func isStale(_ path: String) -> Bool {
        guard let holders = listeners(path), holders.isEmpty else { return false }
        return !otherApplicationRunning()
    }
}

enum ProcessSocketTable {
    static func pids(boundTo path: String) -> [Int32]? {
        guard let processes = allProcesses() else { return nil }
        var holders: [Int32] = []
        for pid in processes where holdsUnixSocket(pid: pid, boundTo: path) {
            holders.append(pid)
        }
        return holders
    }

    /// Fails closed: an unreadable process table reports a running process.
    static func otherProcessRunning(executableSuffix: String) -> Bool {
        guard let processes = allProcesses() else { return true }
        let own = getpid()
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in processes where pid != own {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path.hasSuffix(executableSuffix) { return true }
        }
        return false
    }

    private static func allProcesses() -> [Int32]? {
        let estimate = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(estimate) / MemoryLayout<Int32>.size + 64)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return nil }
        return pids.prefix(Int(filled) / MemoryLayout<Int32>.size).filter { $0 > 0 }
    }

    private static func holdsUnixSocket(pid: Int32, boundTo path: String) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return false }
        for descriptor in descriptors.prefix(Int(filled) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_family == AF_UNIX else { continue }
            let bound = withUnsafeBytes(of: info.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if bound == path { return true }
        }
        return false
    }
}
