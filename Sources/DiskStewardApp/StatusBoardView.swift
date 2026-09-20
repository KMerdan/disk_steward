import SwiftUI

struct StatusBoardView: View {
    @ObservedObject var viewModel: StatusBoardViewModel
    @ObservedObject var lifecycle: MonitoringLifecycleController
    let agentAccess: MCPAccessController?
    let onOpenSettings: () -> Void

    init(
        viewModel: StatusBoardViewModel,
        lifecycle: MonitoringLifecycleController? = nil,
        agentAccess: MCPAccessController? = nil,
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.lifecycle = lifecycle ?? viewModel.lifecycle
        self.agentAccess = agentAccess
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Disk Steward", systemImage: "externaldrive.fill")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!lifecycle.canRequestSample || lifecycle.isSampling)
                .accessibilityLabel("Refresh disk snapshot")
                .accessibilityHint("Reads current capacity without deleting or changing files.")
            }

            if viewModel.primaryVolume != nil {
                CapacitySection(viewModel: viewModel)
            } else if let error = viewModel.errorMessage {
                UnavailableCapacitySection(message: error)
            } else if lifecycle.isSampling {
                ProgressView("Reading volume capacity…")
                    .accessibilityLabel("Reading volume capacity")
            } else {
                Text("No capacity sample yet").font(.subheadline).foregroundStyle(.secondary)
            }

            Divider()

            GrowthSection(viewModel: viewModel)

            Text(viewModel.sampleStateSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let alert = lifecycle.latestGrowthAlert {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest growth alert · this session").font(.caption).foregroundStyle(.secondary)
                    Text("\(alert.amountText) · \(ObservedVolume.name(for: alert.mountPath))")
                        .font(.subheadline.weight(.semibold))
                    Text(alert.intervalText).font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            MonitoringSection(
                presentation: viewModel.presentation,
                freshness: viewModel.evidenceFreshnessSummary,
                storage: viewModel.evidenceStorageSummary,
                action: performMonitoringAction
            )

            if let agentAccess {
                Divider()
                AgentAccessRow(controller: agentAccess)
            }

            Button {
                Task { _ = await viewModel.exportCurrentEvidence() }
            } label: {
                Label(viewModel.isExporting ? "Preparing Evidence…" : "Export Evidence…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isExporting)
            .accessibilityLabel("Export current disk evidence")
            .accessibilityHint("Creates a metadata-only evidence bundle. It does not include file contents.")

            if let message = viewModel.exportMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel(message)
            }
        }
        .padding(18)
        .frame(width: 352)
        .background(.regularMaterial)
        .task { viewModel.prepareIfNeeded() }
    }

    private func performMonitoringAction(_ action: StatusBoardPrimaryAction) {
        switch action {
        case .pause: lifecycle.pause()
        case .resume: lifecycle.resume()
        case .refresh, .retry: viewModel.refresh()
        case .settings: onOpenSettings()
        }
    }
}

private struct CapacitySection: View {
    @ObservedObject var viewModel: StatusBoardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.volumeName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.capacityHealth.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(healthColor)
                    .accessibilityLabel("Capacity health: \(viewModel.capacityHealth.rawValue)")
            }
            Text(viewModel.availableSummary)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            ProgressView(value: viewModel.usedFraction)
                .tint(healthColor)
                .accessibilityLabel("Disk usage")
                .accessibilityValue(viewModel.capacitySummary)
            Text(viewModel.capacitySummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.capacityFreshnessSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(viewModel.volumeName), \(viewModel.availableSummary), \(viewModel.capacitySummary), \(viewModel.capacityHealth.rawValue)")
    }

    private var healthColor: Color {
        switch viewModel.capacityHealth {
        case .healthy: .green
        case .attention: .orange
        case .critical: .red
        case .unavailable: .secondary
        }
    }
}

private struct UnavailableCapacitySection: View {
    let message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text("Capacity unavailable").font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capacity unavailable. \(message)")
    }
}

private struct GrowthSection: View {
    @ObservedObject var viewModel: StatusBoardViewModel

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: growthSymbol)
                .font(.title3)
                .foregroundStyle(growthColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent change")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.growthSummary)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text(viewModel.growthDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recent disk change: \(viewModel.growthSummary). \(viewModel.growthDetail)")
    }

    private var delta: Int64? { viewModel.growthDelta }
    private var growthSymbol: String {
        guard let delta else { return "chart.line.uptrend.xyaxis" }
        if delta > 0 { return "arrow.up.right" }
        if delta < 0 { return "arrow.down.right" }
        return "equal"
    }
    private var growthColor: Color {
        guard let delta else { return .secondary }
        return delta > 0 ? .orange : .secondary
    }
}

private struct MonitoringSection: View {
    let presentation: StatusBoardPresentation
    let freshness: String
    let storage: String
    let action: (StatusBoardPrimaryAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: presentation.symbol)
                .foregroundStyle(statusColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title).font(.subheadline.weight(.semibold))
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(freshness) · \(storage)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(presentation.actionTitle) { action(presentation.action) }
                .buttonStyle(.borderless)
                .accessibilityHint(actionHint)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentation.title). \(presentation.detail). \(freshness). \(storage)")
    }

    private var statusColor: Color {
        switch presentation.state {
        case .active: .green
        case .paused, .noBaseline: .secondary
        case .degraded: .orange
        case .error: .red
        }
    }

    private var actionHint: String {
        switch presentation.action {
        case .pause: "Stops new monitoring samples. Stored evidence remains available."
        case .resume: "Restarts disk monitoring."
        case .refresh, .retry: "Reads current disk capacity again."
        case .settings: "Opens monitoring settings and diagnostics."
        }
    }
}

private struct AgentAccessRow: View {
    @ObservedObject var controller: MCPAccessController

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent Access")
                    .font(.subheadline.weight(.semibold))
                Text(controller.state.title)
                    .font(.caption.weight(.medium))
                Text(controller.state.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("Agent Access", isOn: Binding(
                get: { controller.isEnabled },
                set: { enabled in
                    controller.setEnabled(enabled)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(controller.state.kind == .starting)
            .accessibilityLabel("Agent Access")
            .accessibilityValue(controller.state.title)
            .accessibilityHint("Controls read-only AI access. Monitoring and stored evidence are unaffected.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(controller.state.accessibilitySummary)
    }

    private var symbol: String {
        switch controller.state.kind {
        case .off: "lock.fill"
        case .starting: "hourglass"
        case .on: "checkmark.shield.fill"
        case .degraded: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch controller.state.kind {
        case .off: .secondary
        case .starting: .blue
        case .on: .green
        case .degraded: .orange
        }
    }
}
