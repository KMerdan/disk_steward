import Darwin
import Foundation

public struct ProcessAncestryRecord: Codable, Equatable, Sendable {
    public let identity: ProcessIdentity
    public let parent: ProcessIdentity?

    public init(identity: ProcessIdentity, parent: ProcessIdentity?) {
        self.identity = identity
        self.parent = parent
    }
}

public struct ProcessAncestrySnapshot: Equatable, Sendable {
    public let records: [ProcessIdentity: ProcessAncestryRecord]
    public let truncated: Bool

    public init(records: [ProcessAncestryRecord], truncated: Bool = false) {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.identity, $0) })
        self.truncated = truncated
    }

    public func contains(_ process: ProcessIdentity, inTreeRootedAt root: ProcessIdentity) -> Bool {
        if process == root { return true }
        var current = process
        var visited: Set<ProcessIdentity> = []
        while visited.insert(current).inserted, let parent = records[current]?.parent {
            if parent == root { return true }
            current = parent
        }
        return false
    }
}

public struct LocalProcessInspector: Sendable {
    public init() {}

    public func snapshot(startingAt pid: Int32 = getpid(), maximumDepth: Int = 64) -> ProcessAncestrySnapshot {
        let limit = max(1, min(maximumDepth, 64))
        var records: [ProcessAncestryRecord] = []
        var currentPID = pid
        var truncated = false

        for depth in 0 ..< limit {
            guard let current = processInfo(pid: currentPID) else { break }
            let parent = current.parentPID > 0 ? processInfo(pid: current.parentPID)?.identity : nil
            records.append(ProcessAncestryRecord(identity: current.identity, parent: parent))
            guard let parent else { break }
            currentPID = parent.pid
            if depth == limit - 1, currentPID > 1 { truncated = true }
        }
        return ProcessAncestrySnapshot(records: records, truncated: truncated)
    }

    public func identity(pid: Int32 = getpid()) -> ProcessIdentity? {
        processInfo(pid: pid)?.identity
    }

    private func processInfo(pid: Int32) -> (identity: ProcessIdentity, parentPID: Int32)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return nil }

        let seconds = TimeInterval(info.pbi_start_tvsec)
        let microseconds = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path: String? = pathLength > 0
            ? String(decoding: pathBuffer.prefix(Int(pathLength)), as: UTF8.self)
            : nil
        return (
            ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: seconds + microseconds), executablePath: path),
            Int32(info.pbi_ppid)
        )
    }
}
