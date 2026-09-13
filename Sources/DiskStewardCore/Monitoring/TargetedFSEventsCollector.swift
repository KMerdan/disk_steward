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
    static func interpret(
        paths: [String],
        flags: [FSEventStreamEventFlags],
        eventIDs: [FSEventStreamEventId],
        policy: MonitoringPolicy,
        observedAt: Date
    ) -> TargetedChangeBatch? {
        let count = min(paths.count, flags.count, eventIDs.count)
        var hints: [TargetedChangeHint] = []
        var limitations: [String] = []
        var eventGap = false

        for index in 0 ..< count {
            let path = URL(fileURLWithPath: paths[index]).standardizedFileURL.path
            let eventFlags = flags[index]
            let gap = hasAnyGapFlag(eventFlags)
            if gap {
                eventGap = true
                limitations.append("FSEvents reported dropped, wrapped, or root-change history; rescan affected roots.")
            }
            guard policy.includes(path: path, at: observedAt) else { continue }
            hints.append(
                TargetedChangeHint(
                    path: path,
                    eventID: eventIDs[index],
                    observedAt: observedAt,
                    kind: kind(for: eventFlags),
                    requiresRescan: true,
                    rawFlags: eventFlags,
                    signals: signals(for: eventFlags)
                )
            )
        }
        guard eventGap || !hints.isEmpty else { return nil }
        return TargetedChangeBatch(hints: hints, eventGap: eventGap, limitations: limitations)
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
    private var callbackBox: CallbackBox?

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
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let candidate = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            max(0.05, latency),
            flags
        ) else {
            throw TargetedFSEventsCollectorError.streamCreationFailed
        }

        FSEventStreamSetDispatchQueue(candidate, deliveryQueue)
        guard FSEventStreamStart(candidate) else {
            FSEventStreamInvalidate(candidate)
            FSEventStreamRelease(candidate)
            throw TargetedFSEventsCollectorError.streamStartFailed
        }

        stateLock.lock()
        callbackBox = box
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

        stateLock.lock()
        callbackBox = nil
        stateLock.unlock()
    }

    private static let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        guard let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] else { return }
        let flags = (0 ..< count).map { rawFlags[$0] }
        let eventIDs = (0 ..< count).map { rawIDs[$0] }
        if let batch = FSEventsBatchInterpreter.interpret(
            paths: paths,
            flags: flags,
            eventIDs: eventIDs,
            policy: box.policy,
            observedAt: Date()
        ) {
            box.handler(batch)
        }
    }
}
