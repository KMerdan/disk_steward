import Combine
import DiskStewardCore
import Foundation

protocol MCPAccessServing: AnyObject {
    func start() throws
    func stop()
}

extension UnixSocketEvidenceServer: MCPAccessServing {}

struct MCPAccessState: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case off
        case starting
        case on
        case degraded
    }

    let kind: Kind
    let title: String
    let detail: String

    var accessibilitySummary: String { "Agent Access \(title). \(detail)" }

    static let off = MCPAccessState(
        kind: .off,
        title: "Off",
        detail: "AI tools cannot query Disk Steward. Monitoring and stored evidence continue."
    )
    static let starting = MCPAccessState(
        kind: .starting,
        title: "Starting",
        detail: "Opening the private, current-user evidence service."
    )
    static let on = MCPAccessState(
        kind: .on,
        title: "On",
        detail: "Read-only evidence queries are available through the private local socket."
    )

    static func degraded(_ reason: String) -> MCPAccessState {
        MCPAccessState(
            kind: .degraded,
            title: "Needs Attention",
            detail: "Agent Access was requested but is unavailable: \(reason)"
        )
    }
}

@MainActor
final class MCPAccessController: ObservableObject {
    typealias ServerFactory = () throws -> any MCPAccessServing

    @Published private(set) var state: MCPAccessState

    private let settingsStore: AgentAccessSettingsStore
    private let serverFactory: ServerFactory
    private var server: (any MCPAccessServing)?

    var isEnabled: Bool { settingsStore.isEnabled }

    init(settingsStore: AgentAccessSettingsStore, serverFactory: @escaping ServerFactory) {
        self.settingsStore = settingsStore
        self.serverFactory = serverFactory
        state = settingsStore.isEnabled ? .starting : .off
        if settingsStore.isEnabled { startService() }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try settingsStore.setEnabled(true)
                startService()
            } catch {
                settingsStore.record(error)
                state = .degraded(error.localizedDescription)
            }
        } else {
            server?.stop()
            server = nil
            do {
                try settingsStore.setEnabled(false)
                state = .off
            } catch {
                settingsStore.record(error)
                state = .degraded(error.localizedDescription)
            }
        }
    }

    private func startService() {
        state = .starting
        do {
            let candidate = try serverFactory()
            try candidate.start()
            server = candidate
            state = .on
        } catch {
            server?.stop()
            server = nil
            settingsStore.record(error)
            state = .degraded(error.localizedDescription)
        }
    }
}
