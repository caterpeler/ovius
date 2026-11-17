import Foundation

/// Immutable, `Sendable` snapshot of client-side `AppSettings` constants used by pure metric calculations.
public struct TelemetryCalculationConfig: Sendable, Equatable {
    public let meanPayloadM3: Double
    public let struckPayloadM3: Double
    public let heapedPayloadM3: Double
    public let idleThresholdS: Double
    public let shiftEdgeWindowMin: Int
    public let shiftStartHours: [String]
    public let breakWindows: [String]
    public let uncertaintyConfidenceCutoff: Double

    public init(
        meanPayloadM3: Double = 51.1,
        struckPayloadM3: Double = 42.1,
        heapedPayloadM3: Double = 60.1,
        idleThresholdS: Double = 300.0,
        shiftEdgeWindowMin: Int = 60,
        shiftStartHours: [String] = ["06:00"],
        breakWindows: [String] = ["12:00-13:00"],
        uncertaintyConfidenceCutoff: Double = 0.70
    ) {
        self.meanPayloadM3 = meanPayloadM3
        self.struckPayloadM3 = struckPayloadM3
        self.heapedPayloadM3 = heapedPayloadM3
        self.idleThresholdS = idleThresholdS
        self.shiftEdgeWindowMin = shiftEdgeWindowMin
        self.shiftStartHours = shiftStartHours
        self.breakWindows = breakWindows
        self.uncertaintyConfidenceCutoff = uncertaintyConfidenceCutoff
    }

    @MainActor
    public init(settings: AppSettings) {
        self.init(
            meanPayloadM3: settings.meanPayloadM3,
            struckPayloadM3: settings.struckPayloadM3,
            heapedPayloadM3: settings.heapedPayloadM3,
            idleThresholdS: Double(settings.idleThresholdS),
            shiftEdgeWindowMin: settings.shiftEdgeWindowMin,
            shiftStartHours: settings.shiftStartHours,
            breakWindows: settings.breakWindows,
            uncertaintyConfidenceCutoff: 0.70
        )
    }

    /// Parses `"HH:mm"` strings into minutes since 00:00 UTC.
    public var parsedShiftStartMinutes: [Int] {
        shiftStartHours.compactMap(Self.parseHourMinute)
    }

    /// Parses `"HH:mm-HH:mm"` strings into `(startMinute, endMinute)` pairs since 00:00 UTC.
    public var parsedBreakMinuteRanges: [(start: Int, end: Int)] {
        breakWindows.compactMap { window in
            let parts = window.split(separator: "-").map(String.init)
            guard parts.count == 2,
                  let start = Self.parseHourMinute(parts[0]),
                  let end = Self.parseHourMinute(parts[1]),
                  end > start else {
                return nil
            }
            return (start, end)
        }
    }

    private static func parseHourMinute(_ raw: String) -> Int? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }
}
