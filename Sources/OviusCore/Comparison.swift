import Foundation

/// The team's figures the dashboard compares from one cluster analysis to the others.
public enum Kpi: String, CaseIterable, Identifiable {
    case cyclesPerH, volumePerH, loadS, queueS, excavatorIdleS, truckIdleS, excavatorUtilPct, truckUtilPct

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cyclesPerH: "Load cycles per hour"
        case .volumePerH: "Material moved per hour"
        case .loadS: "Mean load time"
        case .queueS: "Mean queue time"
        case .excavatorIdleS: "Excavator idle time"
        case .truckIdleS: "Dump truck idle time"
        case .excavatorUtilPct: "Excavator utilisation"
        case .truckUtilPct: "Dump truck utilisation"
        }
    }

    public var help: String {
        switch self {
        case .cyclesPerH: "Load cycles, observed and estimated, for each hour of footage."
        case .volumePerH: "Load cycles × the volume of a load (Settings), for each hour of footage."
        case .loadS: "A truck's loading, from the excavator's first pass to its last."
        case .queueS: "Of the trucks that queued: standing in the loading area before spotting."
        case .excavatorIdleS: "Each excavator's time idle (not loading, digging or clearing the face) in the footage."
        case .truckIdleS: "Each cycle's queue time, a truck that did not queue counting as none."
        case .excavatorUtilPct: "Working (loading, digging, clearing the face), of the time each excavator was in view."
        case .truckUtilPct: "Spotting and loading, of the time trucks spent in the loading area."
        }
    }

    /// Whether more is better; nil for neither.
    public var higherIsBetter: Bool? {
        switch self {
        case .cyclesPerH, .volumePerH, .excavatorUtilPct, .truckUtilPct: true
        case .queueS, .excavatorIdleS, .truckIdleS: false
        case .loadS: nil
        }
    }

    /// A share, compared in points rather than as a change of itself.
    public var isPercent: Bool { self == .excavatorUtilPct || self == .truckUtilPct }

    public func value(_ f: TeamFigures) -> Double? {
        switch self {
        case .cyclesPerH: f.durationH > 0 ? Double(f.cycles) / f.durationH : nil
        case .volumePerH: f.durationH > 0 ? f.volumeM3 / f.durationH : nil
        case .loadS: f.loadSMean
        case .queueS: f.queueSMean
        case .excavatorIdleS: f.excavatorIdleSMean
        case .truckIdleS: f.truckIdleSMean
        case .excavatorUtilPct: f.excavatorUtilPct
        case .truckUtilPct: f.truckUtilPct
        }
    }
}

/// An analysis against the average of the others it is compared with.
public struct Comparison: Equatable {
    /// How many analyses the average is of.
    public var count: Int
    public var hours: Double
    public var average: [Kpi: Double]

    /// Each figure's average over `earlier`, weighted by the hours of footage each one had (so cycles per hour is all
    /// the cycles over all the hours); nil without any.
    public static func of(_ earlier: [TeamFigures]) -> Comparison? {
        let seen = earlier.filter { $0.durationH > 0 }
        guard !seen.isEmpty else { return nil }
        var average: [Kpi: Double] = [:]
        for kpi in Kpi.allCases {
            let pairs = seen.compactMap { f in kpi.value(f).map { ($0, f.durationH) } }
            let hours = pairs.reduce(0) { $0 + $1.1 }
            if hours > 0 { average[kpi] = pairs.reduce(0) { $0 + $1.0 * $1.1 } / hours }
        }
        return Comparison(count: seen.count, hours: seen.reduce(0) { $0 + $1.durationH }, average: average)
    }

    public func change(_ kpi: Kpi, _ figures: TeamFigures) -> Change? {
        guard let now = kpi.value(figures), let then = average[kpi] else { return nil }
        return Change.between(now, then, inPoints: kpi.isPercent, higherIsBetter: kpi.higherIsBetter)
    }

    public struct Change: Equatable {
        /// Percentage points for a share; percent of the average otherwise.
        public var by: Double
        public var inPoints: Bool
        public var average: Double
        public var verdict: Verdict

        /// `now` against `then`: in points for a share, else as a percent of `then` (nil when `then` is 0). Under a
        /// point, or 2%, is the same.
        public static func between(_ now: Double, _ then: Double, inPoints: Bool, higherIsBetter: Bool?) -> Change? {
            let by: Double
            if inPoints {
                by = now - then
            } else if then != 0 {
                by = 100 * (now - then) / then
            } else {
                return nil
            }
            let small = abs(by) < (inPoints ? 1 : 2)
            let better = higherIsBetter.map { $0 == (by > 0) }
            return Change(by: by, inPoints: inPoints, average: then, verdict: small ? .same : better.map { $0 ? .better : .worse } ?? .neither)
        }
    }

    public enum Verdict {
        case better, worse, same, neither
    }
}

/// Many cluster analyses together: their counts and volume added up, and their figures averaged by hours.
public struct Overview: Equatable {
    public var analyses: Int
    /// Hours of footage: of the periods the clusters' cameras covered, and every camera's added up.
    public var hours: Double
    public var cameraH: Double
    public var cycles: Int
    public var observed: Int
    public var estimated: Int
    public var volumeM3: Double
    /// Each figure's average; nil without any hours.
    public var average: Comparison?

    public static func of(_ metrics: [ClusterMetrics]) -> Overview {
        Overview(
            analyses: metrics.count,
            hours: metrics.reduce(0) { $0 + $1.total.durationH },
            cameraH: metrics.reduce(0) { $0 + $1.summary.cameraH },
            cycles: metrics.reduce(0) { $0 + $1.total.cycles },
            observed: metrics.reduce(0) { $0 + $1.total.observed },
            estimated: metrics.reduce(0) { $0 + $1.total.estimated },
            volumeM3: metrics.reduce(0) { $0 + $1.total.volumeM3 },
            average: Comparison.of(metrics.map(\.total))
        )
    }
}

/// A stretch of time the dashboard shows: a day, a week or a month of footage, or all of it.
public struct Period: Hashable, Comparable {
    public enum Kind: String, CaseIterable, Identifiable {
        case day, week, month, all
        public var id: String { rawValue }
    }

    public var kind: Kind
    public var start: Date
    public var end: Date

    public static let all = Period(kind: .all, start: .distantPast, end: .distantFuture)

    /// The day, week or month `date` falls in.
    public static func containing(_ date: Date, _ kind: Kind, calendar: Calendar = .current) -> Period {
        let unit: Calendar.Component
        switch kind {
        case .day: unit = .day
        case .week: unit = .weekOfYear
        case .month: unit = .month
        case .all: return .all
        }
        guard let span = calendar.dateInterval(of: unit, for: date) else { return .all }
        return Period(kind: kind, start: span.start, end: span.end)
    }

    /// The periods of `kind` that hold any of `dates`, the earliest first.
    public static func holding(_ dates: [Date], _ kind: Kind, calendar: Calendar = .current) -> [Period] {
        Array(Set(dates.map { containing($0, kind, calendar: calendar) })).sorted()
    }

    public func contains(_ date: Date) -> Bool { start <= date && date < end }

    public static func < (a: Period, b: Period) -> Bool { a.start < b.start }
}
