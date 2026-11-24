import SwiftUI

/// The Clusters & Sections page. A cluster shows its targets (SLA), tags and sections; a section shows its recording
/// selectors and a check of them against AWS.
public struct ClustersView: View {
    @Bindable public var viewModel: ClustersViewModel

    @State private var clusterDraft: ClusterEditorDraft?
    @State private var sectionDraft: SectionEditorDraft?
    @State private var confirmingDelete: DeleteTarget?

    private enum DeleteTarget: Identifiable {
        case cluster(Cluster), section(Section)
        var id: String {
            switch self {
            case .cluster(let c): "cluster-\(c.clusterId)"
            case .section(let s): "section-\(s.sectionId)"
            }
        }
    }

    public init(viewModel: ClustersViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ov.Space.xl) {
                if let errorMessage = viewModel.errorMessage {
                    OvBanner(.error, title: "Something went wrong", message: errorMessage)
                }
                if let cluster = viewModel.selectedCluster {
                    if viewModel.showsCluster || viewModel.selectedSection == nil {
                        clusterPage(cluster)
                    } else if let section = viewModel.selectedSection {
                        sectionPage(section, in: cluster)
                    }
                } else {
                    OvEmptyState(systemImage: "square.stack.3d.up", title: "No cluster selected",
                                 message: "Pick a cluster on the left, or create one.")
                        .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
            .padding(Ov.Space.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Ov.canvas)
        .foregroundStyle(Ov.ink)
        .navigationTitle(viewModel.showsCluster ? (viewModel.selectedCluster?.name ?? "Clusters & Sections")
                                                : (viewModel.selectedSection?.name ?? "Clusters & Sections"))
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
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                switch confirmingDelete {
                case .cluster(let c): viewModel.deleteCluster(c)
                case .section(let s):
                    viewModel.deleteSection(s)
                    viewModel.showsCluster = true
                case nil: break
                }
                confirmingDelete = nil
            }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: Cluster page

    private func clusterPage(_ cluster: Cluster) -> some View {
        let sections = cluster.sections.sorted { $0.sectionId < $1.sectionId }
        return VStack(alignment: .leading, spacing: Ov.Space.xl) {
            OvPageHeader(cluster.name, details: [cluster.clusterId, "\(sections.count) section\(sections.count == 1 ? "" : "s")"]) {
                HStack(spacing: Ov.Space.s) {
                    Button { clusterDraft = .edit(cluster) } label: { Label("Rename", systemImage: "pencil") }
                        .buttonStyle(.ovSecondary)
                    Button { confirmingDelete = .cluster(cluster) } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(OvButtonStyle(.destructive))
                }
            }

            ClusterTargetsCard(cluster: cluster) { viewModel.saveTargets($0, for: cluster) }

            VStack(alignment: .leading, spacing: Ov.Space.l) {
                OvCardHeader("Sections", subtitle: "Each section picks its recordings by camera, location, tag or filename.") {
                    Button { sectionDraft = .create(clusterId: cluster.clusterId) } label: { Label("Add section", systemImage: "plus") }
                        .buttonStyle(OvButtonStyle(.secondary, size: .small))
                }
                if sections.isEmpty {
                    Text("No sections yet. Add one to start grouping recordings.")
                        .font(.system(size: 13))
                        .foregroundStyle(Ov.ink2)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Ov.Space.m, alignment: .top)], spacing: Ov.Space.m) {
                        ForEach(sections, id: \.sectionId) { sectionTile($0) }
                    }
                }
            }
            .ovCard()

