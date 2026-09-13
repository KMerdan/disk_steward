import AppKit
import DiskStewardCore
import SwiftUI

enum StatusItemSurface: String {
    case statusBoard = "status-board"
    case utilityMenu = "utility-menu"

    static func route(for eventType: NSEvent.EventType) -> StatusItemSurface {
        eventType == .rightMouseUp ? .utilityMenu : .statusBoard
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let utilityMenu = NSMenu(title: "Disk Steward")
    private let viewModel: StatusBoardViewModel
    private let settingsStore: MonitoringSettingsStore
    private let lifecycle: MonitoringLifecycleController
    private let launchAtLogin: LaunchAtLoginController
    private let agentAccess: MCPAccessController
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let settingsStore = MonitoringSettingsStore()
        self.settingsStore = settingsStore
        launchAtLogin = LaunchAtLoginController()
        let probe: MonitoringProbing
        var supportDirectory: URL?
        var evidenceDatabaseURL: URL?
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "Disk Steward", directoryHint: .isDirectory)
            supportDirectory = support
            let databaseURL = support.appending(path: "evidence.sqlite")
            evidenceDatabaseURL = databaseURL
            probe = try PersistentMonitoringProbe(databaseURL: databaseURL)
        } catch {
            probe = UnavailableMonitoringProbe(reason: error.localizedDescription)
        }
        lifecycle = MonitoringLifecycleController(settingsStore: settingsStore, probe: probe)
        let durableExporter: StatusBoardViewModel.EvidenceExporter?
        if let databaseURL = evidenceDatabaseURL {
            durableExporter = { @Sendable destination async throws -> EvidenceBundleExportResult in
                let store = try EvidenceStore(url: databaseURL)
                let now = Date()
                do {
                    let result = try await EvidenceBundleExporter().export(
                        store: store,
                        options: .init(from: now.addingTimeInterval(-30 * 86_400), through: now),
                        to: destination
                    )
                    await store.close()
                    return result
                } catch {
                    await store.close()
                    throw error
                }
            }
        } else {
            durableExporter = nil
        }
        viewModel = StatusBoardViewModel(
            evidenceExporter: durableExporter,
            exportCompletion: { url in NSWorkspace.shared.open(url) },
            lifecycle: lifecycle
        )
        let accessSettings = AgentAccessSettingsStore(
            stateFile: .init(url: supportDirectory?.appending(path: "agent-access.json") ?? AgentAccessStateFile.defaultURL())
        )
        agentAccess = MCPAccessController(settingsStore: accessSettings) {
            guard let supportDirectory else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Application Support is unavailable."])
            }
            let backend = try AppEvidenceQueryBackend(databaseURL: supportDirectory.appending(path: "evidence.sqlite"))
            return UnixSocketEvidenceServer(
                socketPath: supportDirectory.appending(path: "disk-steward.sock").path,
                handler: backend
            )
        }
        super.init()
        configureStatusItem()
        configurePopover()
        configureMenu()
        lifecycle.start()
    }

    @objc func handleStatusItemClick(_ sender: Any?) {
        let surface = StatusItemSurface.route(for: NSApp.currentEvent?.type ?? .leftMouseUp)
        switch surface {
        case .statusBoard: showStatusBoard()
        case .utilityMenu: showUtilityMenu()
        }
    }

    func smokeReport() -> [String: Any] {
        viewModel.refresh()
        return [
            "status": "launched",
            "activation_policy": AppConfiguration.activationPolicy == .accessory ? "accessory" : "unexpected",
            "status_item_accessibility_label": statusItem.button?.accessibilityLabel() ?? "",
            "left_click_surface": StatusItemSurface.route(for: .leftMouseUp).rawValue,
            "right_click_surface": StatusItemSurface.route(for: .rightMouseUp).rawValue,
            "menu_items": utilityMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            "snapshot_available": viewModel.primaryVolume != nil,
            "agent_access": agentAccess.state.kind.rawValue,
            "ipc_service": agentAccess.state.kind == .on ? "active" : agentAccess.state.kind.rawValue,
        ]
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: AppMenuLabels.statusItem)
        button.image?.isTemplate = true
        button.toolTip = "Disk Steward — click for storage status, right-click for menu"
        button.setAccessibilityLabel(AppMenuLabels.statusItem)
        button.setAccessibilityHelp("Left-click opens storage status. Right-click opens utility actions.")
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: StatusBoardView(
                viewModel: viewModel,
                lifecycle: lifecycle,
                agentAccess: agentAccess,
                onOpenSettings: { [weak self] in self?.showSettings() }
            )
        )
    }

    private func configureMenu() {
        addMenuItem(AppMenuLabels.generalExport, action: #selector(exportEvidence), key: "e")
        utilityMenu.addItem(.separator())
        addMenuItem(AppMenuLabels.settings, action: #selector(showSettings), key: ",")
        addMenuItem(AppMenuLabels.about, action: #selector(showAbout))
        utilityMenu.addItem(.separator())
        addMenuItem(AppMenuLabels.quit, action: #selector(quit), key: "q")
    }

    private func addMenuItem(_ title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.setAccessibilityLabel(title)
        utilityMenu.addItem(item)
    }

    private func showStatusBoard() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            viewModel.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showUtilityMenu() {
        popover.performClose(nil)
        guard let button = statusItem.button else { return }
        utilityMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func exportEvidence() {
        Task { @MainActor in
            _ = await viewModel.exportCurrentEvidence()
        }
    }

    @objc private func showSettings() {
        settingsWindow = present(
            rootView: MonitoringSettingsView(settingsStore: settingsStore, lifecycle: lifecycle, launchAtLogin: launchAtLogin),
            title: "Disk Steward Settings",
            existing: settingsWindow
        )
    }

    @objc private func showAbout() {
        aboutWindow = present(rootView: AboutView(), title: "About Disk Steward", existing: aboutWindow)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func present<Content: View>(rootView: Content, title: String, existing: NSWindow?) -> NSWindow {
        if let existing {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
}
