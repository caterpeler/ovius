import SwiftUI

/// Sticky top control deck housing the 4 mandatory cross-filtering & lead widgets above scrollable content.
public struct DashboardFilterDeckView: View {
    @Bindable public var viewModel: DashboardViewModel

    private let columns = [
        GridItem(.flexible(minimum: 220), spacing: 12),
        GridItem(.flexible(minimum: 220), spacing: 12),
        GridItem(.flexible(minimum: 210), spacing: 12),
        GridItem(.flexible(minimum: 230), spacing: 12),
    ]

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(viewModel.activeCluster?.name ?? "Ovius Dashboard")
                    .font(.headline)

                Text("\(viewModel.filteredRecordings.count) recordings • \(viewModel.activeSnapshot?.completeCycleCount ?? 0) complete cycles")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                if let refreshed = viewModel.lastRefreshedAt {
                    Text("Anchor \(OviusFormat.utcDateTime(viewModel.referenceDate)) • Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if viewModel.filterState.hasNarrowedFilters {
                    Button("Reset Filters") {
                        viewModel.resetAllFilters()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                Button {
                    Task { await viewModel.refreshAll() }
                } label: {
                    if viewModel.isInitialLoading || viewModel.isFilteringData {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isInitialLoading)
            }

            LazyVGrid(columns: columns, spacing: 12) {
                RecordingsClusterSelectorWidget(viewModel: viewModel)
                    .frame(minHeight: 196)
                DateRangeCalendarWidget(viewModel: viewModel)
                    .frame(minHeight: 196)
                TimeRangeSelectorWidget(viewModel: viewModel)
                    .frame(minHeight: 196)
                LeadsPanelWidget(viewModel: viewModel)
                    .frame(minHeight: 196)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
