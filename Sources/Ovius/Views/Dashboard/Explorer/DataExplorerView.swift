import SwiftUI

/// Bottom Data Explorer section combining an integrated header/search bar, inline filter strip,
/// and native inset macOS tables (`Recordings -> Cycles -> State Timings`).
public struct DataExplorerView: View {
    public let viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        @Bindable var explorer = viewModel.explorer

        VStack(alignment: .leading, spacing: OviusDesign.Spacing.standard) {
            DataExplorerToolbarView(
                explorer: explorer,
                sections: viewModel.sidebar.sectionsInActiveCluster,
                cameras: viewModel.sidebar.camerasInScope,
                onPopToRecordings: viewModel.popToRecordings,
                onPopToCycles: viewModel.popToCycles
            )

            if viewModel.isInitialLoading && explorer.recordingRows.isEmpty {
                SectionLoadingPlaceholderView(
                    title: "Updating Data Explorer…",
                    subtitle: "Loading initial cluster telemetry across recordings, haul cycles, and machine states.",
                    minHeight: 120
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Group {
                    switch explorer.explorerLevel {
                    case .recordings:
                        RecordingExplorerTableView(
                            rows: explorer.displayedRecordingRows,
                            sortOrder: $explorer.recordingSortOrder,
                            onOpenRecording: viewModel.openRecording
                        )
                        .onChange(of: explorer.recordingSortOrder) { _, newOrder in
                            explorer.syncToolbarSortFromTable(newOrder)
                        }

                    case .cycles(let recording):
                        CycleExplorerTableView(
                            recording: recording,
                            rows: explorer.displayedCycleRows,
                            isLoadingDrilldown: viewModel.isExplorerDrilldownLoading,
                            onOpenCycle: viewModel.openCycle
                        )

                    case .stateTimings(_, let cycle):
                        StateTimingExplorerTableView(
                            cycle: cycle,
                            segmentRows: explorer.displayedStateTimingRows,
                            scoopRows: explorer.scoopTimingRows,
                            isLoadingDrilldown: viewModel.isExplorerDrilldownLoading
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
