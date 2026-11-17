import SwiftUI

/// Widget 1: Hierarchical Cluster -> Sections -> Cameras -> Recordings selector.
/// Clicking any entry updates `DashboardFilterState` and cross-filters all other widgets and Data Explorer.
public struct RecordingsClusterSelectorWidget: View {
    @Bindable public var viewModel: DashboardViewModel
    @State private var isExpandedPicker: Bool = false
    @State private var clipSearchText: String = ""

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Recordings / Cluster", systemImage: "square.stack.3d.up.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !viewModel.filterState.selectedSectionIds.isEmpty
                        || !viewModel.filterState.selectedCameraIds.isEmpty
                        || !viewModel.filterState.selectedRecordingIds.isEmpty {
                        Button("Clear") {
                            viewModel.clearScopeSelection()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                // Cluster Picker
                HStack(spacing: 6) {
                    Text("Cluster")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Cluster", selection: $viewModel.filterState.clusterId) {
                        ForEach(viewModel.clusters, id: \.clusterId) { cluster in
                            Text(cluster.name).tag(Optional(cluster.clusterId))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: viewModel.filterState.clusterId) { _, newValue in
                        if let newValue {
                            viewModel.selectCluster(newValue)
                        }
                    }
                }

                // Section Chips (Click to toggle Section cross-filter)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.sectionsInActiveCluster, id: \.sectionId) { section in
                            let isSelected = viewModel.filterState.selectedSectionIds.contains(section.sectionId)
                            Button {
                                viewModel.toggleSectionFilter(section.sectionId)
                            } label: {
                                Text(section.name)
                                    .font(.caption.weight(isSelected ? .semibold : .regular))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.14))
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .clipShape(.rect(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Camera Chips (Click to toggle Camera cross-filter)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(viewModel.camerasInScope, id: \.self) { camId in
                            let isSelected = viewModel.filterState.selectedCameraIds.contains(camId)
                            Button {
                                viewModel.toggleCameraFilter(camId)
                            } label: {
                                Text(camId.replacingOccurrences(of: "CAM-", with: ""))
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(isSelected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.06))
                                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                                    .clipShape(.rect(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                HStack {
                    Text("\(viewModel.filteredRecordings.count) of \(viewModel.clusterRecordings.count) clips active")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(isExpandedPicker ? "Hide Clips" : "Pin Clips (\(viewModel.filterState.selectedRecordingIds.count))") {
                        isExpandedPicker.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .popover(isPresented: $isExpandedPicker, arrowEdge: .bottom) {
                    clipPopoverContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var filteredPinCandidates: [RecordingDTO] {
        let q = clipSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return viewModel.pinCandidates }
        return viewModel.pinCandidates.filter { rec in
            rec.cameraId.localizedCaseInsensitiveContains(q)
                || rec.filename.localizedCaseInsensitiveContains(q)
                || rec.locationTag.localizedCaseInsensitiveContains(q)
                || rec.recordingId.localizedCaseInsensitiveContains(q)
        }
    }

    private var clipPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pin Specific Recordings (\(viewModel.pinCandidates.count))")
                    .font(.headline)
                Spacer()
                if !viewModel.filterState.selectedRecordingIds.isEmpty {
                    Button("Clear Pinned") {
                        viewModel.clearRecordingPins()
                    }
                    .buttonStyle(.link)
                }
            }

            TextField("Filter by camera, filename, or location…", text: $clipSearchText)
                .textFieldStyle(.roundedBorder)

            List(filteredPinCandidates) { rec in
                let pinned = viewModel.filterState.selectedRecordingIds.contains(rec.recordingId)
                Button {
                    viewModel.toggleRecordingFilter(rec.recordingId)
                } label: {
                    HStack {
                        Image(systemName: pinned ? "checkmark.square.fill" : "square")
                            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(rec.cameraId) • \(rec.filename)")
                                .font(.caption)
                            Text("\(rec.locationTag) • \(rec.timestamp)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(width: 390, height: 300)
        }
        .padding(12)
    }
}
