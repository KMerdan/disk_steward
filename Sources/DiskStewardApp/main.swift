import AppKit
import Foundation
import DiskStewardCore

// Hold one lifetime lease per evidence directory, even when Agent Access is off.
private var instanceLease: LocalServiceLease?
do {
    try AppConfiguration.validateLaunch(isSmoke: AppConfiguration.isSmoke)
} catch {
    fputs("Disk Steward cannot start: \(error.localizedDescription)\n", stderr)
    exit(1)
}
if !AppConfiguration.isSmoke, let identifier = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
    fputs("Disk Steward is already running. Quit the existing copy before starting another.\n", stderr)
    exit(0)
}
do {
    try FileManager.default.createDirectory(at: AppConfiguration.supportDirectory, withIntermediateDirectories: true)
    instanceLease = try LocalServiceLease(url: AppConfiguration.supportDirectory.appending(path: "application.lock"))
} catch {
    fputs("Disk Steward cannot start: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let application = NSApplication.shared
private let applicationDelegate = ApplicationDelegate()

application.setActivationPolicy(AppConfiguration.activationPolicy)
application.delegate = applicationDelegate

if CommandLine.arguments.contains("--ui-smoke") {
    application.finishLaunching()
    applicationDelegate.ensureStatusController()
    print(applicationDelegate.smokeReportJSON())
    applicationDelegate.statusController?.shutdown()
    // This path is freshly generated for this smoke launch, never supplied by a caller.
    try? FileManager.default.removeItem(at: AppConfiguration.supportDirectory)
} else {
    application.run()
}
