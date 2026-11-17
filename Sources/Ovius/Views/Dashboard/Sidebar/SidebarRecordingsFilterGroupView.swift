import SwiftUI

/// Sidebar filter group for selecting a Cluster, searching recordings, filtering Sections &
/// Cameras via native multi-select menus, and highlighting all matching recordings.
public struct SidebarRecordingsFilterGroupView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable public var sidebar: DashboardSidebarViewModel
    public let onSelectCluster: (String) -> Void

    public init(
        sidebar: DashboardSidebarViewModel,
        onSelectCluster: @escaping (String) -> Void
    ) {
        self.sidebar = sidebar
        self.onSelectCluster = onSelectCluster
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.compact) {
            headerRow

            searchField

            clusterRow

            if !sidebar.sectionsInActiveCluster.isEmpty || !sidebar.camerasInScope.isEmpty {
                sectionAndCameraMenus
            }
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight) {
                Text("Recordings & Clusters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tokens.text2)
                HStack(spacing: OviusDesign.Spacing.compact) {
                    if sidebar.filterState.hasScopeFilters {
                        clearScopeButton
                    }
                    selectAllButton
                }
            }
        } else {
            HStack(spacing: OviusDesign.Spacing.tight) {
                Text("Recordings & Clusters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)

                Spacer(minLength: OviusDesign.Spacing.tight)

                if sidebar.filterState.hasScopeFilters {
                    clearScopeButton
                }

                selectAllButton
            }
        }
    }

    private var clearScopeButton: some View {
        Button("Clear", action: sidebar.clearScopeSelection)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Tokens.primary.text)
            .accessibilityHint("Clears active Section and Camera filters")
    }

    private var selectAllButton: some View {
        Button(action: sidebar.selectAllSidebarRecordings) {
            Label(
                sidebar.allSidebarRecordingsSelected
                    ? "All Selected (\(sidebar.sidebarRecordings.count))"
                    : "Select All (\(sidebar.sidebarRecordings.count))",
                systemImage: sidebar.allSidebarRecordingsSelected ? "checkmark.circle.fill" : "checklist"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(sidebar.sidebarRecordings.isEmpty || sidebar.allSidebarRecordingsSelected)
        .accessibilityHint("Selects every recording matching the active filters")
    }

    private var searchField: some View {
        HStack(spacing: OviusDesign.Spacing.tight) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tokens.text3)
                .accessibilityHidden(true)

            TextField("Filter clips, camera, location…", text: $sidebar.sidebarSearchText)
                .textFieldStyle(.plain)
                .foregroundStyle(Tokens.text)
                .accessibilityLabel("Filter recordings")

            if !sidebar.sidebarSearchText.isEmpty {
                Button("Clear Recording Filter", systemImage: "xmark.circle.fill", action: clearSearch)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.text3)
            }
        }
        .padding(.horizontal, OviusDesign.Spacing.compact)
        .padding(.vertical, OviusDesign.Spacing.tight)
        .panelSurface(
            background: Tokens.bg,
            borderColor: Tokens.border.opacity(0.55),
            radius: OviusDesign.Radius.control
        )
    }

    private var clusterRow: some View {
        LabeledContent {
            Menu {
                ForEach(sidebar.clusters, id: \.clusterId) { cluster in
                    Button {
                        onSelectCluster(cluster.clusterId)
                    } label: {
                        if cluster.clusterId == sidebar.activeCluster?.clusterId {
                            Label(cluster.name, systemImage: "checkmark")
                        } else {
                            Text(cluster.name)
                        }
                    }
                }
            } label: {
                Text(sidebar.activeCluster?.name ?? "Select Cluster")
                    .lineLimit(1)
            }
            .controlSize(.small)
            .accessibilityLabel("Cluster")
            .accessibilityValue(sidebar.activeCluster?.name ?? "None")
        } label: {
            Text("Cluster")
                .font(.caption)
                .foregroundStyle(Tokens.text2)
        }
    }

    private var sectionAndCameraMenus: some View {
        HStack(spacing: OviusDesign.Spacing.compact) {
            if !sidebar.sectionsInActiveCluster.isEmpty {
                Menu {
                    Button(action: sidebar.clearSectionFilters) {
                        if sidebar.filterState.selectedSectionIds.isEmpty {
                            Label("All Sections", systemImage: "checkmark")
                        } else {
                            Text("All Sections")
                        }
                    }
                    Divider()
                    ForEach(sidebar.sectionsInActiveCluster, id: \.sectionId) { section in
                        Button {
                            sidebar.toggleSectionFilter(section.sectionId)
                        } label: {
                            if sidebar.filterState.selectedSectionIds.contains(section.sectionId) {
                                Label(section.name, systemImage: "checkmark")
                            } else {
                                Text(section.name)
                            }
                        }
                    }
                } label: {
                    Text(sectionMenuSummary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                }
                .controlSize(.small)
                .accessibilityLabel("Section Filter")
                .accessibilityValue(sectionMenuSummary)
            }

            if !sidebar.camerasInScope.isEmpty {
                Menu {
                    Button(action: sidebar.clearCameraFilters) {
                        if sidebar.filterState.selectedCameraIds.isEmpty {
                            Label("All Cameras", systemImage: "checkmark")
                        } else {
                            Text("All Cameras")
                        }
                    }
                    Divider()
                    ForEach(sidebar.camerasInScope, id: \.self) { camId in
                        Button {
                            sidebar.toggleCameraFilter(camId)
                        } label: {
                            if sidebar.filterState.selectedCameraIds.contains(camId) {
                                Label(camId, systemImage: "checkmark")
                            } else {
                                Text(camId)
                            }
                        }
                    }
                } label: {
                    Text(cameraMenuSummary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                }
                .controlSize(.small)
                .accessibilityLabel("Camera Filter")
                .accessibilityValue(cameraMenuSummary)
            }
        }
    }

    private var sectionMenuSummary: String {
        let selected = sidebar.filterState.selectedSectionIds
        if selected.isEmpty { return "All Sections" }
        if selected.count == 1,
           let id = selected.first,
           let match = sidebar.sectionsInActiveCluster.first(where: { $0.sectionId == id }) {
            return match.name
        }
        return "\(selected.count) Sections"
    }

    private var cameraMenuSummary: String {
        let selected = sidebar.filterState.selectedCameraIds
        if selected.isEmpty { return "All Cameras" }
        if selected.count == 1, let cam = selected.first {
            return cam.replacingOccurrences(of: "CAM-", with: "")
        }
        return "\(selected.count) Cameras"
    }

    private func clearSearch() {
        sidebar.sidebarSearchText = ""
    }
}
