import AppKit
import Combine
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
    private let agentIntegrations: AgentIntegrationManager
    private var settingsWindow: NSWindow?
    private var reviewWindow: NSWindow?
    private lazy var reviewModel: ReviewWindowModel = makeReviewModel()
    private var changeJournalService: ChangeJournalService?
    /// The steward file's review index and service, shared by the review
    /// window and growth attribution; nil in the isolated smoke run.
    private let reviewIndex: ReviewIndex?
    private let reviewService: ReviewService?
    private let growthAttribution: GrowthAttributionService?
    private var growthTrigger: AnyCancellable?
    private var journalCheckpoint: AnyCancellable?
    private let changeJournalURL: URL?
    private let legacyEvidence: LegacyEvidenceController
    private var aboutWindow: NSWindow?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let smoke = AppConfiguration.isSmoke
        let persistence: any SettingsPersisting = smoke ? EphemeralSettingsPersistence() : UserDefaults.standard
        let settingsStore = MonitoringSettingsStore(persistence: persistence)
        if smoke {
            settingsStore.update { $0.watchedRoots = []; $0.excludedRoots = []; $0.monitoringPaused = true }
        }
        self.settingsStore = settingsStore
        launchAtLogin = LaunchAtLoginController()
        let supportDirectory: URL? = AppConfiguration.supportDirectory
        // TASK-653: before anything else touches the support directory, the
        // retired per-file evidence store is renamed, unmodified, into
        // legacy/. Nothing below opens the old path again.
        var legacyMigrationError: String?
        if !smoke, let supportDirectory {
            do {
                try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                try LegacyEvidence.migrate(supportDirectory: supportDirectory, at: Date(), migratedBy: AboutView().versionDescription)
            } catch {
                legacyMigrationError = error.localizedDescription
            }
        }
        let legacyEvidence = LegacyEvidenceController(supportDirectory: smoke ? nil : supportDirectory, migrationError: legacyMigrationError)
        self.legacyEvidence = legacyEvidence
        // The quiet guard: capacity sampling only, no per-file collector.
        let composition = MonitoringComposition.quietGuard()
        // Capacity history lives in its own small file, independent of the
        // evidence store. The isolated smoke run writes no history.
        let capacityRingURL = supportDirectory.map { CapacityRing.defaultURL(beside: $0.appending(path: "evidence.sqlite")) }
        let changeJournalURL = supportDirectory.map { ChangeJournal.defaultURL(beside: $0.appending(path: "evidence.sqlite")) }
        self.changeJournalURL = smoke ? nil : changeJournalURL
        let capacityRing = smoke ? nil : capacityRingURL.flatMap { try? CapacityRing(url: $0) }
        // TASK-661: growth attribution re-measures the objects the journal
        // marks dirty; it pauses while a review is measuring.
        let stewardURL = smoke ? nil : changeJournalURL
        let reviewIndex = stewardURL.flatMap { try? ReviewIndex(url: $0) }
        var reviewService: ReviewService?
        if let stewardURL, let reviewIndex { reviewService = ReviewService(index: reviewIndex, stateURL: ReviewService.defaultStateURL(beside: stewardURL)) }
        var growthAttribution: GrowthAttributionService?
        if let stewardURL, let reviewIndex, let capacityRingURL, let journal = try? ChangeJournal(url: stewardURL) {
            growthAttribution = GrowthAttributionService(
                journal: journal, index: reviewIndex, ringURL: capacityRingURL,
                fileURL: GrowthAttributionService.defaultFileURL(beside: stewardURL),
                paused: { [reviewService] in await reviewService?.isRunning ?? false })
        }
        self.reviewIndex = reviewIndex
        self.reviewService = reviewService
        self.growthAttribution = growthAttribution
        // TASK-672: agent sessions outlive a relaunch in the steward file.
        let sessionStore = stewardURL.flatMap { try? SessionStore(url: $0) }
        lifecycle = MonitoringLifecycleController(
            settingsStore: settingsStore, probe: composition.probe,
            notificationDelivery: smoke ? DisabledNotificationDelivery() : UserNotificationDelivery(),
            changeCollector: composition.changeCollector,
            safetyState: MonitoringSafetyStateStore(persistence: persistence),
            capacityRing: capacityRing
        )
        // Export reads a clone of the newest legacy set; the legacy files
        // themselves are never opened.
        let durableExporter: StatusBoardViewModel.EvidenceExporter? = smoke ? nil : { @Sendable destination async throws -> EvidenceBundleExportResult in
            let (manifest, support) = try await MainActor.run { () throws -> (LegacyEvidenceManifest, URL) in
                legacyEvidence.refresh()
                guard let newest = legacyEvidence.newest, let support = legacyEvidence.supportDirectory else {
                    throw LegacyEvidenceError.notFound("legacy evidence")
                }
                return (newest, support)
            }
            return try await LegacyEvidenceController.export(manifest, supportDirectory: support, to: destination)
        }
        viewModel = StatusBoardViewModel(
            evidenceExporter: durableExporter,
            exportParent: {
                if smoke { return AppConfiguration.supportDirectory.appending(path: "exports") }
                return StatusBoardViewModel.defaultExportParent()
            },
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
            let backend = try AppEvidenceQueryBackend(
                databaseURL: supportDirectory.appending(path: "evidence.sqlite"),
                retentionPolicyProvider: { try await MainActor.run { try settingsStore.settings.retentionPolicy() } },
                // Queries apply the user's current roots and exclusions immediately;
                // a policy change must not wait for the next scan to become visible.
                queryScopeProvider: { await MainActor.run { EvidenceQueryScope(settingsStore.settings.monitoringPolicy(at: Date()).scopeVersion(at: Date())) } },
                capacityRingURL: capacityRingURL,
                reserveProvider: { total in await MainActor.run { settingsStore.settings.reserveBytes(totalBytes: total) } },
                changeJournalURL: changeJournalURL,
                fileDetail: .retired(supportDirectory: supportDirectory),
                growthAttribution: growthAttribution,
                sessionStore: sessionStore,
                reviewIndex: reviewIndex,
                watchedRoots: {
                    await MainActor.run {
                        settingsStore.settings.monitoringPolicy(at: Date()).activeRoots(at: Date()).map { DirectoryChangeStream.canonicalPath($0.path) }
                    }
                }
            )
            return UnixSocketEvidenceServer(
                socketPath: supportDirectory.appending(path: "disk-steward.sock").path,
                handler: backend
            )
        }
        let integrationSupport = supportDirectory
            ?? AgentAccessStateFile.defaultURL().deletingLastPathComponent()
        let helperURL = Bundle.main.bundleURL
            .appending(path: "Contents/Helpers", directoryHint: .isDirectory)
            .appending(path: "disk-witness-mcp")
        if smoke {
            agentIntegrations = AgentIntegrationManager(
                descriptors: [], detector: KnownAgentClientDetector(environment: SystemAgentDetectionEnvironment()),
                adapters: [:], helperURL: helperURL
            )
        } else {
            agentIntegrations = AgentIntegrationManager.live(helperURL: helperURL, supportDirectory: integrationSupport)
        }
        super.init()
        viewModel.openReview = { [weak self] in self?.showReview() }
        configureStatusItem()
        configurePopover()
        configureMenu()
        lifecycle.start()
        startChangeJournal()
        startGrowthAttribution()
    }

    /// TASK-661: each capacity sample feeds the threshold trigger, which uses
    /// the growth threshold from Settings.
    private func startGrowthAttribution() {
        guard let growthAttribution else { return }
        let settingsStore = self.settingsStore
        growthTrigger = lifecycle.$latestObservation.dropFirst().sink { observation in
            guard let capacity = observation?.capacity, let identity = capacity.identity else { return }
            let used = capacity.volume.totalBytes - capacity.volume.availableBytes
            let threshold = Int64(settingsStore.settings.growthThresholdMiB) * 1_048_576
            Task { await growthAttribution.observe(usedBytes: used, volumeUUID: identity, thresholdBytes: threshold) }
        }
    }

    /// Which directories changed, from the FSEvents journal, with no disk walk.
    /// The cursor is checkpointed with every capacity sample.
    private func startChangeJournal() {
        guard let changeJournalURL, let journal = try? ChangeJournal(url: changeJournalURL) else { return }
        let service = ChangeJournalService(journal: journal)
        service.start(settingsStore: settingsStore)
        changeJournalService = service
        journalCheckpoint = lifecycle.$latestObservation.dropFirst().sink { _ in
            Task { await service.checkpoint() }
        }
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
            "isolated_smoke": AppConfiguration.isSmoke,
            "detail_sampling_paused": settingsStore.settings.monitoringPaused,
            "watched_root_count": settingsStore.settings.watchedRoots.count,
            "settings_persistence": settingsStore.persistence is EphemeralSettingsPersistence ? "ephemeral" : "user-defaults",
            "notifications_enabled": !AppConfiguration.isSmoke,
            "support_directory": AppConfiguration.supportDirectory.path,
        ]
    }

    func systemWillSleep() {
        lifecycle.prepareForSystemSleep()
    }

    func shutdown() {
        lifecycle.shutdown()
        agentAccess.shutdown()
    }

    func shutdownAndDrain() async -> Bool {
        shutdown()
        return await lifecycle.shutdownAndDrain()
    }

    func systemDidWake() {
        lifecycle.resumeAfterSystemWake()
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

    struct MenuEntry {
        let title: String
        let action: Selector
        let key: String
    }

    /// The utility menu in order; nil is a separator. The menu is built from
    /// this table, so a test sees every entry and the action it sends.
    static let menuEntries: [MenuEntry?] = [
        MenuEntry(title: AppMenuLabels.review, action: #selector(showReview), key: "r"),
        MenuEntry(title: AppMenuLabels.generalExport, action: #selector(exportEvidence), key: "e"),
        nil,
        MenuEntry(title: AppMenuLabels.settings, action: #selector(showSettings), key: ","),
        MenuEntry(title: AppMenuLabels.about, action: #selector(showAbout), key: ""),
        nil,
        MenuEntry(title: AppMenuLabels.quit, action: #selector(quit), key: "q"),
    ]

    private func configureMenu() {
        for entry in Self.menuEntries {
            guard let entry else { utilityMenu.addItem(.separator()); continue }
            addMenuItem(entry.title, action: entry.action, key: entry.key)
        }
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

    /// TASK-623: the review window over the steward file next to the journal.
    /// The isolated smoke run gets a window that cannot start a review.
    private func makeReviewModel() -> ReviewWindowModel {
        let settingsStore = self.settingsStore
        return ReviewWindowModel(
            service: reviewService, index: reviewIndex, scopes: reviewScopes(),
            capacity: { [weak viewModel] in
                guard let viewModel, let volume = viewModel.primaryVolume, !viewModel.capacityUnavailable else { return .unavailable }
                return .init(availableBytes: volume.availableBytes, reserveBytes: settingsStore.settings.reserveBytes(totalBytes: volume.totalBytes))
            },
            excluded: { settingsStore.settings.excludedRoots },
            optedInCaches: { settingsStore.settings.optedInCaches })
    }

    private func reviewScopes() -> [ReviewWindowModel.Scope] {
        settingsStore.settings.watchedRoots.map { .folder($0) } + (settingsStore.settings.optedInCaches.isEmpty ? [] : [.caches])
    }

    @objc private func showReview() {
        let model = reviewModel
        if !model.isReviewing {
            let scopes = reviewScopes()
            if !scopes.isEmpty, scopes != model.scopes {
                model.scopes = scopes
                if !scopes.contains(model.selectedScope) { model.selectedScope = scopes[0] }
            }
        }
        model.refreshCapacity()
        reviewWindow = present(rootView: ReviewWindowView(model: model), title: "Review Storage", existing: reviewWindow)
    }

    @objc private func showSettings() {
        settingsWindow = present(
            rootView: MonitoringSettingsView(
                settingsStore: settingsStore,
                lifecycle: lifecycle,
                launchAtLogin: launchAtLogin,
                agentAccess: agentAccess,
                agentIntegrations: agentIntegrations,
                legacyEvidence: legacyEvidence,
                onExportLegacy: { [weak self] in self?.exportEvidence() }
            ),
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
