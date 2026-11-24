import SwiftUI

/// The Clusters & Sections list column: each cluster with its sections under it. A cluster opens its page (targets,
/// tags, sections); a section opens its selectors.
public struct ClusterSectionListView: View {
    @Bindable public var viewModel: ClustersViewModel
    @State private var clusterDraft: ClusterEditorDraft?
    @State private var sectionDraft: SectionEditorDraft?

    public init(viewModel: ClustersViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clusters")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                Spacer()
                Button { clusterDraft = .create } label: { Label("New cluster", systemImage: "plus") }
                    .buttonStyle(OvButtonStyle(.secondary, size: .small))
                    .help("Create a new cluster")
            }
            .padding(Ov.Space.l)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Ov.Space.m) {
                    if viewModel.clusters.isEmpty {
                        OvEmptyState(systemImage: "square.stack.3d.up", title: "No clusters yet",
                                     message: "Create a cluster, then add the sections whose recordings it groups.")
                    }
                    ForEach(viewModel.clusters, id: \.clusterId) { cluster in
                        clusterBlock(cluster)
                    }
                }
                .padding(.horizontal, Ov.Space.l)
                .padding(.bottom, Ov.Space.l)
            }

            Text("\(viewModel.clusters.count) clusters · \(viewModel.clusters.reduce(0) { $0 + $1.sections.count }) sections")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Ov.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Ov.Space.l)
                .padding(.vertical, Ov.Space.m)
        }
        .task {
            viewModel.reload()
        }
        .sheet(item: $clusterDraft) { draft in
            ClusterEditorSheet(existingCluster: draft.existingCluster) { id, name, tags in
                viewModel.createOrUpdateCluster(clusterId: id, name: name, tagsText: tags)
                viewModel.openCluster(id)
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

    private func clusterBlock(_ cluster: Cluster) -> some View {
        let isOpen = viewModel.showsCluster && viewModel.selectedCluster?.clusterId == cluster.clusterId
        let sections = cluster.sections.sorted { $0.sectionId < $1.sectionId }
        let targets = cluster.fleetTargets.phrases.count
        return VStack(alignment: .leading, spacing: 2) {
            Button { viewModel.openCluster(cluster.clusterId) } label: {
                HStack(spacing: Ov.Space.m) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(isOpen ? Ov.card : Ov.sunken, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cluster.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text("\(sections.count) section\(sections.count == 1 ? "" : "s") · " + (targets == 0 ? "no targets" : "\(targets) target\(targets == 1 ? "" : "s")"))
                            .font(.system(size: 12))
                            .foregroundStyle(Ov.ink2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ov.ink3)
                }
                .padding(Ov.Space.s)
                .background(isOpen ? Ov.sage : .clear, in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open cluster \(cluster.name)")

            ForEach(sections, id: \.sectionId) { section in
                sectionRow(section)
            }

            Button { sectionDraft = .create(clusterId: cluster.clusterId) } label: {
                Label("Add section", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Ov.ink2)
                    .padding(.leading, 46)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Create a new section in \(cluster.name)")
        }
        .padding(Ov.Space.xs)
        .ovCard(.plain, padding: Ov.Space.xs, radius: Ov.Radius.inner)
    }

    private func sectionRow(_ section: Section) -> some View {
        let isOpen = !viewModel.showsCluster && viewModel.selectedSection?.sectionId == section.sectionId
        return Button { viewModel.openSection(section) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(section.name)
                    .font(.system(size: 13.5, weight: isOpen ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(section.cameraIds.count) cameras · \(section.sectionId)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Ov.ink2)
                    .lineLimit(1)
            }
            .padding(.leading, 46 - Ov.Space.s)
            .padding(.horizontal, Ov.Space.s)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOpen ? Ov.sage : .clear, in: RoundedRectangle(cornerRadius: Ov.Radius.small + 2, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open section \(section.name)")
    }
}
