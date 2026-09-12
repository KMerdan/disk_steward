import AppKit
import Foundation

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureStatusController()
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
}
