import Foundation

public struct EndpointMonitoringScope: Equatable, Sendable {
    public let watchedRoots: [String]
    public let excludedRoots: [String]

    public init(watchedRoots: [String], excludedRoots: [String]) {
        self.watchedRoots = watchedRoots.map(Self.normalize).sorted()
        self.excludedRoots = excludedRoots.map(Self.normalize).sorted()
    }

    public func matchedRoot(for rawPath: String) -> String? {
        let path = Self.normalize(rawPath)
        guard !excludedRoots.contains(where: { Self.contains(path, root: $0) }) else { return nil }
        return watchedRoots.filter { Self.contains(path, root: $0) }.max(by: { $0.count < $1.count })
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

public struct EndpointEventNormalizer: Sendable {
    public init() {}

    public func normalize(_ notification: RawPrivilegedNotification, scope: EndpointMonitoringScope, gapBefore: Bool) throws -> NormalizedPrivilegedEvent? {
        guard notification.sequence > 0 else { throw EndpointBridgeError.invalidNotification("sequence must be positive") }
        guard notification.process.pid > 0 else { throw EndpointBridgeError.invalidNotification("process identity is invalid") }
        guard notification.path.hasPrefix("/") else { throw EndpointBridgeError.invalidNotification("path must be absolute") }
        guard let root = scope.matchedRoot(for: notification.destinationPath ?? notification.path) else { return nil }
        if notification.operation == .rename {
            guard let destination = notification.destinationPath, destination.hasPrefix("/") else {
                throw EndpointBridgeError.invalidNotification("rename requires an absolute destination")
            }
        }

        let logicalDelta = try delta(notification.size.logicalBefore, notification.size.logicalAfter)
        let allocatedDelta = try delta(notification.size.allocatedBefore, notification.size.allocatedAfter)
        let exact = notification.fileIdentity != nil
            && notification.size.isComplete
            && notification.deadlineMet
            && !gapBefore
        var limitations: [String] = []
        if notification.fileIdentity == nil { limitations.append("File identity is incomplete.") }
        if !notification.size.isComplete { limitations.append("Before/after size measurement is incomplete.") }
        if !notification.deadlineMet { limitations.append("The source callback deadline was missed.") }
        if gapBefore { limitations.append("A sequence or stream gap precedes this event.") }
        return NormalizedPrivilegedEvent(
            raw: notification,
            watchedRoot: root,
            logicalDelta: logicalDelta,
            allocatedDelta: allocatedDelta,
            gapBefore: gapBefore,
            confidence: exact ? .exact : .unknown,
            method: exact ? "endpoint-security-file-process" : "endpoint-security-incomplete",
            limitations: limitations
        )
    }

    private func delta(_ before: Int64?, _ after: Int64?) throws -> Int64 {
        guard let before, let after else { return 0 }
        let result = after.subtractingReportingOverflow(before)
        guard !result.overflow else { throw EndpointBridgeError.invalidNotification("size delta is not representable") }
        return result.partialValue
    }
}
