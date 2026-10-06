import AppKit
import Foundation
import SwiftUI

struct AgentIntegrationRowPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let symbolName: String
    let isSelectable: Bool
    let isSelected: Bool
    let accessibilityLabel: String

    init(snapshot: AgentIntegrationSnapshot, isSelected: Bool, resultMessage: String? = nil) {
        title = snapshot.descriptor.displayName
        detail = resultMessage ?? snapshot.statusDetail
        self.isSelected = isSelected
        isSelectable = snapshot.canSelectForSetup
        switch snapshot.state {
        case .verified: symbolName = "checkmark.seal.fill"
        case .stale: symbolName = "clock.badge.exclamationmark"
        case .configured, .approvalPending: symbolName = "checkmark.circle.fill"
        case .available: symbolName = "circle"
        case .broken, .conflict, .unavailable: symbolName = "exclamationmark.triangle.fill"
        case .notDetected: symbolName = "minus.circle"
        }
        accessibilityLabel = "\(title). \(snapshot.state.rawValue). \(detail)"
    }
}

@MainActor
final class AgentIntegrationManager: ObservableObject {
    @Published private(set) var snapshots: [AgentClientID: AgentIntegrationSnapshot] = [:]
    @Published private(set) var results: [AgentClientID: AgentIntegrationOperationResult] = [:]
    @Published private(set) var busyClients: Set<AgentClientID> = []
    @Published var selectedClients: Set<AgentClientID> = []

    private let descriptors: [AgentClientDescriptor]
    private let detector: KnownAgentClientDetector
    private let adapters: [AgentClientID: any AgentIntegrationAdapting]
    private let helperURL: URL

    init(
        descriptors: [AgentClientDescriptor] = AgentClientDescriptor.supported,
        detector: KnownAgentClientDetector,
        adapters: [AgentClientID: any AgentIntegrationAdapting],
        helperURL: URL
    ) {
        self.descriptors = descriptors
        self.detector = detector
        self.adapters = adapters
        self.helperURL = helperURL.standardizedFileURL
        for descriptor in descriptors {
            let presence = detector.detect(descriptor)
            snapshots[descriptor.id] = Self.placeholderSnapshot(
                descriptor: descriptor,
                presence: presence,
                hasAdapter: adapters[descriptor.id] != nil
            )
        }
    }

