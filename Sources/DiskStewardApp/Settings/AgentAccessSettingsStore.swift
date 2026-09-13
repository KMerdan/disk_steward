import Combine
import DiskStewardCore
import Foundation

@MainActor
final class AgentAccessSettingsStore: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    let stateFile: AgentAccessStateFile

    init(stateFile: AgentAccessStateFile = .init(url: AgentAccessStateFile.defaultURL())) {
        self.stateFile = stateFile
        do {
            isEnabled = try stateFile.readEnabled()
            errorMessage = nil
        } catch {
            isEnabled = false
            errorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        try stateFile.write(enabled: enabled)
        isEnabled = enabled
        errorMessage = nil
    }

    func record(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
