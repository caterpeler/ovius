import SwiftUI

/// Root `NavigationSplitView` coordinating Dashboard, Clusters & Sections, Diagnostic Rules, and Settings.
public struct ContentView: View {
    @State private var selectedTab: AppSidebarTab = .dashboard
    @State private var dashboardViewModel = DashboardViewModel()
    @State private var clustersViewModel = ClustersViewModel()
    @State private var diagnosticsCatalogViewModel = DiagnosticsCatalogViewModel()
    @State private var settingsViewModel = SettingsViewModel()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(AppSidebarTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 270)
        } detail: {
            switch selectedTab {
            case .dashboard:
                DashboardView(viewModel: dashboardViewModel)
            case .clusters:
                ClustersView(viewModel: clustersViewModel)
            case .diagnosticsCatalog:
                DiagnosticsCatalogView(viewModel: diagnosticsCatalogViewModel)
            case .settings:
                SettingsView(viewModel: settingsViewModel)
            }
        }
    }
}