    static func live(
        helperURL: URL,
        supportDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentIntegrationManager {
        let environment = SystemAgentDetectionEnvironment()
        let detector = KnownAgentClientDetector(environment: environment)
        let receipts = AgentIntegrationReceiptStore(url: supportDirectory.appending(path: "agent-integrations.json"))
        var adapters: [AgentClientID: any AgentIntegrationAdapting] = [:]
        if let executable = environment.executableURL(named: "codex") {
            // Codex reads user skills from $CODEX_HOME/skills (~/.codex/skills).
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
                ?? homeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
            adapters[.codex] = CodexCLIIntegrationAdapter(
                executableURL: executable,
                helperURL: helperURL,
                receiptStore: receipts,
                skillsDirectory: codexHome.appending(path: "skills", directoryHint: .isDirectory)
            )
        }
        if let executable = environment.executableURL(named: "claude") {
            adapters[.claudeCode] = ClaudeCodeIntegrationAdapter(
                executableURL: executable,
                helperURL: helperURL,
                receiptStore: receipts,
                skillsDirectory: homeDirectory.appending(path: ".claude/skills", directoryHint: .isDirectory)
            )
        }
        let applicationSupport = homeDirectory
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        if case .detected = detector.detect(descriptor(.cursor)) {
            adapters[.cursor] = CursorIntegrationAdapter(
                configurationURL: homeDirectory.appending(path: ".cursor/mcp.json"),
                helperURL: helperURL,
                receiptStore: receipts
            )
        }
        if case .detected = detector.detect(descriptor(.visualStudioCode)) {
            adapters[.visualStudioCode] = VSCodeIntegrationAdapter(
                configurationURL: applicationSupport.appending(path: "Code/User/mcp.json"),
                helperURL: helperURL,
                receiptStore: receipts
            )
        }
        if case .detected = detector.detect(descriptor(.claudeDesktop)) {
            adapters[.claudeDesktop] = ClaudeDesktopIntegrationAdapter(
                configurationURL: applicationSupport.appending(path: "Claude/claude_desktop_config.json"),
                helperURL: helperURL,
                receiptStore: receipts
            )
        }
        adapters[.manual] = ManualIntegrationAdapter(helperURL: helperURL)
        return AgentIntegrationManager(
            detector: detector,
            adapters: adapters,
            helperURL: helperURL
        )
    }

    private static func descriptor(_ id: AgentClientID) -> AgentClientDescriptor {
        AgentClientDescriptor.supported.first { $0.id == id }!
    }

    var orderedSnapshots: [AgentIntegrationSnapshot] {
        descriptors.compactMap { snapshots[$0.id] }
    }

    var canSetUpSelected: Bool {
        selectedClients.contains { snapshots[$0]?.canSelectForSetup == true }
            && busyClients.isEmpty
    }

    func setSelected(_ selected: Bool, clientID: AgentClientID) {
        guard snapshots[clientID]?.canSelectForSetup == true else {
            selectedClients.remove(clientID)
            return
        }
        if selected { selectedClients.insert(clientID) } else { selectedClients.remove(clientID) }
    }

    func rescan() async {
        for descriptor in descriptors {
            let snapshot: AgentIntegrationSnapshot
            if let adapter = adapters[descriptor.id] {
                snapshot = await adapter.inspect()
            } else {
                snapshot = Self.placeholderSnapshot(
                    descriptor: descriptor,
                    presence: detector.detect(descriptor),
                    hasAdapter: false
                )
            }
            snapshots[descriptor.id] = snapshot
            if !snapshot.canSelectForSetup { selectedClients.remove(descriptor.id) }
        }
    }

    func setupSelected() async {
        let ids = descriptors.map(\.id).filter(selectedClients.contains)
        for clientID in ids {
            await perform(.setup, clientID: clientID)
        }
    }

    func perform(_ action: AgentIntegrationAction, clientID: AgentClientID) async {
        guard !busyClients.contains(clientID) else { return }
        guard let adapter = adapters[clientID] else {
            guard let snapshot = snapshots[clientID] else { return }
            results[clientID] = AgentIntegrationOperationResult(
                clientID: clientID,
                action: action,
                outcome: .failed,
                message: "Automatic setup requires the \(snapshot.descriptor.displayName) command-line tool. Use the manual configuration instead.",
                snapshot: snapshot
            )
            return
        }
        busyClients.insert(clientID)
        defer { busyClients.remove(clientID) }
        let result = await adapter.perform(action)
        results[clientID] = result
        snapshots[clientID] = result.snapshot
        if !result.snapshot.canSelectForSetup { selectedClients.remove(clientID) }
    }

    private static func placeholderSnapshot(
        descriptor: AgentClientDescriptor,
        presence: AgentClientPresence,
        hasAdapter: Bool
    ) -> AgentIntegrationSnapshot {
        if descriptor.id == .manual {
            return .derive(descriptor: descriptor, presence: .detected(location: nil), inspection: .missing)
        }
        if case .detected = presence, !hasAdapter {
            return .derive(
                descriptor: descriptor,
                presence: presence,
                inspection: .unavailable(reason: "App detected; automatic setup requires its command-line tool or adapter.")
            )
        }
        return .derive(descriptor: descriptor, presence: presence, inspection: .missing)
    }
}

struct AgentIntegrationsView: View {
    @ObservedObject var manager: AgentIntegrationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent integrations").font(.headline)
                    Text("Choose where Disk Steward should install its read-only evidence server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await manager.rescan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Detects supported MCP clients again.")
            }

            VStack(spacing: 6) {
                ForEach(manager.orderedSnapshots) { snapshot in
                    integrationRow(snapshot)
                }
            }

