import CoreServices
import Foundation

public struct TargetedChangeHint: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case created
        case removed
        case renamed
        case modified
        case metadataChanged = "metadata-changed"
        case rootChanged = "root-changed"
        case unknown
    }

    public let path: String
    public let eventID: UInt64
    public let observedAt: Date
    public let kind: Kind
    public let requiresRescan: Bool
    public let rawFlags: UInt32
    public let signals: [String]

    public init(
        path: String,
        eventID: UInt64,
        observedAt: Date,
        kind: Kind,
        requiresRescan: Bool,
        rawFlags: UInt32 = 0,
        signals: [String] = []
    ) {
        self.path = path
        self.eventID = eventID
        self.observedAt = observedAt
        self.kind = kind
        self.requiresRescan = requiresRescan
        self.rawFlags = rawFlags
        self.signals = Array(Set(signals)).sorted()
    }
}

public struct TargetedChangeBatch: Codable, Equatable, Sendable {
    public let hints: [TargetedChangeHint]
    public let eventGap: Bool
    public let limitations: [String]

    public init(hints: [TargetedChangeHint], eventGap: Bool, limitations: [String]) {
        self.hints = hints
        self.eventGap = eventGap
        self.limitations = Array(Set(limitations)).sorted()
    }
}

public enum TargetedFSEventsCollectorError: Error, Equatable, LocalizedError {
    case noActiveRoots
    case streamCreationFailed
    case streamStartFailed

    public var errorDescription: String? {
        switch self {
        case .noActiveRoots: return "No active watched, registered, or investigation roots are available."
        case .streamCreationFailed: return "macOS did not create the requested FSEvents stream."
        case .streamStartFailed: return "macOS created but did not start the requested FSEvents stream."
        }
    }
}

enum FSEventsBatchInterpreter {
    // Admission limits, not filesystem limits. A batch outside these bounds
    // becomes global uncertainty and must be reconciled, never silently dropped.
    static let maximumEventsPerBatch = 256
    static let maximumPathUTF16Units = 4_096

    private static func gap(_ limitation: String) -> TargetedChangeBatch {
        TargetedChangeBatch(hints: [], eventGap: true, limitations: [limitation])
    }

    static func interpret(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        eventIDs: [FSEventStreamEventId],
        policy: MonitoringPolicy,
        observedAt: Date
    ) -> TargetedChangeBatch? {
        guard paths.count == flags.count, paths.count == eventIDs.count else {
            return gap("FSEvents supplied inconsistent batch lengths; reconcile all watched roots.")
        }
        return interpret(count: paths.count, policy: policy, observedAt: observedAt) { index in
            let path = paths[index]
            guard path.utf16.count <= maximumPathUTF16Units else { return nil }
            return (path, flags[index], eventIDs[index])
        }
    }

    /// Borrows the native array without bridging/copying the whole batch into
    /// Swift arrays. Reject count before reading a path, flag or event ID.
    static func interpretNative(
        paths: NSArray,
        count: Int,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>,
        policy: MonitoringPolicy,
        observedAt: Date
    ) -> TargetedChangeBatch? {
        guard count == paths.count else {
            return gap("FSEvents supplied inconsistent batch lengths; reconcile all watched roots.")
        }
        return interpret(count: count, policy: policy, observedAt: observedAt) { index in
            // Check NSString's length before allocating a bridged Swift String.
            guard let path = paths.object(at: index) as? NSString,
                  path.length <= maximumPathUTF16Units else { return nil }
            return (path as String, flags[index], eventIDs[index])
        }
    }

    static func interpret(
        count: Int,
        policy: MonitoringPolicy,
        observedAt: Date,
        eventAt: (Int) -> (String, FSEventStreamEventFlags, FSEventStreamEventId)?
    ) -> TargetedChangeBatch? {
        guard count >= 0, count <= maximumEventsPerBatch else {
            return gap("FSEvents batch exceeded the bounded receipt budget; reconcile all watched roots.")
        }
        var hints: [TargetedChangeHint] = []
        var eventGap = false

        for index in 0 ..< count {
            guard let (rawPath, eventFlags, eventID) = eventAt(index), rawPath.hasPrefix("/") else {
                return gap("FSEvents supplied an invalid or oversized path; reconcile all watched roots.")
            }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            eventGap = eventGap || hasAnyGapFlag(eventFlags)
            guard policy.includes(path: path, at: observedAt) else { continue }
            hints.append(
                TargetedChangeHint(
                    path: path,
                    eventID: eventID,
                    observedAt: observedAt,
                    kind: kind(for: eventFlags),
                    requiresRescan: true,
                    rawFlags: eventFlags,
                    signals: signals(for: eventFlags)
                )
            )
        }
        guard eventGap || !hints.isEmpty else { return nil }
        return TargetedChangeBatch(
            hints: hints, eventGap: eventGap,
            limitations: eventGap ? ["FSEvents reported dropped, wrapped, or root-change history; rescan affected roots."] : []
        )
    }