            if !cluster.tags.isEmpty {
                VStack(alignment: .leading, spacing: Ov.Space.m) {
                    OvCardHeader("Tags")
                    chips(cluster.tags)
                }
                .ovCard()
            }
        }
    }

    private func sectionTile(_ section: Section) -> some View {
        Button { viewModel.openSection(section) } label: {
            VStack(alignment: .leading, spacing: Ov.Space.s) {
                HStack {
                    Text(section.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: Ov.Space.s)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Ov.ink3)
                }
                Text(section.sectionId).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Ov.ink3).lineLimit(1)
                HStack(spacing: 6) {
                    FleetChip(text: "\(section.cameraIds.count) cameras")
                    if !section.locationTags.isEmpty { FleetChip(text: "\(section.locationTags.count) locations") }
                    if let trucks = section.assignedTrucks { FleetChip(text: "\(trucks) trucks") }
                }
            }
            .padding(Ov.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Section page

    private func sectionPage(_ section: Section, in cluster: Cluster) -> some View {
        VStack(alignment: .leading, spacing: Ov.Space.xl) {
            OvBreadcrumb([.init(cluster.name) { viewModel.openCluster(cluster.clusterId) }, .init(section.name)])
            OvPageHeader(section.name, details: [section.sectionId, cluster.name]) {
                HStack(spacing: Ov.Space.s) {
                    Button { sectionDraft = .edit(section) } label: { Label("Edit selectors", systemImage: "pencil") }
                        .buttonStyle(.ovSecondary)
                    Button { confirmingDelete = .section(section) } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(OvButtonStyle(.destructive))
                }
            }

            inheritedTargets(cluster)

            VStack(alignment: .leading, spacing: Ov.Space.m) {
                OvCardHeader("Recording selectors", subtitle: "A recording belongs to this section when it matches every selector that is set.")
                selectorRow("Camera IDs", section.cameraIds)
                selectorRow("Location tags", section.locationTags)
                selectorRow("Custom tags", section.customTags)
                selectorRow("Exact filenames", section.filenames)
                HStack(alignment: .firstTextBaseline) {
                    Text("Assigned trucks").font(.system(size: 13)).foregroundStyle(Ov.ink2).frame(width: 140, alignment: .leading)
                    Text(section.assignedTrucks.map(String.init) ?? "Found from telemetry")
                        .font(.system(size: 13))
                        .foregroundStyle(section.assignedTrucks == nil ? Ov.ink2 : Ov.ink)
                    Spacer()
                }
                .padding(.top, Ov.Space.xs)
            }
            .ovCard()

            VStack(alignment: .leading, spacing: Ov.Space.l) {
                OvCardHeader("Check against AWS", subtitle: "Finds the recordings in AWS that these selectors match.") {
                    Button {
                        Task { await viewModel.testSectionSelector(section) }
                    } label: {
                        if viewModel.isTestingSelector {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Check selectors", systemImage: "network")
                        }
                    }
                    .buttonStyle(.ovPrimary)
                    .disabled(viewModel.isTestingSelector)
                }
                if let msg = viewModel.selectorTestMessage {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Ov.positiveInk)
                }
                if !viewModel.previewRecordings.isEmpty {
                    previewTable
                }
            }
            .ovCard()
        }
    }

    /// A section has no targets of its own: it is judged by its cluster's.
    private func inheritedTargets(_ cluster: Cluster) -> some View {
        let phrases = cluster.fleetTargets.phrases
        return VStack(alignment: .leading, spacing: Ov.Space.m) {
            OvCardHeader("Targets", subtitle: "Sections use their cluster's targets. These are \(cluster.name)'s.") {
                Button { viewModel.openCluster(cluster.clusterId) } label: {
                    HStack(spacing: 4) {
                        Text("Edit on \(cluster.name)")
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                    }
                }
                .buttonStyle(OvButtonStyle(.quiet, size: .small))
            }
            if phrases.isEmpty {
                Text("None set, so this section's figures are judged by their own spread.")
                    .font(.system(size: 13))
                    .foregroundStyle(Ov.ink2)
            } else {
                chips(phrases)
            }
        }
        .ovCard()
    }

    private func selectorRow(_ label: String, _ values: [String]) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 13)).foregroundStyle(Ov.ink2).frame(width: 140, alignment: .leading).padding(.top, 3)
            if values.isEmpty {
                Text("Any").font(.system(size: 13)).foregroundStyle(Ov.ink3).padding(.top, 3)
            } else {
                chips(values)
            }
            Spacer(minLength: 0)
        }
    }

    private func chips(_ values: [String]) -> some View {
        OvFlowLayout(spacing: 6) {
            ForEach(values, id: \.self) { FleetChip(text: $0, ink: Ov.ink, fill: Ov.sunken) }
        }
    }

    private var previewTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: Ov.Space.m) {
                Text("Recording").frame(maxWidth: .infinity, alignment: .leading)
                Text("Camera").frame(width: 130, alignment: .leading)
                Text("Recorded").frame(width: 150, alignment: .leading)
                Text("Location").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Ov.ink3)
            .padding(.horizontal, Ov.Space.m)
            .padding(.vertical, Ov.Space.s)
            .background(Ov.sunken.opacity(0.7), in: RoundedRectangle(cornerRadius: Ov.Radius.small, style: .continuous))
            ForEach(viewModel.previewRecordings) { rec in
                HStack(spacing: Ov.Space.m) {
                    Text(rec.recordingId).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(rec.cameraId).frame(width: 130, alignment: .leading)
                    Text(rec.formattedTimestampLabel.isEmpty ? rec.timestamp : rec.formattedTimestampLabel)
                        .monospacedDigit().frame(width: 150, alignment: .leading)
                    Text(rec.locationTag).lineLimit(1).foregroundStyle(Ov.ink2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, Ov.Space.m)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Ov.hairline).frame(height: 1) }
            }
        }
    }

    // MARK: Delete

    private var deleteTitle: String {
        switch confirmingDelete {
        case .cluster(let c): "Delete \(c.name)?"
        case .section(let s): "Delete \(s.name)?"
        case nil: ""
        }
    }

    private var deleteMessage: String {
        switch confirmingDelete {
        case .cluster: "Its sections and targets are deleted too. Recordings in AWS are not touched."
        case .section: "Recordings in AWS are not touched."
        case nil: ""
        }
    }
}

