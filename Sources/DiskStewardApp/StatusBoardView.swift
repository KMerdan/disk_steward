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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack(alignment: .center) {
                    Label("Disk Steward", systemImage: "externaldrive.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Button {
                        viewModel.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(!lifecycle.canRequestSample || lifecycle.isSampling)
                    .accessibilityLabel("Refresh disk snapshot")
                    .accessibilityHint("Reads current capacity without deleting or changing files.")
                }
                .padding(.horizontal, 2)

                // Capacity Section
                if viewModel.primaryVolume != nil {
                    CapacitySection(viewModel: viewModel)
                } else if let error = viewModel.errorMessage {
                    UnavailableCapacitySection(message: error)
                } else if lifecycle.isSampling {
                    StatusCard {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading volume capacity…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                    }
                    .accessibilityLabel("Reading volume capacity")
                } else {
                    StatusCard {
                        Text("No capacity sample yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                // Growth Section
                GrowthSection(viewModel: viewModel)

                // Sample state summary
                Text(viewModel.sampleStateSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)

                // Growth alert banner (if present)
                if let alert = lifecycle.latestGrowthAlert {
                    StatusCard {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Latest growth alert · this session")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text("\(alert.amountText) · \(ObservedVolume.name(for: alert.mountPath))")
                                    .font(.caption.weight(.semibold))
                                Text(alert.intervalText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                // Monitoring Section
                MonitoringSection(
                    presentation: viewModel.presentation,
                    freshness: viewModel.evidenceFreshnessSummary,
                    storage: viewModel.evidenceStorageSummary,
                    action: performMonitoringAction
                )

                // Agent Access Row
                if let agentAccess {
                    AgentAccessRow(controller: agentAccess)
                }

                // Actions: Review Storage & Export Evidence side by side
                HStack(spacing: 8) {
                    if let openReview = viewModel.openReview {
                        Button {
                            openReview()
                        } label: {
                            Label("Review Storage…", systemImage: "list.bullet.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .accessibilityHint("Opens a review of build output, environments and caches. Nothing is deleted.")
                    }

                    Button {
                        Task { _ = await viewModel.exportCurrentEvidence() }
                    } label: {
                        Label(viewModel.isExporting ? "Exporting…" : "Export Evidence…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(viewModel.isExporting)
                    .accessibilityLabel("Export current disk evidence")
                    .accessibilityHint("Creates a metadata-only evidence bundle. It does not include file contents.")
                }

                if let message = viewModel.exportMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 2)
                        .accessibilityLabel(message)
                }
            }
            .padding(12)
        }
        .frame(width: 352)
        .frame(maxHeight: 520)
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

private struct StatusCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct CapacitySection: View {
    @ObservedObject var viewModel: StatusBoardViewModel

    var body: some View {
        StatusCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text(viewModel.volumeName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(viewModel.capacityHealth.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(healthColor.opacity(0.14))
                        )
                        .foregroundStyle(healthColor)
                        .accessibilityLabel("Capacity health: \(viewModel.capacityHealth.rawValue)")
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(viewModel.availableSummary)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer()
                    Text(viewModel.capacitySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: viewModel.usedFraction)
                    .tint(healthColor)
                    .accessibilityLabel("Disk usage")
                    .accessibilityValue(viewModel.capacitySummary)

                HStack {
                    if let reserve = viewModel.reserveSummary {
                        Text(reserve)
                            .font(.caption2)
                            .foregroundStyle(viewModel.belowReserve ? Color.orange : Color.secondary)
                    }
                    Spacer()
                    Text(viewModel.capacityFreshnessSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(viewModel.volumeName), \(viewModel.availableSummary), \(viewModel.reserveSummary.map { "\($0), " } ?? "")\(viewModel.capacitySummary), \(viewModel.capacityHealth.rawValue)")
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
        StatusCard {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Capacity unavailable").font(.headline)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Capacity unavailable. \(message)")
    }
}

private struct GrowthSection: View {
    @ObservedObject var viewModel: StatusBoardViewModel

    var body: some View {
        StatusCard {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(growthColor.opacity(0.12))
                        .frame(width: 24, height: 24)
                    Image(systemName: growthSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(growthColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Recent change")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.growthSummary)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                    Text(viewModel.growthDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
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
        StatusCard {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 24, height: 24)
                    Image(systemName: presentation.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.subheadline.weight(.semibold))
                    Text(presentation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(storage) · \(freshness)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(presentation.actionTitle) { action(presentation.action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(actionHint)
            }
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
        StatusCard {
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 24, height: 24)
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("Agent Access")
                            .font(.subheadline.weight(.semibold))

                        Text(controller.state.title)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(color.opacity(0.12))
                            )
                            .foregroundStyle(color)
                    }

                    Text(controller.state.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Toggle("Agent Access", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { enabled in
                        controller.setEnabled(enabled)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(controller.state.kind == .starting)
                .accessibilityLabel("Agent Access")
                .accessibilityValue(controller.state.title)
                .accessibilityHint("Controls read-only AI access. Monitoring and stored evidence are unaffected.")
            }
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