            HStack {
                Button("Set Up Selected") { Task { await manager.setupSelected() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!manager.canSetUpSelected)
                    .accessibilityHint("Configures each selected client independently and reports each result.")
                Spacer()
                Text("Never deletes files or enables Agent Access.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await manager.rescan() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent integrations setup")
    }

    @ViewBuilder
    private func integrationRow(_ snapshot: AgentIntegrationSnapshot) -> some View {
        let presentation = AgentIntegrationRowPresentation(
            snapshot: snapshot,
            isSelected: manager.selectedClients.contains(snapshot.id),
            resultMessage: manager.results[snapshot.id]?.message
        )
        HStack(alignment: .center, spacing: 10) {
            Toggle(isOn: Binding(
                get: { manager.selectedClients.contains(snapshot.id) },
                set: { manager.setSelected($0, clientID: snapshot.id) }
            )) { EmptyView() }
            .labelsHidden()
            .disabled(!presentation.isSelectable || manager.busyClients.contains(snapshot.id))
            .accessibilityLabel("Select \(presentation.title) for setup")
            .accessibilityValue(presentation.isSelected ? "Selected" : "Not selected")

            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(clientIconGradient(snapshot.id))
                    .frame(width: 28, height: 28)
                Image(systemName: clientIconName(snapshot.id))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(presentation.title).font(.body.weight(.medium))

                    HStack(spacing: 3) {
                        Image(systemName: presentation.symbolName)
                            .font(.system(size: 9, weight: .semibold))
                        Text(snapshot.state.rawValue.capitalized)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(statusColor(snapshot.state).opacity(0.12))
                    )
                    .foregroundStyle(statusColor(snapshot.state))
                }

                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)

            Spacer(minLength: 8)
            actions(for: snapshot)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(presentation.isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(presentation.isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func actions(for snapshot: AgentIntegrationSnapshot) -> some View {
        if snapshot.id == .manual {
            Button("Copy Config") { Task { await manager.perform(.setup, clientID: .manual) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Copy manual MCP configuration")
        } else if manager.busyClients.contains(snapshot.id) {
            ProgressView().controlSize(.small).accessibilityLabel("Working on \(snapshot.descriptor.displayName)")
        } else {
            Menu("Actions") {
                Button("Test Connection") { Task { await manager.perform(.verify, clientID: snapshot.id) } }
                Button("Repair") { Task { await manager.perform(.repair, clientID: snapshot.id) } }
                Divider()
                Button("Remove Disk Steward Configuration", role: .destructive) {
                    Task { await manager.perform(.remove, clientID: snapshot.id) }
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .disabled(snapshot.state == .notDetected || snapshot.state == .unavailable)
            .accessibilityLabel("Actions for \(snapshot.descriptor.displayName)")
        }
    }

    private func clientIconName(_ id: AgentClientID) -> String {
        switch id {
        case .codex: return "terminal"
        case .claudeCode: return "sparkles"
        case .cursor: return "chevron.right"
        case .visualStudioCode: return "curlybraces"
        case .claudeDesktop: return "macwindow"
        case .manual: return "wrench.and.screwdriver"
        }
    }

    private func clientIconGradient(_ id: AgentClientID) -> LinearGradient {
        switch id {
        case .codex:
            return LinearGradient(colors: [Color.primary.opacity(0.8), Color.primary.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        case .claudeCode, .claudeDesktop:
            return LinearGradient(colors: [Color.orange, Color.brown], startPoint: .top, endPoint: .bottom)
        case .cursor:
            return LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .top, endPoint: .bottom)
        case .visualStudioCode:
            return LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .top, endPoint: .bottom)
        case .manual:
            return LinearGradient(colors: [Color.gray, Color.secondary], startPoint: .top, endPoint: .bottom)
        }
    }

    private func statusColor(_ state: AgentIntegrationStateKind) -> Color {
        switch state {
        case .verified, .configured: .green
        case .available, .approvalPending: .blue
        case .stale, .broken, .conflict: .orange
        case .notDetected, .unavailable: .secondary
        }
    }
}
