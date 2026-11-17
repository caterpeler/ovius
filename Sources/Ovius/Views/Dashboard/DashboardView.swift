import SwiftUI

/// Right-hand Dashboard detail workspace with bordered metric panels and dynamic-height Data Explorer.
public struct DashboardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.section) {
            if let errorMessage = viewModel.errorMessage {
                DashboardStatusBannerView(
                    title: "Telemetry Sync Error",
                    message: errorMessage,
                    accent: Tokens.danger,
                    systemImage: "xmark.octagon.fill"
                )
            }

            if viewModel.isDataTruncated {
                DashboardStatusBannerView(
                    title: "Telemetry Page Cap Reached",
                    message: "The query reached its multi-page cap. Select fewer recordings for exhaustive segment coverage.",
                    accent: Tokens.warning,
                    systemImage: "exclamationmark.triangle.fill"
                )
            }

            if viewModel.isFilteringData {
                TelemetryStreamingBannerView(progress: viewModel.telemetryFetchProgress)
            }

            if viewModel.filteredRecordings.isEmpty && !viewModel.isInitialLoading {
                ContentUnavailableView(
                    "No Recording Selected",
                    systemImage: "sidebar.left",
                    description: Text("Select one or more recordings (or use Select All) in the recordings column, then click refresh to load metrics.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DashboardMetricCardsView(
                    summary: viewModel.metricsSummary,
                    isLoading: viewModel.isInitialLoading && viewModel.explorer.recordingRows.isEmpty
                )

                DividerLine()

                DataExplorerView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(OviusDesign.Spacing.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.sidebar.hasPendingSelectionChanges && !viewModel.isInitialLoading {
                PendingSelectionRefreshBarView(
                    selectedCount: viewModel.sidebar.filterState.selectedRecordingIds.count,
                    onRefresh: viewModel.refreshPendingSelection
                )
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .default : Tokens.Animation.normal, value: viewModel.sidebar.hasPendingSelectionChanges)
        .navigationTitle(viewModel.sidebar.activeCluster?.name ?? "Dashboard")
        .navigationSubtitle("\(viewModel.sidebar.appliedRecordingIds.count) clip\(viewModel.sidebar.appliedRecordingIds.count == 1 ? "" : "s") active")
        .navigationSplitViewColumnWidth(min: OviusDesign.Column.detailMin, ideal: 760)
        .task {
            if viewModel.sidebar.clusterRecordings.isEmpty && !viewModel.isInitialLoading {
                await viewModel.loadInitialAndRefresh()
            }
        }
    }
}
