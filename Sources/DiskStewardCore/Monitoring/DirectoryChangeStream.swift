import CoreServices
import Darwin
import Foundation

/// One directory-level change from the FSEvents journal.
public struct DirectoryChangeEvent: Equatable, Sendable {
    public let path: String
    public let eventID: UInt64
    public let flags: UInt32
}

/// A delivered batch: directory changes, whether the replay of stored history
/// has finished, and any signal that history is incomplete.
public struct DirectoryChangeBatch: Equatable, Sendable {
    public var events: [DirectoryChangeEvent]
    public var historyDone: Bool
    /// Gap signals with the directory they apply to (or the root).
    public var gaps: [(signal: String, path: String)]

    public init(events: [DirectoryChangeEvent] = [], historyDone: Bool = false, gaps: [(signal: String, path: String)] = []) {
        self.events = events
        self.historyDone = historyDone
        self.gaps = gaps
    }

    public var latestEventID: UInt64? { events.map(\.eventID).max() }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.events == rhs.events && lhs.historyDone == rhs.historyDone
            && lhs.gaps.map(\.signal) == rhs.gaps.map(\.signal) && lhs.gaps.map(\.path) == rhs.gaps.map(\.path)
    }

    /// Interprets raw FSEvents records. Directory paths only: the stream is
    /// created without per-file events.
    public static func interpret(_ records: [(path: String, flags: UInt32, eventID: UInt64)]) -> DirectoryChangeBatch {
        var batch = DirectoryChangeBatch()
        let gapFlags: [(UInt32, String)] = [
            (UInt32(kFSEventStreamEventFlagMustScanSubDirs), "must-scan-subdirectories"),
            (UInt32(kFSEventStreamEventFlagUserDropped), "user-dropped"),
            (UInt32(kFSEventStreamEventFlagKernelDropped), "kernel-dropped"),
            (UInt32(kFSEventStreamEventFlagEventIdsWrapped), "event-ids-wrapped"),
            (UInt32(kFSEventStreamEventFlagRootChanged), "root-changed"),
        ]
        for record in records {
            if record.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                batch.historyDone = true
                continue
            }
            for (flag, signal) in gapFlags where record.flags & flag != 0 {
                batch.gaps.append((signal, record.path))
            }
            batch.events.append(.init(path: Self.directoryPath(record.path), eventID: record.eventID, flags: record.flags))
        }
        return batch
    }

    private static func directoryPath(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// A directory-level FSEvents stream that can resume from a stored event ID,
/// so sleep and relaunch replay instead of leaving a blind interval.
public final class DirectoryChangeStream: @unchecked Sendable {
    public typealias Handler = @Sendable (DirectoryChangeBatch) -> Void

    private final class CallbackBox: @unchecked Sendable {
        let handler: Handler
        init(handler: @escaping Handler) { self.handler = handler }
    }

    private let deliveryQueue: DispatchQueue
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    public init(deliveryQueue: DispatchQueue = DispatchQueue(label: "dev.disksteward.change-journal")) {
        self.deliveryQueue = deliveryQueue
    }

    deinit { stop() }

    /// The newest event ID the system has issued.
    public static func currentEventID() -> UInt64 { UInt64(FSEventsGetCurrentEventId()) }

    /// The real path FSEvents reports for `path` (for example `/tmp` is
    /// reported as `/private/tmp`); the path itself when it cannot be resolved.
    public static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The FSEvents journal identity of the volume holding `path`. A change
    /// means stored event IDs no longer refer to this journal.
    public static func journalUUID(for path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public func start(paths: [String], since eventID: UInt64?, latency: TimeInterval = 1, handler: @escaping Handler) throws {
        stop()
        guard !paths.isEmpty else { throw TargetedFSEventsCollectorError.noActiveRoots }
        let box = CallbackBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil)
        // Directory-level only: no kFSEventStreamCreateFlagFileEvents.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        let since = eventID.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let created = withExtendedLifetime(box) {
            FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context, paths as CFArray, since, max(0.05, latency), flags)
        }
        guard let candidate = created else { throw TargetedFSEventsCollectorError.streamCreationFailed }
        FSEventStreamSetDispatchQueue(candidate, deliveryQueue)
        guard FSEventStreamStart(candidate) else {
            FSEventStreamInvalidate(candidate)
            FSEventStreamRelease(candidate)
            throw TargetedFSEventsCollectorError.streamStartFailed
        }
        lock.withLock { stream = candidate }
    }

    /// The newest event ID this stream has delivered.
    public func latestEventID() -> UInt64? {
        lock.withLock { stream.map { UInt64(FSEventStreamGetLatestEventId($0)) } }
    }

    public func stop() {
        let active = lock.withLock { () -> FSEventStreamRef? in
            let value = stream
            stream = nil
            return value
        }
        if let active {
            FSEventStreamStop(active)
            FSEventStreamInvalidate(active)
            FSEventStreamRelease(active)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(rawPaths, to: NSArray.self)
        var records: [(path: String, flags: UInt32, eventID: UInt64)] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            guard let path = paths[index] as? String else { continue }
            records.append((path, UInt32(rawFlags[index]), UInt64(rawIDs[index])))
        }
        box.handler(DirectoryChangeBatch.interpret(records))
    }
}
