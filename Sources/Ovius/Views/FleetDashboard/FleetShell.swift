import AppKit
import SwiftUI

// MARK: - Rail

/// The app's mark and its pages: Dashboard, Clusters & Sections, Uploads, Settings.
struct FleetRail: View {
    @Binding var selection: AppSidebarTab

    var body: some View {
        VStack(spacing: Ov.Space.s) {
            Image(systemName: "viewfinder")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Ov.onInverse)
                .frame(width: 36, height: 36)
                .background(Ov.inverse, in: Circle())
                .padding(.bottom, Ov.Space.m)
            item(.dashboard)
            item(.clusters)
            item(.uploads)
            Spacer()
            item(.settings)
        }
        .padding(.vertical, Ov.Space.l)
        .frame(width: 68)
        .frame(maxHeight: .infinity)
    }

    private func item(_ tab: AppSidebarTab) -> some View {
        let on = selection == tab
        return Button { selection = tab } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 15, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Ov.ink : Ov.ink2)
                .frame(width: 40, height: 40)
                .background(on ? Ov.sage : .clear, in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Recordings column

/// The recordings of the active cluster to pick from: cluster, search, section, camera and date on top, a card per
/// recording, and how many are picked. A click shows that recording; ⌘-click or the box adds it to a selection that
/// the Refresh bar then shows.
struct FleetRecordingsColumn: View {
    let viewModel: DashboardViewModel

    var body: some View {
        @Bindable var sidebar = viewModel.sidebar
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Ov.Space.m) {
                HStack(spacing: Ov.Space.s) {
                    Text("Recordings")
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                    Spacer()
                    let all = sidebar.allSidebarRecordingsSelected
                    Button(all ? "Clear" : "Select all (\(sidebar.sidebarRecordings.count))") {
                        if all { sidebar.updateSelectedRecordings([]) } else { sidebar.selectAllSidebarRecordings() }
                    }
                    .buttonStyle(OvButtonStyle(.secondary, size: .small))
                    .disabled(sidebar.sidebarRecordings.isEmpty)
                    OvIconButton("arrow.clockwise", shape: .round, help: "Reload recordings and clear cached telemetry") {
                        Task { await viewModel.refreshAll() }
                    }
                    .disabled(viewModel.isInitialLoading)
                }
                OvPillMenu(sidebar.activeCluster?.name ?? "Choose a cluster", systemImage: "square.stack.3d.up") {
                    ForEach(sidebar.clusters, id: \.clusterId) { cluster in
                        Button { viewModel.selectCluster(cluster.clusterId) } label: {
                            if cluster.clusterId == sidebar.activeCluster?.clusterId {
                                Label(cluster.name, systemImage: "checkmark")
                            } else {
                                Text(cluster.name)
                            }
                        }
                    }
                }
                .help("The cluster whose recordings are listed")
                OvSearchField(text: $sidebar.sidebarSearchText, prompt: "Clips, cameras, locations…")
                HStack(spacing: Ov.Space.s) {
                    sectionMenu(sidebar)
                    cameraMenu(sidebar)
                }
                dateRange(sidebar)
            }
            .padding(Ov.Space.l)

            ScrollView { cards(sidebar) }
                .frame(maxHeight: .infinity, alignment: .top)

            footer(sidebar)
        }
        .onChange(of: sidebar.sidebarSearchText) { _, _ in sidebar.rebuildSidebarForSearchChange() }
        .onAppear { viewModel.loadCatalog() }
    }

    // MARK: Filters

    private func sectionMenu(_ sidebar: DashboardSidebarViewModel) -> some View {
        let picked = sidebar.sectionsInActiveCluster.filter { sidebar.filterState.selectedSectionIds.contains($0.sectionId) }
        let title = picked.isEmpty ? "All sections" : (picked.count == 1 ? picked[0].name : "\(picked.count) sections")
        return OvPillMenu(title, systemImage: "square.split.2x2") {
            Button(action: sidebar.clearSectionFilters) {
                if picked.isEmpty { Label("All sections", systemImage: "checkmark") } else { Text("All sections") }
            }
            Divider()
            ForEach(sidebar.sectionsInActiveCluster, id: \.sectionId) { section in
                Button { sidebar.toggleSectionFilter(section.sectionId) } label: {
                    if sidebar.filterState.selectedSectionIds.contains(section.sectionId) {
                        Label(section.name, systemImage: "checkmark")
                    } else {
                        Text(section.name)
                    }
                }
            }
        }
    }

    private func cameraMenu(_ sidebar: DashboardSidebarViewModel) -> some View {
        let picked = sidebar.filterState.selectedCameraIds
        let title = picked.isEmpty ? "All cameras" : (picked.count == 1 ? picked.first! : "\(picked.count) cameras")
        return OvPillMenu(title, systemImage: "video") {
            Button(action: sidebar.clearCameraFilters) {
                if picked.isEmpty { Label("All cameras", systemImage: "checkmark") } else { Text("All cameras") }
            }
            Divider()
            ForEach(sidebar.camerasInScope, id: \.self) { camera in
                Button { sidebar.toggleCameraFilter(camera) } label: {
                    if picked.contains(camera) { Label(camera, systemImage: "checkmark") } else { Text(camera) }
                }
            }
        }
    }

    private func dateRange(_ sidebar: DashboardSidebarViewModel) -> some View {
        @Bindable var sidebar = sidebar
        let preset = Binding<DateRangePreset>(
            get: { sidebar.filterState.datePreset },
            set: { sidebar.selectDatePreset($0) }
        )
        return VStack(alignment: .leading, spacing: Ov.Space.s) {
            HStack {
                OvSegmentedControl(selection: preset, options: DateRangePreset.quickPresets.map { ($0, $0.shortLabel) })
                Spacer(minLength: 0)
                if sidebar.filterState.datePreset == .custom {
                    Button("Reset", action: sidebar.resetDateRangeToDefault)
                        .buttonStyle(OvButtonStyle(.quiet, size: .small))
                }
            }
            HStack(spacing: Ov.Space.s) {
                Text("From").foregroundStyle(Ov.ink2)
                DatePicker("From", selection: $sidebar.filterState.startDate, in: ...sidebar.filterState.endDate, displayedComponents: .date)
                    .labelsHidden()
                Text("to").foregroundStyle(Ov.ink2)
                DatePicker("To", selection: $sidebar.filterState.endDate, in: sidebar.filterState.startDate..., displayedComponents: .date)
                    .labelsHidden()
                Text("UTC").foregroundStyle(Ov.ink3)
            }
            .font(.system(size: 12))
            .datePickerStyle(.compact)
            .controlSize(.small)
            .environment(\.calendar, DashboardFilterState.utcCalendar)
            .environment(\.timeZone, .gmt)
            .onChange(of: sidebar.filterState.startDate) { _, _ in sidebar.onCustomStartDateEdited() }
            .onChange(of: sidebar.filterState.endDate) { _, _ in sidebar.onCustomEndDateEdited() }
        }
    }

    // MARK: Cards

    private func cards(_ sidebar: DashboardSidebarViewModel) -> some View {
        LazyVStack(spacing: Ov.Space.s) {
            if viewModel.isInitialLoading && sidebar.clusterRecordings.isEmpty {
                OvLoadingState("Loading recordings", message: "Fetching this cluster's recordings.")
            } else if sidebar.displayedSidebarRecordings.isEmpty {
                OvEmptyState(systemImage: "film.stack", title: "No matching clips", message: "Clear the section, camera, date or search.")
            }
            ForEach(sidebar.displayedSidebarRecordings) { rec in
                let stats = viewModel.loadedFleetRecording(for: rec.recordingId)
                let targets = sidebar.activeCluster?.fleetTargets ?? FleetTargets()
                FleetRecordingCard(
                    recording: rec,
                    sectionName: sidebar.sectionMapByRecId[rec.recordingId]?.sectionName ?? "Unassigned",
                    stats: stats,
                    status: stats.map { FleetAnalysis.status(of: $0, targets: targets) },
                    excTarget: targets.excEEU,
                    isSelected: sidebar.filterState.selectedRecordingIds.contains(rec.recordingId),
                    isShown: sidebar.appliedRecordingIds.contains(rec.recordingId),
                    onToggle: { toggle(rec.recordingId, sidebar) }
                )
                .onTapGesture { click(rec.recordingId, sidebar) }
            }
            if sidebar.hasMoreSidebarRecordings {
                Button("Load \(min(DashboardSidebarViewModel.pageSize, sidebar.remainingSidebarRecordingCount)) more (\(sidebar.remainingSidebarRecordingCount) left)",
                       action: sidebar.loadMoreSidebarRecordings)
                    .buttonStyle(OvButtonStyle(.secondary, size: .small))
                    .padding(.top, Ov.Space.xs)
            }
        }
        .padding(.horizontal, Ov.Space.l)
        .padding(.bottom, Ov.Space.l)
    }

    private func footer(_ sidebar: DashboardSidebarViewModel) -> some View {
        HStack {
            if let progress = viewModel.telemetryFetchProgress, viewModel.isFilteringData {
                ProgressView().controlSize(.mini)
                Text(progress).foregroundStyle(Ov.ink2).lineLimit(1)
            } else {
                Text("\(sidebar.displayedSidebarRecordings.count) of \(sidebar.sidebarRecordings.count) clips · ")
                    .foregroundStyle(Ov.ink2)
                    + Text("\(sidebar.filterState.selectedRecordingIds.count) selected").foregroundStyle(Ov.ink)
            }
            Spacer()
            Text("⌘-click to add")
                .foregroundStyle(Ov.ink3)
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.horizontal, Ov.Space.l)
        .padding(.vertical, Ov.Space.m)
    }

    // MARK: Picking

    /// A click shows only this recording, straight away; with ⌘ it is added to (or taken from) the selection.
    private func click(_ id: String, _ sidebar: DashboardSidebarViewModel) {
        if NSEvent.modifierFlags.contains(.command) {
            toggle(id, sidebar)
        } else {
            sidebar.updateSelectedRecordings([id])
            if sidebar.hasPendingSelectionChanges { viewModel.refreshPendingSelection() }
        }
    }

    private func toggle(_ id: String, _ sidebar: DashboardSidebarViewModel) {
        var ids = sidebar.filterState.selectedRecordingIds
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        sidebar.updateSelectedRecordings(ids)
    }
}

