import AppKit

enum AppConfiguration {
    static let activationPolicy: NSApplication.ActivationPolicy = .accessory
    static let defaultExportFolderName = "Disk Steward Exports"
}

enum AppMenuLabels {
    static let statusItem = "Disk Steward"
    static let generalExport = "Export Current Evidence"
    static let settings = "Settings…"
    static let about = "About Disk Steward"
    static let quit = "Quit Disk Steward"
}
