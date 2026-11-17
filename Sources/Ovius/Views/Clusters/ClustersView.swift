import SwiftUI

/// Native master-detail management workspace for Domain 2 `Cluster` and `Section` groupings.
public struct ClustersView: View {
    @Bindable public var viewModel: ClustersViewModel

    @State private var showingNewClusterSheet = false
    @State private var editingCluster: Cluster?
    @State private var showingNewSectionSheet = false
    @State private var editingSection: Section?

    public init(viewModel: ClustersViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        HSplitView {
            clusterAndSectionList
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

            sectionDetailPane
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Clusters & Sections")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingNewClusterSheet = true
                } label: {
                    Label("Add Cluster", systemImage: "folder.badge.plus")
                }

                if viewModel.selectedCluster != nil {
                    Button {
                        showingNewSectionSheet = true
                    } label: {
                        Label("Add Section", systemImage: "plus.rectangle.on.folder")
                    }
                }
            }
        }
        .onAppear {
            viewModel.reload()
        }
        .sheet(isPresented: $showingNewClusterSheet) {
            ClusterEditorSheet { id, name, tags in
                viewModel.createOrUpdateCluster(clusterId: id, name: name, tagsText: tags)
            }
        }
        .sheet(item: $editingCluster) { cluster in
            ClusterEditorSheet(existingCluster: cluster) { id, name, tags in
                viewModel.createOrUpdateCluster(clusterId: id, name: name, tagsText: tags)
            }
        }
        .sheet(isPresented: $showingNewSectionSheet) {
            if let cluster = viewModel.selectedCluster {
                SectionEditorSheet(clusterId: cluster.clusterId) { sId, cId, name, cams, locs, tags, files, trucks in
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
        .sheet(item: $editingSection) { section in
            SectionEditorSheet(clusterId: section.clusterId, existingSection: section) { sId, cId, name, cams, locs, tags, files, trucks in
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

    private var clusterAndSectionList: some View {
        List {
            ForEach(viewModel.clusters, id: \.clusterId) { cluster in
                SwiftUI.Section {
                    ForEach(cluster.sections.sorted { $0.sectionId < $1.sectionId }, id: \.sectionId) { section in
                        Button {
                            viewModel.selectedClusterId = cluster.clusterId
                            viewModel.selectedSectionId = section.sectionId
                            viewModel.previewRecordings = []
                            viewModel.selectorTestMessage = nil
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(section.name)
                                        .font(.body)
                                    Text("\(section.cameraIds.count) cameras • \(section.sectionId)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewModel.selectedSection?.sectionId == section.sectionId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(cluster.name)
                        Spacer()
                        Button("Edit") {
                            editingCluster = cluster
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var sectionDetailPane: some View {
        if let section = viewModel.selectedSection {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let errorMessage = viewModel.errorMessage {
                        GroupBox {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.name)
                                .font(.title2.bold())
                            Text("Section ID: \(section.sectionId) • Cluster: \(section.clusterId)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Button("Edit Selectors") {
                            editingSection = section
                        }

                        Button("Delete Section", role: .destructive) {
                            viewModel.deleteSection(section)
                        }
                    }

                    GroupBox("Dynamic Recording Selectors") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Camera IDs") {
                                Text(section.cameraIds.isEmpty ? "—" : section.cameraIds.joined(separator: ", "))
                            }
                            LabeledContent("Location Tags") {
                                Text(section.locationTags.isEmpty ? "—" : section.locationTags.joined(separator: ", "))
                            }
                            LabeledContent("Custom Tags") {
                                Text(section.customTags.isEmpty ? "—" : section.customTags.joined(separator: ", "))
                            }
                            LabeledContent("Exact Filenames") {
                                Text(section.filenames.isEmpty ? "—" : section.filenames.joined(separator: ", "))
                            }
                            LabeledContent("Assigned Trucks Override") {
                                Text(section.assignedTrucks.map(String.init) ?? "Auto-detected from telemetry")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Live AWS DynamoDB Selector Test") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button {
                                    Task { await viewModel.testSectionSelector(section) }
                                } label: {
                                    if viewModel.isTestingSelector {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("Test Selector Against AWS", systemImage: "network")
                                    }
                                }
                                .disabled(viewModel.isTestingSelector)

                                if let msg = viewModel.selectorTestMessage {
                                    Text(msg)
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }

                            if !viewModel.previewRecordings.isEmpty {
                                Table(viewModel.previewRecordings) {
                                    TableColumn("Recording ID") { rec in
                                        Text(rec.recordingId).font(.caption.monospaced())
                                    }
                                    TableColumn("Camera") { rec in
                                        Text(rec.cameraId).font(.caption)
                                    }
                                    TableColumn("Timestamp") { rec in
                                        Text(rec.timestamp).font(.caption.monospacedDigit())
                                    }
                                    TableColumn("Location") { rec in
                                        Text(rec.locationTag).font(.caption)
                                    }
                                }
                                .frame(height: 220)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView(
                "No Section Selected",
                systemImage: "square.stack.3d.up",
                description: Text("Select a section from the sidebar or add a new section to inspect its AWS selectors.")
            )
        }
    }
}