    private static func hasAnyGapFlag(_ flags: FSEventStreamEventFlags) -> Bool {
        let gapFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )
        return flags & gapFlags != 0
    }

    private static func kind(for flags: FSEventStreamEventFlags) -> TargetedChangeHint.Kind {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { return .rootChanged }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 { return .created }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 { return .removed }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 { return .renamed }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 { return .modified }
        let metadataFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemInodeMetaMod
                | kFSEventStreamEventFlagItemFinderInfoMod
                | kFSEventStreamEventFlagItemChangeOwner
                | kFSEventStreamEventFlagItemXattrMod
        )
        if flags & metadataFlags != 0 { return .metadataChanged }
        return .unknown
    }

    private static func signals(for flags: FSEventStreamEventFlags) -> [String] {
        var values: [String] = []
        let candidates: [(FSEventStreamEventFlags, String)] = [
            (FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated), "item-created"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved), "item-removed"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed), "item-renamed"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified), "item-modified"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs), "must-scan-subdirectories"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped), "user-dropped"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped), "kernel-dropped"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped), "event-ids-wrapped"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged), "root-changed"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagMount), "volume-mounted"),
            (FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount), "volume-unmounted"),
        ]
        for (flag, name) in candidates where flags & flag != 0 { values.append(name) }
        return values.sorted()
    }
}

/// Delivers notification-only path hints for configured roots. Callers must rescan
/// file metadata to derive operations and byte deltas; FSEvents does not identify
/// the process responsible for a change.
public final class TargetedFSEventsCollector: @unchecked Sendable {
    public typealias Handler = @Sendable (TargetedChangeBatch) -> Void

    private final class CallbackBox: @unchecked Sendable {
        let policy: MonitoringPolicy
        let handler: Handler

        init(policy: MonitoringPolicy, handler: @escaping Handler) {
            self.policy = policy
            self.handler = handler
        }
    }

    private let deliveryQueue: DispatchQueue
    private let stateLock = NSLock()
    private var stream: FSEventStreamRef?

    public init(deliveryQueue: DispatchQueue = DispatchQueue(label: "dev.disksteward.fsevents")) {
        self.deliveryQueue = deliveryQueue
    }

    deinit {
        stop()
    }

    public func start(
        policy: MonitoringPolicy,
        at date: Date = Date(),
        latency: TimeInterval = 0.2,
        handler: @escaping Handler
    ) throws {
        stop()
        let roots = policy.activeRoots(at: date)
        guard !roots.isEmpty else { throw TargetedFSEventsCollectorError.noActiveRoots }

        let box = CallbackBox(policy: policy, handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        let created = withExtendedLifetime(box) {
            FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.callback,
                &context,
                roots.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                max(0.05, latency),
                flags
            )
        }
        guard let candidate = created else {
            throw TargetedFSEventsCollectorError.streamCreationFailed
        }

        FSEventStreamSetDispatchQueue(candidate, deliveryQueue)
        guard FSEventStreamStart(candidate) else {
            FSEventStreamInvalidate(candidate)
            FSEventStreamRelease(candidate)
            throw TargetedFSEventsCollectorError.streamStartFailed
        }

        stateLock.lock()
        stream = candidate
        stateLock.unlock()
    }

    /// Replaces the active stream so newly registered or investigation roots take
    /// effect without changing the bounded monitoring policy.
    public func restart(
        policy: MonitoringPolicy,
        at date: Date = Date(),
        latency: TimeInterval = 0.2,
        handler: @escaping Handler
    ) throws {
        try start(policy: policy, at: date, latency: latency, handler: handler)
    }

    public func stop() {
        stateLock.lock()
        let activeStream = stream
        stream = nil
        stateLock.unlock()

        if let activeStream {
            FSEventStreamStop(activeStream)
            FSEventStreamInvalidate(activeStream)
            FSEventStreamRelease(activeStream)
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        if let batch = FSEventsBatchInterpreter.interpretNative(
            paths: unsafeBitCast(rawPaths, to: NSArray.self),
            count: count,
            flags: rawFlags,
            eventIDs: rawIDs,
            policy: box.policy,
            observedAt: Date()
        ) {
            box.handler(batch)
        }
    }
}
