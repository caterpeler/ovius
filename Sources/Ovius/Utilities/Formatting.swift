import Foundation

/// Pure formatting helpers for Ovius telemetry, KPI metrics, and UTC shift timestamps.
public enum OviusFormat {
    private static let isoFractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoStandardStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// Parses an ISO-8601 timestamp string emitted by AWS DynamoDB / Lambda.
    public static func parseISODate(_ raw: String) -> Date? {
        if let date = try? isoFractionalStyle.parse(raw) {
            return date
        }
        return try? isoStandardStyle.parse(raw)
    }

    /// Formats a `Date` as a UTC ISO-8601 string accepted by `/api/v1/*` `start_time` / `end_time`.
    public static func isoString(from date: Date) -> String {
        isoStandardStyle.format(date)
    }

    /// Formats a duration in seconds into `12s`, `4m 12s`, or `1h 05m`.
    public static func duration(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let clamped = max(0, seconds)
        if clamped < 60 {
            return String(format: "%.1fs", clamped)
        }
        let whole = Int(clamped.rounded())
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        return String(format: "%dm %02ds", minutes, secs)
    }

    /// Formats a scalar metric value cleanly according to its `MetricKey` unit.
    public static func metricValue(_ value: Double?, key: MetricKey) -> String {
        guard let value, value.isFinite else { return "—" }
        switch key {
        case .avgQueueTimeS, .avgSpotTimeS, .avgLoadDurationS, .avgDepartureLagS,
             .trueIdleExcessS, .breakWindowIdleExcessS:
            return duration(seconds: value)
        case .excavatorHangRatio, .shiftEdgeIdleRatio, .hourlySlumpConcentration,
             .incompleteCycleRatio, .outOfFrameRatio:
            return percentage(value)
        case .volumetricRateM3Hr:
            return String(format: "%.0f m³/hr", value)
        case .truckArrivalRateHr:
            return String(format: "%.1f /hr", value)
        }
    }

    /// Formats a `[0, 1]` ratio as a percentage string (`34.2%`).
    public static func percentage(_ ratio: Double?, decimals: Int = 1) -> String {
        guard let ratio, ratio.isFinite else { return "—" }
        return String(format: "%.\(decimals)f%%", ratio * 100.0)
    }

    /// Formats a signed relative delta (`+38.4%` or `-14.2%`).
    public static func signedDeltaPercentage(_ deltaRatio: Double?) -> String {
        guard let deltaRatio, deltaRatio.isFinite else { return "—" }
        let pct = deltaRatio * 100.0
        let prefix = pct > 0 ? "+" : ""
        return String(format: "%@%.1f%%", prefix, pct)
    }

    /// Formats a Z-score (`+1.8σ` or `-0.4σ`).
    public static func zScore(_ z: Double?) -> String {
        guard let z, z.isFinite else { return "—" }
        let prefix = z > 0 ? "+" : ""
        return String(format: "%@%.2fσ", prefix, z)
    }

    /// Formats a volume quantity in cubic meters (`1,240 m³`).
    public static func volumeM3(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f m³", value)
    }

    /// Formats a wall-clock `Date` as `HH:mm:ss UTC`.
    public static func utcClock(_ date: Date) -> String {
        let components = utcCalendar.dateComponents([.hour, .minute, .second], from: date)
        return String(
            format: "%02d:%02d:%02d UTC",
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    /// Formats a wall-clock `Date` as `yyyy-MM-dd HH:mm UTC`.
    public static func utcDateTime(_ date: Date) -> String {
        let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d UTC",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1,
            components.hour ?? 0,
            components.minute ?? 0
        )
    }

    /// Extracts UTC hour-of-day (`0...23`) and minute-of-day (`0...1439`) from a `Date`.
    public static func utcHourAndMinute(for date: Date) -> (hour: Int, minuteOfDay: Int) {
        let components = utcCalendar.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return (hour, hour * 60 + minute)
    }

    /// Extracts sub-second UTC seconds elapsed since `00:00:00Z` of that calendar day (`[0, 86400)`).
    public static func utcSecondsSinceMidnight(for date: Date) -> Double {
        let components = utcCalendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)
        let nanos = Double(components.nanosecond ?? 0) / 1_000_000_000.0
        return hour * 3600.0 + minute * 60.0 + second + nanos
    }

    /// Returns the UTC day start (`00:00:00Z`) containing `date`.
    public static func utcStartOfDay(for date: Date) -> Date {
        utcCalendar.startOfDay(for: date)
    }
}
