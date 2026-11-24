import SwiftUI

/// Right-hand Dashboard detail workspace: sync and loading banners, then the analysis of the applied recordings
/// (diagnosis, figure cards, shift timeline, each machine, and the Data Explorer), with a cycle opened at the side.
public struct DashboardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public let viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            content
        }
        .background(Ov.canvas)
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

    private var content: some View {
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
                .frame(maxWidth: .infinity, minHeight: 420)
            } else if viewModel.fleet.recordings.isEmpty {
                OvLoadingState("Loading telemetry", message: "Cycles and machine states for the selected recordings are on their way.")
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                FleetAnalysisPage(state: viewModel.fleet)
            }
        }
        .padding(OviusDesign.Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .foregroundStyle(Ov.ink)
    }
}
