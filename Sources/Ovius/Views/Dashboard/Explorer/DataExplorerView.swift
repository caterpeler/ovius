import SwiftUI

/// Bottom Data Explorer section separated from Diagnostic Views by a horizontal rule,
/// with in-place breadcrumb navigation (Recordings -> Cycles -> State Timings), search, filter, and sort controls.
public struct DataExplorerView: View {
    @Bindable public var viewModel: DashboardViewModel

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            breadcrumbHeader
            searchAndFilterToolbar

            if viewModel.isInitialLoading || viewModel.isFilteringData {
                SectionLoadingPlaceholderView(
                    title: "Updating Data Explorer…",
                    subtitle: "Applying cross-filters across recordings, haul cycles, and machine states.",
                    minHeight: 260
                )
            } else {
                switch viewModel.explorerLevel {
                case .recordings:
                    RecordingExplorerTableView(
                        rows: viewModel.displayedRecordingRows,
                        sortOrder: $viewModel.recordingSortOrder,
                        onOpenRecording: { row in
                            viewModel.openRecording(row)
                        }
                    )
                    .onChange(of: viewModel.recordingSortOrder) { _, newOrder in
                        viewModel.syncToolbarSortFromTable(newOrder)
                    }

                case .cycles(let recording):
                    CycleExplorerTableView(
                        recording: recording,
                        rows: viewModel.displayedCycleRows,
                        isLoadingDrilldown: viewModel.isExplorerDrilldownLoading,
                        onOpenCycle: { cycle in
                            viewModel.openCycle(cycle)
                        }
                    )

                case .stateTimings(_, let cycle):
                    StateTimingExplorerTableView(
                        cycle: cycle,
                        segmentRows: viewModel.displayedStateTimingRows,
                        scoopRows: viewModel.scoopTimingRows,
                        isLoadingDrilldown: viewModel.isExplorerDrilldownLoading
                    )
                }
            }
        }
    }

    // MARK: - Breadcrumb Navigation

    private var breadcrumbHeader: some View {
        HStack(spacing: 6) {
            Text("Data Explorer")
                .font(.title3.bold())

            Text("•")
                .foregroundStyle(.secondary)

            Button("All Recordings (\(viewModel.displayedRecordingRows.count))") {
                viewModel.popToRecordings()
            }
            .buttonStyle(.link)
            .disabled(viewModel.explorerLevel == .recordings)

            if case .cycles(let rec) = viewModel.explorerLevel {
                breadcrumbSeparator
                Text("\(rec.cameraId) (\(rec.filename))")
                    .font(.subheadline.weight(.semibold))
            } else if case .stateTimings(let rec, let cycle) = viewModel.explorerLevel {
                breadcrumbSeparator
                Button("\(rec.cameraId) (\(rec.filename))") {
                    viewModel.popToCycles()
                }
                .buttonStyle(.link)

                breadcrumbSeparator
                Text(cycle.cycleId)
                    .font(.subheadline.weight(.semibold))
            }

            Spacer()
        }
    }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Search, Filter & Sort Toolbar

    private var searchAndFilterToolbar: some View {
        GroupBox {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search ID, camera, machine, location, or state…", text: $viewModel.explorerSearchText)
                        .textFieldStyle(.plain)
                    if !viewModel.explorerSearchText.isEmpty {
                        Button {
                            viewModel.explorerSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .clipShape(.rect(cornerRadius: 6))
                .frame(maxWidth: 320)

                Spacer()

                contextualLayerControls
            }
        }
    }

    @ViewBuilder
    private var contextualLayerControls: some View {
        switch viewModel.explorerLevel {
        case .recordings:
            HStack(spacing: 8) {
                Picker("Section", selection: $viewModel.explorerSectionFilterId) {
                    Text("All Sections").tag(String?.none)
                    ForEach(viewModel.sectionsInActiveCluster, id: \.sectionId) { sec in
                        Text(sec.name).tag(Optional(sec.sectionId))
                    }
                }
                .frame(maxWidth: 150)

                Picker("Camera", selection: $viewModel.explorerCameraFilterId) {
                    Text("All Cameras").tag(String?.none)
                    ForEach(viewModel.camerasInScope, id: \.self) { cam in
                        Text(cam).tag(Optional(cam))
                    }
                }
                .frame(maxWidth: 145)

                Picker("Sort", selection: $viewModel.recordingSortField) {
                    ForEach(RecordingSortField.allCases) { field in
                        Text(field.rawValue).tag(field)
                    }
                }
                .frame(maxWidth: 125)
                .onChange(of: viewModel.recordingSortField) { _, _ in
                    viewModel.applyToolbarRecordingSort()
                }

                Button {
                    viewModel.recordingSortAscending.toggle()
                    viewModel.applyToolbarRecordingSort()
                } label: {
                    Image(systemName: viewModel.recordingSortAscending ? "arrow.up" : "arrow.down")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Toggle recording sort order")
            }

        case .cycles:
            HStack(spacing: 8) {
                Picker("Status", selection: $viewModel.cycleStatusFilter) {
                    ForEach(CycleStatusFilter.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .frame(maxWidth: 135)

                Picker("Excavator", selection: $viewModel.cycleExcavatorFilter) {
                    Text("All Exc").tag(String?.none)
                    ForEach(viewModel.availableCycleExcavators, id: \.self) { exc in
                        Text(exc).tag(Optional(exc))
                    }
                }
                .frame(maxWidth: 105)

                Picker("Truck", selection: $viewModel.cycleTruckFilter) {
                    Text("All Trucks").tag(String?.none)
                    ForEach(viewModel.availableCycleTrucks, id: \.self) { trk in
                        Text(trk).tag(Optional(trk))
                    }
                }
                .frame(maxWidth: 110)

                Toggle("Uncertain (<0.70)", isOn: $viewModel.cycleUncertainOnly)
                    .toggleStyle(.checkbox)
            }

        case .stateTimings:
            HStack(spacing: 8) {
                Picker("Role", selection: $viewModel.timingRoleFilter) {
                    ForEach(MachineRoleFilter.allCases) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
                .frame(maxWidth: 130)

                Picker("State", selection: $viewModel.timingStateFilter) {
                    Text("All States").tag(MachineState?.none)
                    ForEach(MachineState.allCases, id: \.self) { st in
                        Text(st.rawValue).tag(Optional(st))
                    }
                }
                .frame(maxWidth: 145)

                Toggle("Uncertain (<0.70)", isOn: $viewModel.timingUncertainOnly)
                    .toggleStyle(.checkbox)
            }
        }
    }
}
