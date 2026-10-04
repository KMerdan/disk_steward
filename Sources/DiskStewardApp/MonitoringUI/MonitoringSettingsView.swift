import DiskStewardCore
import Foundation
import SwiftUI

struct MonitoringSettingsView: View {
    @ObservedObject var settingsStore: MonitoringSettingsStore
    @ObservedObject var lifecycle: MonitoringLifecycleController
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var agentAccess: MCPAccessController
    @ObservedObject var agentIntegrations: AgentIntegrationManager
    @ObservedObject var legacyEvidence: LegacyEvidenceController
    var onExportLegacy: () -> Void = {}
    @State private var pendingDeletion: LegacyEvidenceManifest?
    @State private var deletionError: String?
    @State private var folderSelection: FolderSelectionPurpose?

    var body: some View {
        Form {
            Section("Lifecycle") {
                Toggle("Launch Disk Steward at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { enabled in
                        launchAtLogin.setEnabled(enabled)
                        settingsStore.update { $0.launchAtLogin = launchAtLogin.isEnabled }
                    }
                ))
                if let error = launchAtLogin.errorMessage {
                    Text(error).foregroundStyle(.red).accessibilityLabel("Launch at login error: \(error)")
                }
                Button(settingsStore.settings.monitoringPaused ? "Resume Monitoring" : "Pause Monitoring") {
                    settingsStore.settings.monitoringPaused ? lifecycle.resume() : lifecycle.pause()
                }
            }

