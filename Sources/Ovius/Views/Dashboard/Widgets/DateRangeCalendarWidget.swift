import SwiftUI

/// Widget 2: Interactive UTC calendar & range preset widget (defaulting to Last 1 Month / 30 days).
public struct DateRangeCalendarWidget: View {
    @Bindable public var viewModel: DashboardViewModel

    @State private var displayedMonthStart: Date = Date.now
    @State private var showingCustomPopover: Bool = false
    @State private var customStart: Date = Date.now
    @State private var customEnd: Date = Date.now

    private let weekdayLabels = ["M", "T", "W", "T", "F", "S", "S"]
    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        cal.firstWeekday = 2 // Monday
        return cal
    }()

    public init(viewModel: DashboardViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Date Range", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(rangeSummaryLabel) {
                        customStart = utcDateToLocalPickerDate(viewModel.filterState.startDate)
                        customEnd = utcDateToLocalPickerDate(viewModel.filterState.endDate)
                        showingCustomPopover = true
                    }
                    .buttonStyle(.link)
                    .font(.caption.monospacedDigit())
                    .popover(isPresented: $showingCustomPopover, arrowEdge: .bottom) {
                        customDatePopover
                    }
                }

                // Preset Chips (default 1M)
                HStack(spacing: 4) {
                    ForEach([DateRangePreset.latestDay, .last7Days, .last1Month, .last3Months]) { preset in
                        let isSelected = viewModel.filterState.datePreset == preset
                        Button {
                            viewModel.applyDatePreset(preset)
                        } label: {
                            Text(preset.label)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.14))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .clipShape(.rect(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Month Navigation
                HStack {
                    Button {
                        shiftMonth(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous month")

                    Spacer()
                    Text(monthTitle(for: displayedMonthStart))
                        .font(.caption.weight(.medium))
                    Spacer()

                    Button {
                        shiftMonth(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next month")
                }

                // Compact Interactive Calendar Grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                    ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                        Text(label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(Array(monthDaySlots.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(for: day)
                        } else {
                            Color.clear.frame(height: 18)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            syncDisplayedMonth(to: viewModel.referenceDate)
        }
        .onChange(of: viewModel.referenceDate) { _, newAnchor in
            syncDisplayedMonth(to: newAnchor)
        }
    }

    @ViewBuilder
    private func dayCell(for day: Date) -> some View {
        let dayStart = OviusFormat.utcStartOfDay(for: day)
        let inRange = dayStart >= OviusFormat.utcStartOfDay(for: viewModel.filterState.startDate)
            && dayStart <= OviusFormat.utcStartOfDay(for: viewModel.filterState.endDate)
        let hasRecordings = (viewModel.recordingCountByDate[dayStart] ?? 0) > 0
        let dayNum = utcCalendar.component(.day, from: day)

        Button {
            viewModel.selectSingleCalendarDate(dayStart)
        } label: {
            Text("\(dayNum)")
                .font(.system(size: 10, weight: inRange ? .bold : .regular).monospacedDigit())
                .frame(maxWidth: .infinity)
                .frame(height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(inRange ? Color.accentColor.opacity(0.24) : (hasRecordings ? Color.primary.opacity(0.05) : Color.clear))
                )
                .foregroundStyle(inRange ? Color.accentColor : (hasRecordings ? Color.primary : Color.secondary))
        }
        .buttonStyle(.plain)
    }

    private var customDatePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom UTC Date Range")
                .font(.headline)
            DatePicker("Start Date", selection: $customStart, displayedComponents: .date)
            DatePicker("End Date", selection: $customEnd, displayedComponents: .date)
            HStack {
                Spacer()
                Button("Apply") {
                    viewModel.applyCustomDateRange(
                        start: localPickerDateToUTCStartOfDay(customStart),
                        end: localPickerDateToUTCStartOfDay(customEnd)
                    )
                    showingCustomPopover = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    /// Maps a UTC `Date`'s calendar components (`yyyy-MM-dd`) to `12:00` on the same calendar day in `Calendar.current`
    /// so macOS `DatePicker` renders the exact UTC calendar date without local-offset shift.
    private func utcDateToLocalPickerDate(_ utcDate: Date) -> Date {
        let comps = utcCalendar.dateComponents([.year, .month, .day], from: utcDate)
        var localComps = DateComponents()
        localComps.year = comps.year
        localComps.month = comps.month
        localComps.day = comps.day
        localComps.hour = 12
        return Calendar.current.date(from: localComps) ?? utcDate
    }

    /// Reads the selected local calendar date (`yyyy-MM-dd`) from `DatePicker` and anchors it cleanly to `00:00:00 UTC`.
    private func localPickerDateToUTCStartOfDay(_ localDate: Date) -> Date {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: localDate)
        var utcComps = DateComponents()
        utcComps.year = comps.year
        utcComps.month = comps.month
        utcComps.day = comps.day
        utcComps.hour = 0
        utcComps.minute = 0
        utcComps.second = 0
        return utcCalendar.date(from: utcComps) ?? OviusFormat.utcStartOfDay(for: localDate)
    }

    private var monthDaySlots: [Date?] {
        guard let monthInterval = utcCalendar.dateInterval(of: .month, for: displayedMonthStart),
              let daysRange = utcCalendar.range(of: .day, in: .month, for: monthInterval.start) else {
            return []
        }
        let firstWeekday = utcCalendar.component(.weekday, from: monthInterval.start)
        // Monday-based leading offset (Mon=2 -> 0, Sun=1 -> 6)
        let leadingBlanks = (firstWeekday + 5) % 7
        var slots: [Date?] = Array(repeating: nil, count: leadingBlanks)

        for offset in 0..<daysRange.count {
            if let date = utcCalendar.date(byAdding: .day, value: offset, to: monthInterval.start) {
                slots.append(date)
            }
        }
        return slots
    }

    private var rangeSummaryLabel: String {
        let s = shortDateString(viewModel.filterState.startDate)
        let e = shortDateString(viewModel.filterState.endDate)
        return s == e ? s : "\(s) → \(e)"
    }

    private func shortDateString(_ date: Date) -> String {
        let comps = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
    }

    private func monthTitle(for date: Date) -> String {
        let comps = utcCalendar.dateComponents([.year, .month], from: date)
        let name = utcCalendar.shortMonthSymbols[max(0, min(11, (comps.month ?? 1) - 1))]
        return "\(name) \(comps.year ?? 2026)"
    }

    private func shiftMonth(by delta: Int) {
        if let shifted = utcCalendar.date(byAdding: .month, value: delta, to: displayedMonthStart) {
            displayedMonthStart = shifted
        }
    }

    private func syncDisplayedMonth(to date: Date) {
        if let monthStart = utcCalendar.dateInterval(of: .month, for: date)?.start {
            displayedMonthStart = monthStart
        }
    }
}
