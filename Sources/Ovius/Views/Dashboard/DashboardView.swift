import SwiftUI

/// Root Dashboard workspace organizing:
/// 1) Sticky top 4-widget PowerBI filter & leads deck (`DashboardFilterDeckView`)
/// 2) Dedicated Diagnostic Card views (`DashboardDiagnosticsSectionView`)
/// 3) Horizontal Rule (`Divider()`)
/// 4) Bottom 3-layer Data Explorer (`DataExplorerView`)
public struct DashboardView: View {
    @Bindable public var viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sticky Top 4-Widget Deck (Always Present)
            DashboardFilterDeckView(viewModel: viewModel)

            // Scrollable Dashboard Cards + Horizontal Rule + Data Explorer
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorMessage = viewModel.errorMessage {
                        statusBanner(
                            title: "Telemetry Sync Error",
                            message: errorMessage,
                            color: .red,
                            systemImage: "xmark.octagon.fill"
                        )
                    }

                    if viewModel.isDataTruncated {
                        statusBanner(
                            title: "Multi-Page Telemetry Cap Reached",
                            message: "The current query reached its multi-page cap. Narrow the Date Range or Cluster scope for exhaustive raw cycle coverage.",
                            color: .orange,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                    }

                    DashboardDiagnosticsSectionView(viewModel: viewModel)

                    Divider()
                        .padding(.vertical, 4)

                    DataExplorerView(viewModel: viewModel)
                }
                .padding(20)
            }
        }
        .navigationTitle("Operational Dashboard")
        .task {
            if viewModel.clusterRecordings.isEmpty && !viewModel.isInitialLoading {
                await viewModel.loadInitialAndRefresh()
            }
        }
    }

    private func statusBanner(
        title: String,
        message: String,
        color: Color,
        systemImage: String
    ) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}