            Section("AI access") {
                Toggle("Agent Access (read only)", isOn: Binding(
                    get: { agentAccess.isEnabled },
                    set: { enabled in agentAccess.setEnabled(enabled) }
                ))
                Text(agentAccess.state.detail)
                    .font(.caption)
                    .foregroundStyle(agentAccess.state.kind == .degraded ? .orange : .secondary)
                    .accessibilityLabel(agentAccess.state.accessibilitySummary)
                Text("Client setup below and Agent Access are separate: installing a client entry never turns access on.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                AgentIntegrationsView(manager: agentIntegrations)
            }

            Section("Review scopes") {
                pathList(settingsStore.settings.watchedRoots, remove: settingsStore.removeWatchedRoot)
                Button("Add Review Scope…") { folderSelection = .watched }
                Text("Folders changed inside these scopes are journaled without scanning files. Other disk growth remains visible as unexplained whole-volume change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cache review") {
                ForEach(CacheCatalog.entries) { entry in
                    let path = entry.resolvedPath(home: NSHomeDirectory())
                    Toggle(isOn: Binding(
                        get: { settingsStore.settings.optedInCaches.contains(entry.id) },
                        set: { optedIn in settingsStore.update { $0.setCache(entry.id, optedIn: optedIn) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not found on this Mac")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .disabled(path == nil)
                    .accessibilityHint("Includes \(entry.name) in reviews you start. Its cleanup command is shown, never run.")
                }
                Text("A cache is measured only in reviews you start, and only when turned on here. Disk Steward shows each tool's own cleanup command; it never runs one.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy exclusions") {
                pathList(settingsStore.settings.excludedRoots, remove: settingsStore.removeExcludedRoot)
                Button("Add Excluded Folder…") { folderSelection = .excluded }
            }

            Section("Thresholds") {
                Stepper(reserveLabel, value: reserveBinding, in: 1 ... 65_536, step: 5)
                    .accessibilityHint("Notifies once when free space falls below this amount on two samples in a row.")
                if settingsStore.settings.comfortReserveGiB != nil {
                    Button("Use suggested reserve") { settingsStore.update { $0.comfortReserveGiB = nil } }
                }
                Stepper("Notify after \(settingsStore.settings.growthThresholdMiB) MiB growth", value: binding(\.growthThresholdMiB), in: 1 ... 1_048_576, step: 100)
                Stepper("Sample every \(settingsStore.settings.sampleIntervalMinutes) minutes", value: binding(\.sampleIntervalMinutes), in: 1 ... 1_440)
            }

            Section("Legacy evidence") {
                if let newest = legacyEvidence.newest {
                    Text("File evidence from before \(newest.migratedAt.formatted(date: .abbreviated, time: .omitted)) (\(ByteCountFormatter.string(fromByteCount: newest.databaseBytes, countStyle: .file))) is kept unmodified for export or rollback. Nothing reads or adds to it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Export Legacy Evidence…") { onExportLegacy() }
                    Button("Delete Legacy Evidence…", role: .destructive) { pendingDeletion = newest }
                } else {
                    Text("No legacy evidence is kept.").foregroundStyle(.secondary)
                }
                if let error = legacyEvidence.migrationError {
                    Text("The old evidence store could not be moved to legacy/: \(error)").foregroundStyle(.red)
                }
                if let deletionError {
                    Text(deletionError).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620, height: 760)
        .accessibilityLabel("Disk Steward monitoring settings")
        .confirmationDialog(
            "Delete legacy evidence?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { manifest in
            Button("Move to Trash", role: .destructive) {
                do {
                    try legacyEvidence.delete(manifest, confirmed: true)
                    deletionError = nil
                } catch {
                    deletionError = "Legacy evidence was not deleted: \(error.localizedDescription)"
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { manifest in
            Text("The evidence from before \(manifest.migratedAt.formatted(date: .abbreviated, time: .omitted)) moves to the Trash. Export it first if you may need it; without it, rolling back to an earlier version starts with no evidence.")
        }
        .sheet(item: $folderSelection) { purpose in
            FolderSelectionSheet(
                purpose: purpose,
                initialURL: initialFolder(for: purpose)
            ) { url in
                switch purpose {
                case .watched:
                    settingsStore.addWatchedRoot(url.standardizedFileURL)
                case .excluded:
                    settingsStore.addExcludedRoot(url.standardizedFileURL)
                }
            }
        }
    }

    private var startupDiskBytes: Int64 {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity).map { Int64($0) } ?? 0
    }

    private var effectiveReserveGiB: Int {
        settingsStore.settings.comfortReserveGiB
            ?? MonitoringSettings.suggestedReserveGiB(totalBytes: startupDiskBytes, capacityThresholdPercent: settingsStore.settings.capacityThresholdPercent)
    }

    private var reserveLabel: String {
        let suffix = settingsStore.settings.comfortReserveGiB == nil ? " (suggested for this disk)" : ""
        return "Keep at least \(effectiveReserveGiB) GiB free\(suffix)"
    }

    private var reserveBinding: Binding<Int> {
        Binding(get: { effectiveReserveGiB }, set: { value in settingsStore.update { $0.comfortReserveGiB = value } })
    }

    private func binding(_ keyPath: WritableKeyPath<MonitoringSettings, Int>) -> Binding<Int> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { value in settingsStore.update { $0[keyPath: keyPath] = value } }
        )
    }

    @ViewBuilder
    private func pathList(_ paths: [String], remove: @escaping (String) -> Void) -> some View {
        ForEach(paths, id: \.self) { path in
            HStack {
                Text(path).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Remove") { remove(path) }.buttonStyle(.borderless)
            }
        }
    }

    private func initialFolder(for purpose: FolderSelectionPurpose) -> URL {
        let configuredPath: String?
        switch purpose {
        case .watched:
            configuredPath = settingsStore.settings.watchedRoots.last
        case .excluded:
            configuredPath = settingsStore.settings.excludedRoots.last
        }
        return configuredPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}

enum FolderSelectionPurpose: String, Identifiable {
    case watched
    case excluded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .watched: "Add Watched Folder"
        case .excluded: "Add Excluded Folder"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .watched: "Watch This Folder"
        case .excluded: "Exclude This Folder"
        }
    }
}

@MainActor
final class FolderSelectionModel: ObservableObject {
    @Published private(set) var currentURL: URL
    @Published private(set) var directories: [URL] = []
    @Published var pathText: String
    @Published private(set) var errorMessage: String?

    private let fileManager: FileManager
    private let homeURL: URL

    init(
        initialURL: URL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.homeURL = homeURL.standardizedFileURL
        let start = initialURL.standardizedFileURL
        currentURL = start
        pathText = start.path
        navigate(to: start)
    }

    var canGoUp: Bool { currentURL.path != "/" }

    var selectedURL: URL? {
        var isDirectory: ObjCBool = false
        let path = currentURL.standardizedFileURL.path
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    func navigate(to candidate: URL) {
        let url = candidate.standardizedFileURL
        guard isReadableDirectory(url) else {
            errorMessage = "Disk Steward cannot read that folder. Check the path or its privacy permission."
            return
        }

        currentURL = url
        pathText = url.path
        do {
            directories = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            )
            .filter { child in
                (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            errorMessage = nil
        } catch {
            directories = []
            errorMessage = "This folder is selected, but its contents cannot be listed: \(error.localizedDescription)"
        }
    }

    func goToTypedPath() {
        let expanded = NSString(string: pathText).expandingTildeInPath
        navigate(to: URL(fileURLWithPath: expanded, isDirectory: true))
    }

    func goHome() { navigate(to: homeURL) }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isReadableFile(atPath: url.path)
    }
}

private struct FolderSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: FolderSelectionModel

    let purpose: FolderSelectionPurpose
    let onSelect: (URL) -> Void

    init(purpose: FolderSelectionPurpose, initialURL: URL, onSelect: @escaping (URL) -> Void) {
        self.purpose = purpose
        self.onSelect = onSelect
        _model = StateObject(wrappedValue: FolderSelectionModel(initialURL: initialURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(purpose.title)
                .font(.title2.weight(.semibold))

            HStack(spacing: 8) {
                Button(action: model.goUp) {
                    Image(systemName: "chevron.up")
                }
                .disabled(!model.canGoUp)
                .help("Parent Folder")
                .accessibilityLabel("Go to parent folder")

                Button(action: model.goHome) {
                    Image(systemName: "house")
                }
                .help("Home Folder")
                .accessibilityLabel("Go to home folder")

                TextField("Folder path", text: $model.pathText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.goToTypedPath)

                Button("Go", action: model.goToTypedPath)
            }

            Text(model.currentURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            List(model.directories, id: \.path) { directory in
                Button {
                    model.navigate(to: directory)
                } label: {
                    Label(directory.lastPathComponent, systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this folder in the folder browser")
            }
            .frame(minHeight: 270)

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Folder error: \(errorMessage)")
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(purpose.confirmationTitle) {
                    guard let selectedURL = model.selectedURL else { return }
                    onSelect(selectedURL)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedURL == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 440)
        .accessibilityLabel(purpose.title)
    }
}
