import SwiftUI

/// Sticky sidebar header cleanly separating Recordings & Clusters controls from Date Range controls.
public struct RecordingSidebarHeaderView: View {
    public let sidebar: DashboardSidebarViewModel
    public let onSelectCluster: (String) -> Void

    public init(
        sidebar: DashboardSidebarViewModel,
        onSelectCluster: @escaping (String) -> Void
    ) {
        self.sidebar = sidebar
        self.onSelectCluster = onSelectCluster
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.standard) {
            SidebarRecordingsFilterGroupView(
                sidebar: sidebar,
                onSelectCluster: onSelectCluster
            )

            DividerLine()
                .opacity(0.6)

            SidebarDateRangeGroupView(sidebar: sidebar)
        }
        .padding(.horizontal, OviusDesign.Spacing.standard)
        .padding(.vertical, OviusDesign.Spacing.standard)
        .background(Tokens.surface)
    }
}
