import AppKit
import SwiftUI

struct MonitoringSettingsView: View {
    @ObservedObject var settingsStore: MonitoringSettingsStore
    @ObservedObject var lifecycle: MonitoringLifecycleController
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @State private var investigationHours = 1

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
                Button("Add Watched Folder…") { chooseFolder(settingsStore.addWatchedRoot) }
                Text("Other disk growth remains visible as unexplained whole-volume change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy exclusions") {
                pathList(settingsStore.settings.excludedRoots, remove: settingsStore.removeExcludedRoot)
                Button("Add Excluded Folder…") { chooseFolder(settingsStore.addExcludedRoot) }
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

    private func chooseFolder(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }
}
