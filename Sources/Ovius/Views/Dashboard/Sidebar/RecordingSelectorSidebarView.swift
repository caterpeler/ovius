import SwiftUI

/// Native middle `NavigationSplitView` column dedicated to Cluster selection, recording filters,
/// UTC date range filtering, and Mail-style multi-recording selection.
public struct RecordingSelectorSidebarView: View {
    public let viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        @Bindable var sidebar = viewModel.sidebar

        VStack(spacing: 0) {
            RecordingSidebarHeaderView(
                sidebar: sidebar,
                onSelectCluster: viewModel.selectCluster
            )

            DividerLine()

            Group {
                if viewModel.isInitialLoading && sidebar.clusterRecordings.isEmpty {
                    ProgressView("Loading Recordings…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Tokens.bg)
                } else if sidebar.displayedSidebarRecordings.isEmpty {
                    ContentUnavailableView(
                        "No Matching Recordings",
                        systemImage: "film.stack",
                        description: Text("Adjust or clear your Section, Camera, Date Range, or search filters above.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Tokens.bg)
                } else {
                    List(sidebar.displayedSidebarRecordings, selection: $sidebar.filterState.selectedRecordingIds) { rec in
                        RecordingSidebarRowView(recording: rec)
                            .tag(rec.recordingId)
                            .listRowSeparatorTint(Tokens.border)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(Tokens.bg)
                }
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DividerLine()

            RecordingSidebarFooterView(
                displayedCount: sidebar.displayedSidebarRecordings.count,
                totalCount: sidebar.sidebarRecordings.count,
                selectedCount: sidebar.filterState.selectedRecordingIds.count,
                hasMore: sidebar.hasMoreSidebarRecordings,
                remainingCount: sidebar.remainingSidebarRecordingCount,
                pageSize: DashboardSidebarViewModel.pageSize,
                isFiltering: viewModel.isFilteringData,
                progressText: viewModel.telemetryFetchProgress,
                onLoadMore: sidebar.loadMoreSidebarRecordings
            )
        }
        .background(Tokens.bg)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(sidebar.clusters, id: \.clusterId) { cluster in
                        Button {
                            viewModel.selectCluster(cluster.clusterId)
                        } label: {
                            if cluster.clusterId == sidebar.activeCluster?.clusterId {
                                Label(cluster.name, systemImage: "checkmark")
                            } else {
                                Text(cluster.name)
                            }
                        }
                    }
                } label: {
                    Label(sidebar.activeCluster?.name ?? "Cluster", systemImage: "square.stack.3d.up")
                }
                .help("Switch Active Cluster")

                Button("Refresh Recordings", systemImage: "arrow.clockwise", action: triggerRefresh)
                    .disabled(viewModel.isInitialLoading)
                    .help("Reload recordings & clear cached telemetry")
            }
        }
        .navigationSplitViewColumnWidth(
            min: OviusDesign.Column.contentMin,
            ideal: OviusDesign.Column.contentIdeal,
            max: OviusDesign.Column.contentMax
        )
        .onChange(of: sidebar.sidebarSearchText) { _, _ in
            sidebar.rebuildSidebarForSearchChange()
        }
        .onAppear {
            viewModel.loadCatalog()
        }
    }

    private func triggerRefresh() {
        Task { await viewModel.refreshAll() }
    }
}
