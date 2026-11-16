import OviusCore
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case dashboard
    case clusters
    case simulation
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var item: SidebarItem? = .dashboard
    /// How far the Clusters page has gone: a cluster, then one of its runs.
    @State private var path: [ClusterRoute] = []
    @State private var resultFolders: [URL] = []
    @State private var importingResults = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $item) {
                Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                    .tag(SidebarItem.dashboard)
                Label("Clusters", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.clusters)
                Label("Simulation", systemImage: "slider.horizontal.3")
                    .tag(SidebarItem.simulation)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            // On the sidebar: one view keeps one file importer working.
            .fileImporter(isPresented: $model.showImportResults, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result, !urls.isEmpty {
                    resultFolders = urls
                    importingResults = true
                }
            }
            .sheet(isPresented: $importingResults) {
                ImportResultsSheet(folders: resultFolders, clusterID: selectedCluster) { open($0) }
            }
        } detail: {
            switch item ?? .dashboard {
            case .dashboard:
                OverviewView { open($0) }
            case .clusters:
                NavigationStack(path: $path) {
                    ClustersHome { path = [.cluster($0)] }
                        .navigationDestination(for: ClusterRoute.self) { route in
                            switch route {
                            case .cluster(let id):
                                if let cluster = model.cluster(id) {
                                    ClusterPage(cluster: cluster, open: { path.append(.run($0)) }, close: { path.removeAll() })
                                } else {
                                    ContentUnavailableView("Cluster Deleted", systemImage: "trash")
                                }
                            case .run(let id):
                                if let batch = model.batch(id) {
                                    BatchDetail(batch: batch, back: PageBack(to: model.clusterTitle(batch.clusterID)) {
                                        if !path.isEmpty { path.removeLast() }
                                    })
                                } else {
                                    ContentUnavailableView("Run Deleted", systemImage: "trash")
                                }
                            }
                        }
                }
            case .simulation:
                ContentUnavailableView("Simulation", systemImage: "slider.horizontal.3", description: Text("Not built yet."))
                    .navigationTitle("Simulation")
            }
        }
        // The pages' own headings take the title bar's place.
        .toolbar(.hidden, for: .windowToolbar)
        .sheet(isPresented: $model.showNewAnalysis) {
            NewAnalysisSheet(clusterID: selectedCluster) { open($0) }
        }
        .confirmationDialog(
            "Delete this run of \(model.deleting.map { model.clusterTitle($0.clusterID) } ?? "")?",
            isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } }),
            presenting: model.deleting
        ) { batch in
            Button("Delete", role: .destructive) {
                path.removeAll { $0 == .run(batch.id) }
                model.delete(batch)
            }
        } message: { batch in
            let n = model.analyses(of: batch).count
            Text("Its \(n == 1 ? "camera's copy of the video" : "\(n) cameras' copies of their videos") and its figures are removed from the library. This cannot be undone.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.alert ?? "")
        }
    }

    /// The cluster the Clusters page has open.
    private var selectedCluster: Int64? {
        guard item == .clusters else { return nil }
        return path.compactMap { route -> Int64? in
            switch route {
            case .cluster(let id): id
            case .run(let id): model.batch(id)?.clusterID
            }
        }.last
    }

    /// A run's page, on the Clusters page after its cluster's.
    private func open(_ batchID: Int64) {
        guard let batch = model.batch(batchID) else { return }
        item = .clusters
        path = [.cluster(batch.clusterID), .run(batchID)]
    }
}
