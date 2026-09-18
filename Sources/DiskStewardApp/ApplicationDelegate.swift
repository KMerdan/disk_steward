import AppKit
import Foundation

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusController: StatusItemController?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureStatusController()
        observePowerLifecycle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.shutdown()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let statusController else { return .terminateNow }
        if terminationTask == nil {
            terminationTask = Task {
                // A bounded drain avoids a permanent Quit hang. On timeout the
                // unfinished marker remains for the next launch's safety pause.
                _ = await statusController.shutdownAndDrain()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
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
