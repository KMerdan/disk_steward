import SwiftUI

struct StatusBoardView: View {
    @ObservedObject var viewModel: StatusBoardViewModel
    @ObservedObject var lifecycle: MonitoringLifecycleController

    init(viewModel: StatusBoardViewModel, lifecycle: MonitoringLifecycleController? = nil) {
        self.viewModel = viewModel
        self.lifecycle = lifecycle ?? viewModel.lifecycle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                .accessibilityLabel("Refresh disk snapshot")
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Monitoring \(lifecycle.status.title)")
                        .font(.subheadline.bold())
                    Text(lifecycle.status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.growthSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(lifecycle.status.kind == .paused ? "Resume" : "Pause") {
                    lifecycle.status.kind == .paused ? lifecycle.resume() : lifecycle.pause()
                }
                .buttonStyle(.borderless)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(lifecycle.status.accessibilitySummary)

            if let volume = viewModel.primaryVolume {
                VStack(alignment: .leading, spacing: 7) {
                    Text(volume.mountPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressView(value: viewModel.usedFraction)
                        .accessibilityLabel("Disk usage")
                        .accessibilityValue(viewModel.capacitySummary)
                    Text(viewModel.capacitySummary)
                        .font(.system(.body, design: .rounded, weight: .medium))
                    Text("Available: \(ByteCountFormatter.string(fromByteCount: volume.availableBytes, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Current volume snapshot")
            } else if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Snapshot error: \(error)")
            } else {
                ProgressView("Reading volume capacity…")
                    .accessibilityLabel("Reading volume capacity")
            }

            Divider()

            Button("Export Evidence…") {
                viewModel.exportCurrentSnapshot()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Export current disk evidence")

            if let message = viewModel.exportMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityLabel(message)
            }
        }
        .padding(16)
        .frame(width: 330)
        .task { viewModel.refresh() }
    }

    private var statusSymbol: String {
        switch lifecycle.status.kind {
        case .active: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .recovered: "arrow.clockwise.circle.fill"
        case .paused: "pause.circle.fill"
        }
    }

    private var statusColor: Color {
        switch lifecycle.status.kind {
        case .active, .recovered: .green
        case .degraded: .orange
        case .paused: .secondary
        }
    }
}
