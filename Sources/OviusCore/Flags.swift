import Foundation

/// What is unusual about a run, or worth checking in it: a figure outside what its cluster's other runs (or every
/// other run) usually show, and things in its own footage that make its figures less sure.
public struct RunFlags: Equatable {
    public var unusual: [Unusual]
    public var checks: [Check]

    public static let none = RunFlags(unusual: [], checks: [])

    public var count: Int { unusual.count + checks.count }
    public var isEmpty: Bool { count == 0 }

    /// A figure outside what is usual, against the cluster's other runs, every other run, or both.
    public struct Unusual: Equatable {
        public var kpi: Kpi
        public var value: Double
        /// Above what is usual (else below).
        public var higher: Bool
        /// Whether that is better or worse (or neither, for a figure with no better way).
        public var verdict: Comparison.Verdict
        public var against: [Usual]
    }

    /// What a figure usually is, over some runs: their median, and the range outside which one is unusual.
    public struct Usual: Equatable {
        public enum Scope: Equatable {
            /// The run's cluster's other runs.
            case cluster
            /// Every other run, of any cluster.
            case overall
        }

        public var scope: Scope
        public var runs: Int
        public var median: Double
        public var low: Double
        public var high: Double
    }

    /// Something in the run's own footage or figures to look at.
    public enum Check: Equatable {
        /// Cameras that failed or were stopped: the figures are of the others.
        case camerasMissing(Int)
        /// Cameras that saw no excavator.
        case noExcavator([String])
        /// Cameras that saw excavators but no load cycles.
        case noCycles([String])
        /// More than half the cycles are estimated: their load times are drawn, not seen.
        case mostlyEstimated(estimated: Int, of: Int)
        /// Cameras whose footage is under half the longest's: the cameras do not cover the same period.
        case shortFootage([String])

        /// The cameras it names, if any.
        public var cameras: [String] {
            switch self {
            case .noExcavator(let c), .noCycles(let c), .shortFootage(let c): c
            case .camerasMissing, .mostlyEstimated: []
            }
        }
    }

    /// The figures checked for being unusual: every rate, time and share (material per hour goes with cycles per hour).
    public static let checked: [Kpi] = [.cyclesPerH, .loadS, .queueS, .excavatorIdleS, .truckIdleS, .excavatorUtilPct, .truckUtilPct]
    /// Fewer other runs than this say nothing of what is usual.
    public static let leastRuns = 4
    /// Outside the quartiles by more than this many times their spread is unusual (the box plot's whiskers)...
    public static let fence = 1.5
    /// ...and only when that far from the median: a tenth of it, or 5 points for a share.
    public static let leastChange = 0.10
    public static let leastPoints = 5.0

    /// The run's flags: `total` and its `cameras`' rows, `missing` cameras that failed or were stopped, against the
    /// cluster's other runs and every other run.
    public static func of(total: TeamFigures, cameras: [(name: String, figures: TeamFigures)], missing: Int,
                          cluster: [TeamFigures], overall: [TeamFigures]) -> RunFlags {
        var unusual: [Unusual] = []
        for kpi in checked {
            guard let value = kpi.value(total) else { continue }
            let against = [(Usual.Scope.cluster, cluster), (.overall, overall)].compactMap { scope, runs in
                usual(runs.compactMap(kpi.value), scope: scope, percent: kpi.isPercent).flatMap { u in
                    isUnusual(value, u, percent: kpi.isPercent) ? u : nil
                }
            }
            guard let first = against.first else { continue }
            let higher = value > first.median
            let verdict: Comparison.Verdict = kpi.higherIsBetter.map { $0 == higher ? .better : .worse } ?? .neither
            unusual.append(Unusual(kpi: kpi, value: value, higher: higher, verdict: verdict, against: against))
        }

        var checks: [Check] = []
        if missing > 0 { checks.append(.camerasMissing(missing)) }
        let blind = cameras.filter { $0.figures.excavators == 0 }.map(\.name)
        if !blind.isEmpty { checks.append(.noExcavator(blind)) }
        let idle = cameras.filter { $0.figures.excavators > 0 && $0.figures.cycles == 0 }.map(\.name)
        if !idle.isEmpty { checks.append(.noCycles(idle)) }
        if total.cycles > 0, 2 * total.estimated > total.cycles { checks.append(.mostlyEstimated(estimated: total.estimated, of: total.cycles)) }
        let longest = cameras.map(\.figures.durationH).max() ?? 0
        let short = cameras.filter { longest > 0 && $0.figures.durationH < longest / 2 }.map(\.name)
        if !short.isEmpty { checks.append(.shortFootage(short)) }
        return RunFlags(unusual: unusual, checks: checks)
    }

    /// What `values` usually are: their median and the quartiles widened by `fence` times their spread (a share kept
    /// within 0–100); nil for fewer than `leastRuns`.
    public static func usual(_ values: [Double], scope: Usual.Scope, percent: Bool) -> Usual? {
        guard values.count >= leastRuns else { return nil }
        let sorted = values.sorted()
        let q1 = quantile(sorted, 0.25), q3 = quantile(sorted, 0.75)
        var low = q1 - fence * (q3 - q1), high = q3 + fence * (q3 - q1)
        if percent {
            low = max(0, low)
            high = min(100, high)
        }
        return Usual(scope: scope, runs: values.count, median: quantile(sorted, 0.5), low: low, high: high)
    }

    static func isUnusual(_ value: Double, _ u: Usual, percent: Bool) -> Bool {
        let far = percent ? leastPoints : leastChange * abs(u.median)
        return (value < u.low || value > u.high) && abs(value - u.median) >= far
    }

    /// The `q` quantile of sorted values, between the two nearest (as a spreadsheet's QUARTILE.INC).
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        let at = q * Double(sorted.count - 1)
        let below = Int(at.rounded(.down)), above = min(sorted.count - 1, below + 1)
        return sorted[below] + (at - Double(below)) * (sorted[above] - sorted[below])
    }
}
