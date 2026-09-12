import Foundation
import ServiceManagement

protocol MainAppServiceBacking: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: MainAppServiceBacking {}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var errorMessage: String?

    private let service: MainAppServiceBacking

    init(service: MainAppServiceBacking = SMAppService.mainApp) {
        self.service = service
        isEnabled = service.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            isEnabled = enabled
            errorMessage = nil
        } catch {
            isEnabled = service.status == .enabled
            errorMessage = error.localizedDescription
        }
    }
}
