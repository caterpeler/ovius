import Foundation

/// Scope and date-range filter state driven by the left recordings & cluster sidebar.
public struct DashboardFilterState: Sendable, Equatable {
    public var clusterId: String?
    public var selectedSectionIds: Set<String> = []
    public var selectedCameraIds: Set<String> = []
    public var selectedRecordingIds: Set<String> = []
    public var datePreset: DateRangePreset
    public var startDate: Date
    public var endDate: Date

    public static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    public init(
        clusterId: String? = nil,
        selectedSectionIds: Set<String> = [],
        selectedCameraIds: Set<String> = [],
        selectedRecordingIds: Set<String> = [],
        datePreset: DateRangePreset = .lastMonth,
        referenceDate: Date = .now
    ) {
        self.clusterId = clusterId
        self.selectedSectionIds = selectedSectionIds
        self.selectedCameraIds = selectedCameraIds
        self.selectedRecordingIds = selectedRecordingIds
        self.datePreset = datePreset
        let bounds = Self.presetBounds(for: datePreset, referenceDate: referenceDate)
        self.startDate = bounds.start
        self.endDate = bounds.end
    }

    /// True if section or camera filters narrow the sidebar list below all cluster recordings.
    public var hasScopeFilters: Bool {
        !selectedSectionIds.isEmpty || !selectedCameraIds.isEmpty
    }

    /// Returns UTC day-normalized `[start, end]` dates for the given preset relative to `referenceDate`.
    public static func presetBounds(
        for preset: DateRangePreset,
        referenceDate: Date = .now,
        earliestAvailableDate: Date? = nil
    ) -> (start: Date, end: Date) {
        let end = utcStartOfDay(for: referenceDate)
        let start: Date
        switch preset {
        case .last7Days:
            start = utcCalendar.date(byAdding: .day, value: -7, to: end) ?? end
        case .lastMonth:
            start = utcCalendar.date(byAdding: .month, value: -1, to: end) ?? end
        case .last3Months:
            start = utcCalendar.date(byAdding: .month, value: -3, to: end) ?? end
        case .allDates:
            let fallbackStart = utcCalendar.date(byAdding: .month, value: -3, to: end) ?? end
            start = earliestAvailableDate.map { utcStartOfDay(for: $0) } ?? fallbackStart
        case .custom:
            start = utcCalendar.date(byAdding: .month, value: -1, to: end) ?? end
        }
        return (start, max(start, end))
    }

    /// Inclusive lower bound (`00:00:00Z`) and exclusive upper bound (start of day after `endDate`) for UTC matching.
    public func utcDateBounds() -> (lower: Date, upper: Date)? {
        guard datePreset != .allDates else { return nil }
        let lower = Self.utcStartOfDay(for: startDate)
        let normalizedEnd = max(lower, Self.utcStartOfDay(for: endDate))
        let upper = Self.utcCalendar.date(byAdding: .day, value: 1, to: normalizedEnd)
            ?? normalizedEnd.addingTimeInterval(86_400)
        return (lower, upper)
    }

    public func matchesDateRange(_ date: Date?) -> Bool {
        guard let bounds = utcDateBounds(), let date else { return true }
        return date >= bounds.lower && date < bounds.upper
    }

    public mutating func applyDatePreset(
        _ preset: DateRangePreset,
        referenceDate: Date = .now,
        earliestAvailableDate: Date? = nil
    ) {
        datePreset = preset
        let bounds = Self.presetBounds(
            for: preset,
            referenceDate: referenceDate,
            earliestAvailableDate: earliestAvailableDate
        )
        startDate = bounds.start
        endDate = bounds.end
    }

    public static func utcStartOfDay(for date: Date) -> Date {
        utcCalendar.startOfDay(for: date)
    }
}