// MARK: - Cluster targets

/// A cluster's targets (SLA), edited in place. Each is optional: the dashboard compares the cluster's figures with
/// each one set, and judges the rest by their own spread.
struct ClusterTargetsCard: View {
    let cluster: Cluster
    let onSave: (FleetTargets) -> Void

    @State private var exc = ""
    @State private var truck = ""
    @State private var queue = ""
    @State private var cycle = ""

    var body: some View {
        let draft = FleetTargets(excEEU: Self.number(exc), truckEEU: Self.number(truck),
                                 maxQueueS: Self.number(queue), maxCycleS: Self.number(cycle))
        let changed = draft != cluster.fleetTargets
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            OvCardHeader("Targets", subtitle: "What this cluster's figures should be. The dashboard compares with each one you set; leave one empty to judge that figure by its own spread instead.") {
                FleetChip(text: cluster.fleetTargets.isEmpty ? "None set" : "\(cluster.fleetTargets.phrases.count) set",
                          ink: cluster.fleetTargets.isEmpty ? Ov.ink2 : Ov.sageInk,
                          fill: cluster.fleetTargets.isEmpty ? Ov.sunken : Ov.sage)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Ov.Space.m)], spacing: Ov.Space.m) {
                field("Excavator EEU at least", "Share of time in view spent working", $exc, "%")
                field("Truck EEU at least", "Share of time spotting, loading, departing", $truck, "%")
                field("Queue at most", "Longest a truck should wait to be loaded", $queue, "s")
                field("Cycle at most", "Arrival to departure", $cycle, "s")
            }
            HStack(spacing: Ov.Space.s) {
                if !isValid {
                    Label("Use positive numbers; EEU at most 100%.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Ov.negativeInk)
                } else if changed {
                    Text("Not saved yet").font(.system(size: 12.5)).foregroundStyle(Ov.warningInk)
                }
                Spacer()
                Button("Clear all") { exc = ""; truck = ""; queue = ""; cycle = "" }
                    .buttonStyle(OvButtonStyle(.quiet, size: .small))
                    .disabled(draft.isEmpty)
                Button("Revert") { load() }
                    .buttonStyle(OvButtonStyle(.secondary, size: .small))
                    .disabled(!changed)
                Button("Save targets") { onSave(draft) }
                    .buttonStyle(OvButtonStyle(.primary, size: .small))
                    .disabled(!changed || !isValid)
            }
        }
        .ovCard()
        .onAppear(perform: load)
        .onChange(of: cluster.clusterId) { _, _ in load() }
    }

    private func load() {
        let t = cluster.fleetTargets
        exc = Self.text(t.excEEU)
        truck = Self.text(t.truckEEU)
        queue = Self.text(t.maxQueueS)
        cycle = Self.text(t.maxCycleS)
    }

    private func field(_ title: String, _ note: String, _ value: Binding<String>, _ unit: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                Text(note).font(.system(size: 12)).foregroundStyle(Ov.ink2).lineLimit(2)
            }
            Spacer(minLength: Ov.Space.s)
            HStack(spacing: 4) {
                TextField(title, text: value, prompt: Text("Not set"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .frame(width: 60)
                Text(unit).foregroundStyle(Ov.ink2)
            }
            .padding(.horizontal, Ov.Space.m)
            .frame(height: 36)
            .background(Ov.card, in: Capsule())
        }
        .padding(Ov.Space.m)
        .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
    }

    private var isValid: Bool {
        func ok(_ text: String, max: Double = .infinity) -> Bool {
            text.trimmingCharacters(in: .whitespaces).isEmpty || Self.number(text).map { $0 > 0 && $0 <= max } == true
        }
        return ok(exc, max: 100) && ok(truck, max: 100) && ok(queue) && ok(cycle)
    }

    static func number(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return t.isEmpty ? nil : Double(t)
    }

    static func text(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) } ?? ""
    }
}

// MARK: - Flow layout

/// Lays chips out in rows, wrapping to the next row when one is full.
struct OvFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
