import SwiftUI

/// Sidebar filter group for choosing quick UTC date range presets (`Last Month` default) or custom
/// `From` / `To` dates using native macOS controls.
public struct SidebarDateRangeGroupView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable public var sidebar: DashboardSidebarViewModel

    @State private var segmentedPreset: DateRangePreset? = .lastMonth

    public init(sidebar: DashboardSidebarViewModel) {
        self.sidebar = sidebar
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.compact) {
            headerRow

            Picker("Date Range Preset", selection: $segmentedPreset) {
                ForEach(DateRangePreset.quickPresets) { preset in
                    Text(preset.shortLabel)
                        .tag(Optional(preset))
                        .accessibilityLabel(preset.accessibilityLabelText)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .onAppear { syncSegmentedPreset(from: sidebar.filterState.datePreset) }
            .onChange(of: sidebar.filterState.datePreset) { _, newPreset in
                syncSegmentedPreset(from: newPreset)
            }
            .onChange(of: segmentedPreset) { _, chosen in
                if let chosen, chosen != sidebar.filterState.datePreset {
                    sidebar.selectDatePreset(chosen)
                }
            }

            datePickersRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: OviusDesign.Spacing.tight) {
            Text("Date Range")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Tokens.text2)

            Spacer(minLength: OviusDesign.Spacing.tight)

            if sidebar.filterState.datePreset != .lastMonth {
                Text(sidebar.filterState.datePreset.accessibilityLabelText)
                    .font(.caption)
                    .foregroundStyle(Tokens.text3)

                Button("Reset", action: sidebar.resetDateRangeToDefault)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Tokens.primary.text)
                    .accessibilityHint("Resets date range back to the last month")
            } else {
                Text("Last Month • UTC")
                    .font(.caption)
                    .foregroundStyle(Tokens.text3)
            }
        }
    }

    private var datePickersRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight) {
                    fromDatePickerRow
                    toDatePickerRow
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: OviusDesign.Spacing.compact) {
                        fromDatePickerRow
                        Spacer(minLength: OviusDesign.Spacing.tight)
                        toDatePickerRow
                    }

                    Grid(alignment: .leading, horizontalSpacing: OviusDesign.Spacing.compact, verticalSpacing: OviusDesign.Spacing.tight) {
                        GridRow {
                            Text("From")
                                .font(.caption)
                                .foregroundStyle(Tokens.text2)
                            fromDatePicker
                        }
                        GridRow {
                            Text("To")
                                .font(.caption)
                                .foregroundStyle(Tokens.text2)
                            toDatePicker
                        }
                    }
                }
            }
        }
        .environment(\.calendar, DashboardFilterState.utcCalendar)
        .environment(\.timeZone, .gmt)
        .onChange(of: sidebar.filterState.startDate) { _, _ in
            sidebar.onCustomStartDateEdited()
        }
        .onChange(of: sidebar.filterState.endDate) { _, _ in
            sidebar.onCustomEndDateEdited()
        }
    }

    private var fromDatePickerRow: some View {
        HStack(spacing: OviusDesign.Spacing.tight - 1) {
            Text("From")
                .font(.caption)
                .foregroundStyle(Tokens.text2)
            fromDatePicker
        }
    }

    private var toDatePickerRow: some View {
        HStack(spacing: OviusDesign.Spacing.tight - 1) {
            Text("To")
                .font(.caption)
                .foregroundStyle(Tokens.text2)
            toDatePicker
        }
    }

    private var fromDatePicker: some View {
        DatePicker(
            "Start Date",
            selection: $sidebar.filterState.startDate,
            in: ...sidebar.filterState.endDate,
            displayedComponents: .date
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .controlSize(.small)
        .accessibilityLabel("Start Date (UTC)")
    }

    private var toDatePicker: some View {
        DatePicker(
            "End Date",
            selection: $sidebar.filterState.endDate,
            in: sidebar.filterState.startDate...,
            displayedComponents: .date
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .controlSize(.small)
        .accessibilityLabel("End Date (UTC)")
    }

    private func syncSegmentedPreset(from preset: DateRangePreset) {
        let target: DateRangePreset? = (preset == .custom) ? nil : preset
        if segmentedPreset != target {
            segmentedPreset = target
        }
    }
}
