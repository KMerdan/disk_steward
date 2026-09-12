import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Monitoring") {
                LabeledContent("Current mode", value: "Snapshot only")
                Text("Scheduled monitoring and thresholds arrive in the persistent recorder increment.")
                    .foregroundStyle(.secondary)
            }
            Section("Exports") {
                LabeledContent("Default folder", value: AppConfiguration.defaultExportFolderName)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460, height: 260)
        .accessibilityLabel("Disk Steward settings")
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 42))
                .foregroundStyle(.blue)
            Text("Disk Steward")
                .font(.title2.bold())
            Text("Version 0.1.0")
                .foregroundStyle(.secondary)
            Text("Storage evidence for humans and local coding agents.")
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 360, height: 230)
        .accessibilityLabel("About Disk Steward")
    }
}