/// A recording as a card: its camera and length, where it is, and, once its telemetry has loaded, its cycles, how it
/// looks and both utilisations.
struct FleetRecordingCard: View {
    let recording: RecordingDTO
    let sectionName: String
    let stats: FleetRecording?
    let status: FleetAnalysis.RecordingStatus?
    /// The cluster's excavator EEU target, when there is one.
    let excTarget: Double?
    let isSelected: Bool
    /// Whether the dashboard is showing it now.
    let isShown: Bool
    let onToggle: () -> Void

    var body: some View {
        let r = recording
        let minutes = r.durationS / 60
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Ov.Space.s) {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? Ov.sageInk : Ov.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Remove \(r.cameraId)" : "Add \(r.cameraId)")
                Text(r.cameraId)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.2)
                    .lineLimit(1)
                Spacer(minLength: Ov.Space.s)
                Text(FleetAnalysis.hm(minutes))
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Ov.ink2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Ov.sunken, in: Capsule())
                    .help("Clip length")
            }
            Text(r.locationTag.localizedCaseInsensitiveContains(sectionName) ? r.locationTag : "\(sectionName) · \(r.locationTag)")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text("\(r.filename) · \(r.formattedTimestampLabel)")
                .font(.system(size: 11))
                .foregroundStyle(Ov.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
            if let s = stats {
                HStack {
                    (Text("\(s.completeCycles) cycles ") + Text("· \(s.cyclesPerHour.formatted(.number.precision(.fractionLength(1))))/h").foregroundStyle(Ov.ink2))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                    Spacer()
                    if let status { FleetStatusTag(status: status) }
                }
                .padding(.top, 2)
                VStack(spacing: 4) {
                    FleetEEUBar(label: "Exc", value: s.excEEU,
                                color: excTarget.map { s.excEEU < $0 ? Ov.negativeInk : FleetPalette.load } ?? FleetPalette.load)
                    FleetEEUBar(label: "Trk", value: s.truckEEU, color: Ov.ink2)
                }
                .padding(.top, 4)
            } else {
                Text("Figures appear once it's opened")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ov.ink3)
                    .padding(.top, 2)
            }
        }
        .padding(Ov.Space.m)
        .background(isSelected ? Ov.sage : Ov.card, in: RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous)
            .strokeBorder(isShown ? Ov.sageStrong : Ov.hairline, lineWidth: isShown ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}
