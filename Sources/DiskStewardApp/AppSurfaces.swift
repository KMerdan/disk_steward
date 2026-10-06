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
    let versionDescription: String

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        let version = nonEmpty(infoDictionary?["CFBundleShortVersionString"] as? String)
        let rawBuild = infoDictionary?["CFBundleVersion"]
        let build = nonEmpty((rawBuild as? String) ?? (rawBuild as? Int).map { String($0) })
        switch (version, build) {
        case let (version?, build?): versionDescription = "Version \(version) (\(build))"
        case let (version?, nil): versionDescription = "Version \(version)"
        case let (nil, build?): versionDescription = "Build \(build)"
        case (nil, nil): versionDescription = "Development build"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.85), Color.indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)

                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 4)

            VStack(spacing: 4) {
                Text("Disk Steward")
                    .font(.title2.bold())

                Text(versionDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Storage evidence for humans and local coding agents.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .padding(24)
        .frame(width: 360, height: 230)
        .accessibilityLabel("About Disk Steward")
    }
}
