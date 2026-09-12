import AppKit
import Foundation

let application = NSApplication.shared
private let applicationDelegate = ApplicationDelegate()

application.setActivationPolicy(AppConfiguration.activationPolicy)
application.delegate = applicationDelegate

if CommandLine.arguments.contains("--ui-smoke") {
    application.finishLaunching()
    applicationDelegate.ensureStatusController()
    print(applicationDelegate.smokeReportJSON())
} else {
    application.run()
}
