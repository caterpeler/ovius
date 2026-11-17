import SwiftUI

/// Primary application navigation sidebar with surface and semantic ink tokens.
public struct SidebarNavigationColumnView: View {
    @Binding public var selectedTab: AppSidebarTab?

    public init(selectedTab: Binding<AppSidebarTab?>) {
        self._selectedTab = selectedTab
    }

    public var body: some View {
        List(AppSidebarTab.allCases, selection: $selectedTab) { tab in
            Label(tab.title, systemImage: tab.systemImage)
                .font(.callout)
                .tag(tab)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Tokens.surface)
        .navigationSplitViewColumnWidth(
            min: OviusDesign.Column.sidebarMin,
            ideal: OviusDesign.Column.sidebarIdeal,
            max: OviusDesign.Column.sidebarMax
        )
    }
}
