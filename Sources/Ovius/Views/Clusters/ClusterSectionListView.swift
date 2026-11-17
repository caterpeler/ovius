import SwiftUI

/// Native middle `NavigationSplitView` column listing Clusters and Sections.
public struct ClusterSectionListView: View {
    @Bindable public var viewModel: ClustersViewModel
    @State private var clusterDraft: ClusterEditorDraft?
    @State private var sectionDraft: SectionEditorDraft?

    public init(viewModel: ClustersViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List(selection: $viewModel.selectedSectionId) {
            ForEach(viewModel.clusters, id: \.clusterId) { cluster in
                SwiftUI.Section {
                    ForEach(cluster.sections.sorted { $0.sectionId < $1.sectionId }, id: \.sectionId) { section in
                        VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight / 2) {
                            Text(section.name)
                                .font(.callout)
                                .foregroundStyle(Tokens.text)
                            Text("\(section.cameraIds.count) cameras • \(section.sectionId)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Tokens.text2)
                        }
                        .padding(.vertical, OviusDesign.Spacing.tight / 2)
                        .tag(Optional(section.sectionId))
                        .listRowSeparatorTint(Tokens.border)
                    }
                } header: {
                    HStack {
                        Text(cluster.name)
                            .foregroundStyle(Tokens.text2)
                        Spacer()
                        Button("Edit") {
                            clusterDraft = .edit(cluster)
                        }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(Tokens.primary.text)
                        .accessibilityLabel("Edit cluster \(cluster.name)")
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Tokens.bg)
        .navigationSplitViewColumnWidth(
            min: OviusDesign.Column.contentMin,
            ideal: OviusDesign.Column.contentIdeal,
            max: OviusDesign.Column.contentMax
        )
        .toolbar {
            ToolbarItemGroup {
                Button("Add Cluster", systemImage: "folder.badge.plus", action: presentNewCluster)
                    .help("Create a new Cluster")

                Button("Add Section", systemImage: "plus.rectangle.on.folder", action: presentNewSection)
                    .disabled(viewModel.selectedCluster == nil)
                    .help("Create a new Section in the selected Cluster")
            }
        }
        .onChange(of: viewModel.selectedSectionId) { _, newId in
            syncSelectionContext(sectionId: newId)
        }
        .task {
            viewModel.reload()
        }
        .sheet(item: $clusterDraft) { draft in
            ClusterEditorSheet(existingCluster: draft.existingCluster) { id, name, tags in
                viewModel.createOrUpdateCluster(clusterId: id, name: name, tagsText: tags)
            }
        }
        .sheet(item: $sectionDraft) { draft in
            SectionEditorSheet(clusterId: draft.clusterId, existingSection: draft.existingSection) { sId, cId, name, cams, locs, tags, files, trucks in
                viewModel.createOrUpdateSection(
                    sectionId: sId,
                    clusterId: cId,
                    name: name,
                    cameraIdsText: cams,
                    locationTagsText: locs,
                    customTagsText: tags,
                    filenamesText: files,
                    assignedTrucksText: trucks
                )
            }
        }
    }

    private func presentNewCluster() {
        clusterDraft = .create
    }

    private func presentNewSection() {
        guard let cluster = viewModel.selectedCluster else { return }
        sectionDraft = .create(clusterId: cluster.clusterId)
    }

    private func syncSelectionContext(sectionId: String?) {
        guard let sectionId else { return }
        for cluster in viewModel.clusters {
            if cluster.sections.contains(where: { $0.sectionId == sectionId }) {
                viewModel.selectedClusterId = cluster.clusterId
                break
            }
        }
        viewModel.previewRecordings = []
        viewModel.selectorTestMessage = nil
    }
}
