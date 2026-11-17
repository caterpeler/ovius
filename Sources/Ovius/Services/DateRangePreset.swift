import Foundation

/// Presets available in the sidebar Date Range filter group.
public enum DateRangePreset: String, CaseIterable, Identifiable, Sendable {
    case last7Days = "7 Days"
    case lastMonth = "Last Month"
    case last3Months = "3 Months"
    case allDates = "All"
    case custom = "Custom"

    public var id: String { rawValue }

    /// Compact segment label that fits comfortably in narrow macOS segmented controls.
    public var shortLabel: String {
        switch self {
        case .last7Days: "7D"
        case .lastMonth: "1M"
        case .last3Months: "3M"
        case .allDates: "All"
        case .custom: "Custom"
        }
    }

    /// Descriptive label exposed to VoiceOver and summary badges.
    public var accessibilityLabelText: String {
        switch self {
        case .last7Days: "Last 7 Days"
        case .lastMonth: "Last Month"
        case .last3Months: "Last 3 Months"
        case .allDates: "All Dates"
        case .custom: "Custom Range"
        }
    }

    /// Quick-select presets rendered in the segmented control (excluding `.custom`, which activates on manual picker edits).
    public static let quickPresets: [DateRangePreset] = [
        .last7Days,
        .lastMonth,
        .last3Months,
        .allDates,
    ]
}
