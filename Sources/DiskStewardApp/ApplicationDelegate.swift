import AppKit
import Foundation

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusController: StatusItemController?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureStatusController()
        observePowerLifecycle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    func ensureStatusController() {
        if statusController == nil {
            statusController = StatusItemController()
        }
    }

    func smokeReportJSON() -> String {
        let report = statusController?.smokeReport() ?? ["status": "not-launched"]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let output = String(data: data, encoding: .utf8)
        else { return #"{"status":"encoding-failed"}"# }
        return output
    }

    private func observePowerLifecycle() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.statusController?.systemWillSleep() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.statusController?.systemDidWake() }
            },
        ]
    }
}
