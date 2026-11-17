import Foundation

/// Pure formatting helpers for recording metadata, durations, counts, and utilization percentages.
public enum OviusFormat {
    private static let isoFractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoStandardStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// Parses an ISO-8601 timestamp string emitted by AWS DynamoDB / Lambda using a fast ASCII path.
    public static func parseISODate(_ raw: String) -> Date? {
        if let fast = fastParseISO8601(raw) {
            return fast
        }
        if let date = try? isoFractionalStyle.parse(raw) {
            return date
        }
        return try? isoStandardStyle.parse(raw)
    }

    /// Formats a `Date` as a UTC ISO-8601 string accepted by backend discovery queries.
    public static func isoString(from date: Date) -> String {
        isoStandardStyle.format(date)
    }

    /// Formats a duration in seconds into `12.0s`, `4m 12s`, or `1h 05m`.
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

    /// Formats a floating-point metric with fixed decimal precision (`4.2`).
    public static func decimal(_ value: Double?, decimals: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.\(decimals)f", value)
    }

    /// Formats a `[0, 1]` ratio as a percentage string (`34.2%`).
    public static func percentage(_ ratio: Double?, decimals: Int = 1) -> String {
        guard let ratio, ratio.isFinite else { return "—" }
        return String(format: "%.\(decimals)f%%", ratio * 100.0)
    }

    /// Formats a recording timestamp label as `yyyy-MM-dd HH:mm UTC`.
    public static func utcDateTime(_ date: Date) -> String {
        var secs = time_t(floor(date.timeIntervalSince1970))
        var tmValue = tm()
        guard gmtime_r(&secs, &tmValue) != nil else {
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
        return String(
            format: "%04d-%02d-%02d %02d:%02d UTC",
            Int(tmValue.tm_year) + 1900,
            Int(tmValue.tm_mon) + 1,
            Int(tmValue.tm_mday),
            Int(tmValue.tm_hour),
            Int(tmValue.tm_min)
        )
    }

    // MARK: - Lock-Free Fast ISO-8601 ASCII Parser

    private static func fastParseISO8601(_ raw: String) -> Date? {
        let bytes = Array(raw.utf8)
        // Minimum format: YYYY-MM-DDTHH:MM:SSZ (20 bytes)
        guard bytes.count >= 20 else { return nil }
        guard bytes[4] == 45, bytes[7] == 45, // '-'
              (bytes[10] == 84 || bytes[10] == 116 || bytes[10] == 32), // 'T' / 't' / ' '
              bytes[13] == 58, bytes[16] == 58 // ':'
        else {
            return nil
        }

        func digit(_ byte: UInt8) -> Int? {
            (byte >= 48 && byte <= 57) ? Int(byte - 48) : nil
        }
        func twoDigits(_ idx: Int) -> Int? {
            guard let d0 = digit(bytes[idx]), let d1 = digit(bytes[idx + 1]) else { return nil }
            return d0 * 10 + d1
        }
        func fourDigits(_ idx: Int) -> Int? {
            guard let a = twoDigits(idx), let b = twoDigits(idx + 2) else { return nil }
            return a * 100 + b
        }

        guard let year = fourDigits(0),
              let month = twoDigits(5), (1...12).contains(month),
              let day = twoDigits(8), (1...31).contains(day),
              let hour = twoDigits(11), (0...23).contains(hour),
              let minute = twoDigits(14), (0...59).contains(minute),
              let second = twoDigits(17), (0...59).contains(second) else {
            return nil
        }

        var cursor = 19
        var fractionalSeconds = 0.0
        if cursor < bytes.count && bytes[cursor] == 46 { // '.'
            cursor += 1
            var fracValue = 0.0
            var fracScale = 0.1
            var hasDigit = false
            while cursor < bytes.count, let d = digit(bytes[cursor]) {
                hasDigit = true
                if fracScale >= 1e-9 {
                    fracValue += Double(d) * fracScale
                    fracScale *= 0.1
                }
                cursor += 1
            }
            guard hasDigit else { return nil }
            fractionalSeconds = fracValue
        }

        guard cursor < bytes.count else { return nil }
        var tzOffsetSeconds = 0
        let tzByte = bytes[cursor]
        if tzByte == 90 || tzByte == 122 { // 'Z' or 'z'
            cursor += 1
            guard cursor == bytes.count else { return nil }
        } else if tzByte == 43 || tzByte == 45 { // '+' or '-'
            let sign = (tzByte == 43) ? 1 : -1
            cursor += 1
            guard cursor + 1 < bytes.count, let offH = twoDigits(cursor), (0...23).contains(offH) else {
                return nil
            }
            cursor += 2
            var offM = 0
            if cursor < bytes.count {
                if bytes[cursor] == 58 { cursor += 1 }
                guard cursor + 1 < bytes.count, let parsedM = twoDigits(cursor), (0...59).contains(parsedM) else {
                    return nil
                }
                offM = parsedM
                cursor += 2
            }
            guard cursor == bytes.count else { return nil }
            tzOffsetSeconds = sign * (offH * 3600 + offM * 60)
        } else {
            return nil
        }

        var tmVal = tm()
        tmVal.tm_year = Int32(year - 1900)
        tmVal.tm_mon = Int32(month - 1)
        tmVal.tm_mday = Int32(day)
        tmVal.tm_hour = Int32(hour)
        tmVal.tm_min = Int32(minute)
        tmVal.tm_sec = Int32(second)
        tmVal.tm_isdst = 0
        let epochSeconds = timegm(&tmVal)
        guard epochSeconds != -1 || year == 1969 else { return nil }
        return Date(timeIntervalSince1970: Double(epochSeconds - tzOffsetSeconds) + fractionalSeconds)
    }
}
