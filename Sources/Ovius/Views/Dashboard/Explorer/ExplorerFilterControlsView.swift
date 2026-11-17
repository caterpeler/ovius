import SwiftUI

/// Lightweight native filter & sort controls scoped to the active Data Explorer drilldown layer.
public struct ExplorerFilterControlsView: View {
    @Bindable public var explorer: DataExplorerViewModel
    public let sections: [Section]
    public let cameras: [String]

    public init(
        explorer: DataExplorerViewModel,
        sections: [Section],
        cameras: [String]
    ) {
        self.explorer = explorer
        self.sections = sections
        self.cameras = cameras
    }

    public var body: some View {
        switch explorer.explorerLevel {
        case .recordings:
            HStack(spacing: OviusDesign.Spacing.compact) {
                Picker("Section", selection: $explorer.explorerSectionFilterId) {
                    Text("All Sections").tag(String?.none)
                    ForEach(sections, id: \.sectionId) { sec in
                        Text(sec.name).tag(Optional(sec.sectionId))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Filter table by section")

                Picker("Camera", selection: $explorer.explorerCameraFilterId) {
                    Text("All Cameras").tag(String?.none)
                    ForEach(cameras, id: \.self) { cam in
                        Text(cam).tag(Optional(cam))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Filter table by camera")

                Spacer(minLength: OviusDesign.Spacing.compact)

                HStack(spacing: OviusDesign.Spacing.tight) {
                    Picker("Sort", selection: $explorer.recordingSortField) {
                        ForEach(RecordingSortField.allCases) { field in
                            Text("Sort: \(field.rawValue)").tag(field)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Sort recordings by")
                    .onChange(of: explorer.recordingSortField) { _, _ in
                        explorer.applyToolbarRecordingSort()
                    }

                    Button(
                        explorer.recordingSortAscending ? "Sort Ascending" : "Sort Descending",
                        systemImage: explorer.recordingSortAscending ? "arrow.up" : "arrow.down",
                        action: toggleSortDirection
                    )
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(explorer.recordingSortAscending ? "Sorted ascending" : "Sorted descending")
                }
            }

        case .cycles:
            HStack(spacing: OviusDesign.Spacing.compact) {
                Picker("Status", selection: $explorer.cycleStatusFilter) {
                    ForEach(CycleStatusFilter.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Filter cycles by status")

                Picker("Excavator", selection: $explorer.cycleExcavatorFilter) {
                    Text("All Excavators").tag(String?.none)
                    ForEach(explorer.availableCycleExcavators, id: \.self) { exc in
                        Text(exc).tag(Optional(exc))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Filter cycles by excavator")

                Picker("Truck", selection: $explorer.cycleTruckFilter) {
                    Text("All Trucks").tag(String?.none)
                    ForEach(explorer.availableCycleTrucks, id: \.self) { trk in
                        Text(trk).tag(Optional(trk))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Filter cycles by truck")

                Spacer(minLength: OviusDesign.Spacing.compact)

                Toggle("Uncertain (<0.70)", isOn: $explorer.cycleUncertainOnly)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }

        case .stateTimings:
            HStack(spacing: OviusDesign.Spacing.compact) {
                Picker("Role", selection: $explorer.timingRoleFilter) {
                    ForEach(MachineRoleFilter.allCases) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Filter state timings by machine role")

                Picker("State", selection: $explorer.timingStateFilter) {
                    Text("All States").tag(MachineState?.none)
                    ForEach(MachineState.allCases, id: \.self) { st in
                        Text(st.rawValue).tag(Optional(st))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Filter state timings by machine state")

                Spacer(minLength: OviusDesign.Spacing.compact)

                Toggle("Uncertain (<0.70)", isOn: $explorer.timingUncertainOnly)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
        }
    }

    private func toggleSortDirection() {
        explorer.recordingSortAscending.toggle()
        explorer.applyToolbarRecordingSort()
    }
}
