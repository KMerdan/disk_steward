import DiskStewardCore
import SwiftUI

/// TASK-623: the review window. Free space and the review estimate are shown
/// separately; every item is something to review, never something to delete.
struct ReviewWindowView: View {
    @ObservedObject var model: ReviewWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            summary
            Divider()
            content
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 520)
        .task { await model.loadLatest() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Scope", selection: $model.selectedScope) {
                ForEach(model.scopes) { scope in Text(scope.label).tag(scope) }
            }
            .frame(maxWidth: 320)
            .disabled(model.isReviewing)
            .accessibilityLabel("Review scope, \(model.selectedScope.label)")
            .onChange(of: model.selectedScope) { _ in Task { await model.loadLatest() } }
            Spacer()
            if let display = model.display, !model.isReviewing {
                Text("Reviewed \(display.completedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(model.primaryActionTitle) { model.primaryAction() }
                .keyboardShortcut(model.isReviewing ? "." : "r", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .accessibilityHint(model.isReviewing ? "Stops the review; what was covered is kept as a partial report." : "Measures the scope; nothing is deleted.")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.capacityLine, systemImage: model.capacity.availableBytes == nil ? "exclamationmark.triangle" : (model.belowReserve ? "exclamationmark.circle" : "internaldrive"))
                .font(.headline)
                .foregroundStyle(model.belowReserve || model.capacity.availableBytes == nil ? Color.orange : Color.primary)
            Text(model.stateLine)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let display = model.display, model.reviewState == .partial {
                if !display.uncovered.isEmpty {
                    Text("Not reviewed: " + display.uncovered.prefix(6).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                         + (display.uncovered.count > 6 ? " and \(display.uncovered.count - 6) more" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                } else if !display.limitations.isEmpty {
                    Text(display.limitations.prefix(2).joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let message = model.lastMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilitySummary)
    }

    @ViewBuilder
    private var content: some View {
        if model.groups.isEmpty {
            Spacer(minLength: 0)
        } else {
            HStack(alignment: .top, spacing: 12) {
                List(selection: $model.selectedItemID) {
                    ForEach(model.groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.items) { item in
                                ItemRow(item: item).tag(item.id)
                            }
                        }
                    }
                }
                .frame(minWidth: 360)
                .accessibilityLabel("Items to review, grouped by project")
                Group {
                    if let item = model.selectedItem {
                        ItemDetail(item: item, model: model)
                    } else {
                        Text("Select an item to see why it is listed.").foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct ItemRow: View {
    let item: ReviewWindowModel.Item

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium))
                Text(item.origin).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ReviewWindowModel.bytes(item.allocatedBytes)).font(.body.monospacedDigit())
                Text(item.evidence.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ReviewWindowModel.accessibilityLabel(for: item))
    }
}

private struct ItemDetail: View {
    let item: ReviewWindowModel.Item
    @ObservedObject var model: ReviewWindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title3.weight(.semibold))
                    Text(item.path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Text("Reclaim estimate: \(ReviewWindowModel.bytes(item.allocatedBytes)) · \(item.evidence.rawValue), checked \(item.verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout)
                        .padding(.top, 2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )

                section("Origin", [item.origin])
                section("Why it may be disposable", item.whyDisposable)
                section("Reasons to keep it", item.reasonsToKeep)
                section("Recreate", [item.rebuildCommand], monospaced: item.rebuildCommandKnown)
                if let cleanup = item.cleanupCommand { section("The tool's own cleanup command (not run)", [cleanup], monospaced: true) }

                HStack(spacing: 8) {
                    Button("Reveal in Finder") { model.revealInFinder(item) }
                        .buttonStyle(.bordered)
                    Button("Copy Review Brief") { model.copyReviewBrief(item) }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, _ lines: [String], monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(monospaced ? .callout.monospaced() : .callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
