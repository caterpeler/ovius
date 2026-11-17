import SwiftUI

/// Root native 3-column `NavigationSplitView` coordinating App Sidebar, Content Selector Column,
/// and Main Detail Workspace.
public struct ContentView: View {
    @State private var selectedTab: AppSidebarTab? = .dashboard
    @State private var selectedSettingsCategory: SettingsCategory? = .endpoint
    @State private var dashboardViewModel = DashboardViewModel()
    @State private var clustersViewModel = ClustersViewModel()
    @State private var settingsViewModel = SettingsViewModel()

    public init() {}

    private var activeTab: AppSidebarTab {
        selectedTab ?? .dashboard
    }

    private var activeSettingsCategory: SettingsCategory {
        selectedSettingsCategory ?? .endpoint
    }

    public var body: some View {
        NavigationSplitView {
            SidebarNavigationColumnView(selectedTab: $selectedTab)
        } content: {
            switch activeTab {
            case .dashboard:
                RecordingSelectorSidebarView(viewModel: dashboardViewModel)
            case .clusters:
                ClusterSectionListView(viewModel: clustersViewModel)
            case .settings:
                SettingsCategoryListView(selectedCategory: $selectedSettingsCategory)
            }
        } detail: {
            switch activeTab {
            case .dashboard:
                DashboardView(viewModel: dashboardViewModel)
            case .clusters:
                ClustersView(viewModel: clustersViewModel)
            case .settings:
                SettingsView(
                    viewModel: settingsViewModel,
                    category: activeSettingsCategory,
                    onClearTelemetryCaches: dashboardViewModel.clearTelemetryCaches
                )
            }
        }
        .tint(Tokens.primary.color)
        .appAccent(Tokens.primary)
    }
}
