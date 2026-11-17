import Foundation

/// Quick calendar presets in the Date Range Selector widget (defaulting to Last 1 Month).
public enum DateRangePreset: String, CaseIterable, Identifiable, Sendable {
    case latestDay = "1D"
    case last7Days = "7D"
    case last1Month = "1M"
    case last3Months = "3M"
    case custom = "Custom"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .latestDay: "1D"
        case .last7Days: "7D"
        case .last1Month: "1M"
        case .last3Months: "3M"
        case .custom: "Custom"
        }
    }

    public var dayCount: Int? {
        switch self {
        case .latestDay: 1
        case .last7Days: 7
        case .last1Month: 30
        case .last3Months: 90
        case .custom: nil
        }
    }

    /// Computes inclusive UTC calendar-day `[startDate, endDate]` bounds anchored on `latestDate`.
    public func bounds(endingAt latestDate: Date) -> (start: Date, end: Date) {
        let dayStart = OviusFormat.utcStartOfDay(for: latestDate)
        let days = dayCount ?? 30
        let start = dayStart.addingTimeInterval(-Double(max(0, days - 1)) * 86_400.0)
        let end = dayStart.addingTimeInterval(86_399.0)
        return (start, end)
    }
}

/// Quick intra-day shift window presets in the Time Range Selector widget.
public enum ShiftTimePreset: String, CaseIterable, Identifiable, Sendable {
    case fullShift = "Full Shift"
    case startupEdge = "Startup Edge"
    case morning = "Morning"
    case middayBreak = "Break"
    case afternoon = "Afternoon"
    case closingEdge = "Closing Edge"
    case custom = "Custom"

    public var id: String { rawValue }

    /// Standard offset range `[todStartS, todEndS]` relative to default `06:00 UTC` clip start (`0..43200s`).
    public var offsetRange: (startS: Double, endS: Double)? {
        offsetRange(using: TelemetryCalculationConfig())
    }

    public var clockLabel: String {
        clockLabel(using: TelemetryCalculationConfig())
    }

    /// Computes `[todStartS, todEndS]` offset in seconds from the first configured shift start.
    public func offsetRange(using config: TelemetryCalculationConfig) -> (startS: Double, endS: Double)? {
        let baseMin = config.parsedShiftStartMinutes.first ?? 360
        let edgeS = Double(max(15, min(180, config.shiftEdgeWindowMin)) * 60)
        let shiftDurS = 43_200.0

        let breakRangeS: (startS: Double, endS: Double) = {
            if let firstBreak = config.parsedBreakMinuteRanges.first {
                var relStart = (firstBreak.start - baseMin) * 60
                var relEnd = (firstBreak.end - baseMin) * 60
                if relStart < 0 {
                    relStart += 86_400
                    relEnd += 86_400
                }
                if relEnd > relStart && relEnd <= Int(shiftDurS) {
                    return (Double(relStart), Double(relEnd))
                }
            }
            return (21_600.0, 25_200.0)
        }()

        switch self {
        case .fullShift:
            return (0, shiftDurS)
        case .startupEdge:
            return (0, min(shiftDurS, edgeS))
        case .morning:
            return (min(shiftDurS, edgeS), max(min(shiftDurS, edgeS), breakRangeS.startS))
        case .middayBreak:
            return breakRangeS
        case .afternoon:
            let aftEnd = max(breakRangeS.endS, shiftDurS - edgeS)
            return (breakRangeS.endS, aftEnd)
        case .closingEdge:
            return (max(0, shiftDurS - edgeS), shiftDurS)
        case .custom:
            return nil
        }
    }

    /// Formats UTC `HH:mm–HH:mm` clock range for `config`.
    public func clockLabel(using config: TelemetryCalculationConfig) -> String {
        guard let range = offsetRange(using: config) else { return "Custom" }
        let baseMin = config.parsedShiftStartMinutes.first ?? 360
        let lo = DashboardFilterState.shiftClockString(offsetS: range.startS, baseMinuteUTC: baseMin)
        let hi = DashboardFilterState.shiftClockString(offsetS: range.endS, baseMinuteUTC: baseMin)
        return "\(lo)–\(hi)"
    }
}

/// Unified PowerBI-style cross-filter state driving all dashboard content and the Data Explorer.
public struct DashboardFilterState: Sendable, Equatable {
    public var clusterId: String?
    public var selectedSectionIds: Set<String> = []
    public var selectedCameraIds: Set<String> = []
    public var selectedRecordingIds: Set<String> = []

    public var datePreset: DateRangePreset = .last1Month
    public var startDate: Date
    public var endDate: Date

    public var timePreset: ShiftTimePreset = .fullShift
    public var shiftBaseMinuteUTC: Int = 360
    public var todStartS: Double = 0
    public var todEndS: Double = 43_200

    /// Selected Lead in Widget 4 (highlights associated Diagnostic Cards without filtering raw data).
    public var highlightedLeadEntryId: String?

    public init(referenceDate: Date = .now) {
        let initialBounds = DateRangePreset.last1Month.bounds(endingAt: referenceDate)
        self.startDate = initialBounds.start
        self.endDate = initialBounds.end
    }

    /// True if any scope, date, or time filter narrows beyond Cluster + Last 1 Month + Full Shift defaults.
    public var hasNarrowedFilters: Bool {
        !selectedSectionIds.isEmpty
            || !selectedCameraIds.isEmpty
            || !selectedRecordingIds.isEmpty
            || datePreset != .last1Month
            || timePreset != .fullShift
    }

    /// Formats `todStartS` offset from `baseHourUTC` as `"HH:mm"`.
    public static func shiftClockString(offsetS: Double, baseHourUTC: Int = 6) -> String {
        shiftClockString(offsetS: offsetS, baseMinuteUTC: baseHourUTC * 60)
    }

    /// Formats `todStartS` offset from `baseMinuteUTC` as `"HH:mm"`.
    public static func shiftClockString(offsetS: Double, baseMinuteUTC: Int) -> String {
        let clamped = max(0, Int(offsetS.rounded()))
        let totalMinutes = baseMinuteUTC + (clamped / 60)
        let normalized = ((totalMinutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }
}
