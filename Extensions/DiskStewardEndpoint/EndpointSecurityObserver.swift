import DiskStewardCore
import Foundation

public enum EndpointSecurityStartupError: Error, Equatable, Sendable {
    case pendingUserApproval
    case notEntitled
    case notPermitted
    case tooManyClients
    case unavailable

    public var bridgeState: EndpointBridgeState {
        switch self {
        case .pendingUserApproval: .pendingUserApproval
        case .notEntitled: .notEntitled
        case .notPermitted: .notPermitted
        case .tooManyClients: .tooManyClients
        case .unavailable: .unavailable
        }
    }
}

public protocol EndpointSecurityNotificationRuntime: Sendable {
    func start(handler: @escaping @Sendable (RawPrivilegedNotification) -> Void) throws
    func stop()
}

public final class EndpointSecurityObserver: @unchecked Sendable {
    public static let notificationOnlySubscriptions = ["NOTIFY_CREATE", "NOTIFY_RENAME", "NOTIFY_WRITE", "NOTIFY_CLOSE"]

    private let runtime: any EndpointSecurityNotificationRuntime
    private let bridge: ProtectedEndpointBridge
    private let proof: EndpointBridgePeerProof

    public init(runtime: any EndpointSecurityNotificationRuntime, bridge: ProtectedEndpointBridge, proof: EndpointBridgePeerProof) {
        self.runtime = runtime
        self.bridge = bridge
        self.proof = proof
    }

    public func start() async {
        do {
            try runtime.start { [bridge, proof] notification in
                Task { _ = try? await bridge.receive(notification, proof: proof) }
            }
            await bridge.transition(to: .available)
        } catch let error as EndpointSecurityStartupError {
            await bridge.transition(to: error.bridgeState)
        } catch {
            await bridge.transition(to: .unavailable)
        }
    }

    public func stop() async {
        runtime.stop()
        await bridge.transition(to: .unavailable)
    }

    public func runtimeDidCrash() async {
        runtime.stop()
        await bridge.transition(to: .unavailable)
    }
}

public final class FixtureEndpointSecurityRuntime: EndpointSecurityNotificationRuntime, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (RawPrivilegedNotification) -> Void)?
    public var startupError: EndpointSecurityStartupError?

    public init(startupError: EndpointSecurityStartupError? = nil) { self.startupError = startupError }

    public func start(handler: @escaping @Sendable (RawPrivilegedNotification) -> Void) throws {
        if let startupError { throw startupError }
        lock.lock(); self.handler = handler; lock.unlock()
    }

    public func emit(_ notification: RawPrivilegedNotification) {
        lock.lock(); let callback = handler; lock.unlock()
        callback?(notification)
    }

    public func stop() {
        lock.lock(); handler = nil; lock.unlock()
    }
}

public struct UnavailableSystemEndpointSecurityRuntime: EndpointSecurityNotificationRuntime {
    public init() {}
    public func start(handler: @escaping @Sendable (RawPrivilegedNotification) -> Void) throws {
        throw EndpointSecurityStartupError.notEntitled
    }
    public func stop() {}
}
