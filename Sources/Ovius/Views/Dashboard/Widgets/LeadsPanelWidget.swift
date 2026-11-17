import SwiftUI

/// Widget 4: Displays up to 5 detected `OperationalLead` entries for the active slice.
/// Clicking any lead highlights its associated Diagnostic Cards below without altering raw data filters.
public struct LeadsPanelWidget: View {
    @Bindable public var viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        viewModel.topLeads.isEmpty
                            ? "Leads (0 Detected)"
                            : "Detected Leads (Top \(viewModel.topLeads.count)/5)",
                        systemImage: viewModel.topLeads.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.topLeads.isEmpty ? Color.green : Color.orange)

                    Spacer()

                    if viewModel.filterState.highlightedLeadEntryId != nil {
                        Button("Clear Highlight") {
                            viewModel.filterState.highlightedLeadEntryId = nil
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                if viewModel.isFilteringData {
                    VStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Evaluating leads…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.topLeads.isEmpty {
                    Text("No active operational leads triggered for this scope. All tracked KPIs sit within cluster tolerances.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 4) {
                            ForEach(viewModel.topLeads) { item in
                                let isHighlighted = viewModel.filterState.highlightedLeadEntryId == item.id
                                Button {
                                    viewModel.toggleHighlightedLead(item.id)
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(isHighlighted ? Color.accentColor : Color.orange)
                                            .frame(width: 6, height: 6)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.evaluatedLead.lead.name)
                                                .font(.caption.weight(isHighlighted ? .bold : .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text("\(item.sectionName) • \(item.evaluatedLead.lead.category)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        Spacer()

                                        Text(String(format: "%.0f%%", item.evaluatedLead.confidenceScore * 100))
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(isHighlighted ? Color.accentColor : Color.orange)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.orange.opacity(0.08))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(isHighlighted ? Color.accentColor : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }

                if !viewModel.isFilteringData && viewModel.hasPendingLeadsUpdate {
                    Divider()
                    Button {
                        viewModel.applyPendingLeadsAndDiagnostics()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                            Text("Changes in records changed identified leads. Reload leads & widgets.")
                                .font(.caption2.weight(.medium))
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
