import SwiftUI

/// Root window: the icon rail (Dashboard, Clusters & Sections, Uploads, Settings), then each page's list column and its
/// main area.
public struct ContentView: View {
    @State private var selectedTab: AppSidebarTab?
    @State private var selectedSettingsCategory: SettingsCategory? = .endpoint
    @State private var dashboardViewModel: DashboardViewModel
    @State private var clustersViewModel: ClustersViewModel
    @State private var settingsViewModel: SettingsViewModel
    /// The Uploads page: videos added this session, sent to the backend.
    @State private var uploadsState: UploadsState

    public init() {
        self.init(tab: .dashboard, dashboardViewModel: DashboardViewModel(), clustersViewModel: ClustersViewModel(),
                  settingsViewModel: SettingsViewModel())
    }

    /// A window on given view models (the shell preview's in-memory ones).
    init(tab: AppSidebarTab, settingsCategory: SettingsCategory = .endpoint, dashboardViewModel: DashboardViewModel,
         clustersViewModel: ClustersViewModel, settingsViewModel: SettingsViewModel, uploadsState: UploadsState? = nil) {
        _uploadsState = State(initialValue: uploadsState ?? UploadsState())
        _selectedTab = State(initialValue: tab)
        _selectedSettingsCategory = State(initialValue: settingsCategory)
        _dashboardViewModel = State(initialValue: dashboardViewModel)
        _clustersViewModel = State(initialValue: clustersViewModel)
        _settingsViewModel = State(initialValue: settingsViewModel)
    }

    private var activeTab: AppSidebarTab {
        selectedTab ?? .dashboard
    }

    private var activeSettingsCategory: SettingsCategory {
        selectedSettingsCategory ?? .endpoint
    }

    public var body: some View {
        HStack(spacing: 0) {
            FleetRail(selection: Binding(get: { activeTab }, set: { selectedTab = $0 }))
            Rectangle().fill(Ov.hairline).frame(width: 1)
            Group {
                switch activeTab {
                case .dashboard:
                    FleetRecordingsColumn(viewModel: dashboardViewModel)
                case .clusters:
                    ClusterSectionListView(viewModel: clustersViewModel)
                case .uploads:
                    UploadsColumn(state: uploadsState)
                case .settings:
                    SettingsCategoryListView(selectedCategory: $selectedSettingsCategory)
                }
            }
            .frame(width: 320)
            .frame(maxHeight: .infinity)
            Rectangle().fill(Ov.hairline).frame(width: 1)
            Group {
                switch activeTab {
                case .dashboard:
                    DashboardView(viewModel: dashboardViewModel)
                case .clusters:
                    ClustersView(viewModel: clustersViewModel)
                case .uploads:
                    UploadDetailView(state: uploadsState, clustersViewModel: clustersViewModel)
                case .settings:
                    SettingsView(
                        viewModel: settingsViewModel,
                        category: activeSettingsCategory,
                        onClearTelemetryCaches: dashboardViewModel.clearTelemetryCaches
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Ov.canvas)
        .foregroundStyle(Ov.ink)
        .fleetCycleModal(dashboardViewModel.fleet)
        .tint(Tokens.primary.color)
        .appAccent(Tokens.primary)
        .onAppear {
            // The dashboard's targets link opens the viewed cluster's page.
            dashboardViewModel.fleet.openClusterTargets = { [dashboardViewModel, clustersViewModel, $selectedTab] in
                guard let id = dashboardViewModel.sidebar.activeCluster?.clusterId else { return }
                clustersViewModel.reload()
                clustersViewModel.openCluster(id)
                $selectedTab.wrappedValue = .clusters
            }
        }
    }
}
