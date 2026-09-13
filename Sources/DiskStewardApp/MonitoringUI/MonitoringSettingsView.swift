import Foundation
import SwiftUI

struct MonitoringSettingsView: View {
    @ObservedObject var settingsStore: MonitoringSettingsStore
    @ObservedObject var lifecycle: MonitoringLifecycleController
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @State private var investigationHours = 1
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

            Section("Detailed evidence roots") {
                pathList(settingsStore.settings.watchedRoots, remove: settingsStore.removeWatchedRoot)
                Button("Add Watched Folder…") { folderSelection = .watched }
                Text("Other disk growth remains visible as unexplained whole-volume change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy exclusions") {
                pathList(settingsStore.settings.excludedRoots, remove: settingsStore.removeExcludedRoot)
                Button("Add Excluded Folder…") { folderSelection = .excluded }
            }

            Section("Thresholds and retention") {
                Stepper("Notify at \(settingsStore.settings.capacityThresholdPercent)% capacity", value: binding(\.capacityThresholdPercent), in: 50 ... 99)
                Stepper("Notify after \(settingsStore.settings.growthThresholdMiB) MiB growth", value: binding(\.growthThresholdMiB), in: 1 ... 1_048_576, step: 100)
                Stepper("Sample every \(settingsStore.settings.sampleIntervalMinutes) minutes", value: binding(\.sampleIntervalMinutes), in: 1 ... 1_440)
                Stepper("Keep raw events \(settingsStore.settings.rawEventDays) days", value: binding(\.rawEventDays), in: 1 ... 30)
                Stepper("Evidence database limit \(settingsStore.settings.maxDatabaseMiB) MiB", value: binding(\.maxDatabaseMiB), in: 10 ... 10_240, step: 10)
            }

            Section("Investigation window") {
                Stepper("Duration: \(investigationHours) hours", value: $investigationHours, in: 1 ... 24)
                if let root = settingsStore.settings.watchedRoots.first {
                    Button(settingsStore.settings.investigationRoot == nil ? "Investigate First Watched Root" : "End Investigation") {
                        if settingsStore.settings.investigationRoot == nil {
                            settingsStore.beginInvestigation(root: root, hours: investigationHours)
                        } else {
                            settingsStore.endInvestigation()
                        }
                    }
                    Text(root).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Add a watched folder before starting an investigation.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560, height: 620)
        .accessibilityLabel("Disk Steward monitoring settings")
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
