import Foundation
import SwiftUI

// MARK: - Data the dashboard shows

/// One bucket pass of a load: how long it took, the load so far, and how full the truck is estimated to be.
public struct FleetPass: Identifiable, Hashable, Sendable {
    public let number: Int
    public let durationS: Double
    public let cumulativeS: Double
    /// Share of the cycle's passes done by this one (not a measured bucket fill).
    public let fillPct: Int
    public let confidence: Double?
    public var id: Int { number }
}

/// One truck's visit to an excavator: when in the video, who, and how long it queued, spotted and was loaded.
public struct FleetCycle: Identifiable, Hashable, Sendable {
    public let id: String
    public let recordingId: String
    public let seq: Int
    /// Seconds into its recording's video.
    public let offsetS: Double
    public let truck: String
    public let excavator: String
    public let queueS: Double
    public let spotS: Double
    public let loadS: Double
    /// Loaded to gone; 0 when unknown.
    public var departS: Double = 0
    public let passes: [FleetPass]
    /// The detector's least sure moment of the visit; nil when unknown.
    public let confidence: Double?
    /// Whether the truck was seen from arrival to departure; an incomplete visit is listed but not judged.
    public var isComplete = true

    public var totalS: Double { queueS + spotS + loadS + departS }
    public var offsetMin: Double { offsetS / 60 }
    public var shortCode: String { String(format: "#%03d", seq) }
    public var isUncertain: Bool { (confidence ?? 1) < FleetAnalysis.uncertainBelow }
}

/// A machine seen in a recording, with its utilisation and idle time there.
public struct FleetMachine: Identifiable, Hashable, Sendable {
    public let id: String
    public let isExcavator: Bool
    public let eeu: Double
    public let meanIdleS: Double
}

/// A recording and its figures: where, how long, its cycles, and its machines.
public struct FleetRecording: Identifiable, Hashable, Sendable {
    public let id: String
    public let camera: String
    public let section: String
    public let location: String
    public let fileName: String
    public let date: Date?
    public let durationS: Double
    public let totalCycles: Int
    public let completeCycles: Int
    public let meanPasses: Double
    public let meanCycleS: Double
    public let cycleSdS: Double
    public let meanQueueS: Double
    public let meanLoadS: Double
    public let meanSpotS: Double
    public let excIdleMeanS: Double
    public let excIdleSdS: Double
    public let truckIdleMeanS: Double
    public let truckIdleSdS: Double
    public let excEEU: Double
    public let truckEEU: Double
    public let machines: [FleetMachine]
    public let cycles: [FleetCycle]
    public var meanDepartS: Double = 0

    public var durationMin: Double { durationS / 60 }
    /// Where it is, in words: the location, led by its section unless the location already names it.
    public var place: String {
        location.localizedCaseInsensitiveContains(section) ? location : "\(section) · \(location)"
    }
    public var cyclesPerHour: Double { durationS > 0 ? Double(completeCycles) / (durationS / 3600) : 0 }
    public var excavators: [FleetMachine] { machines.filter(\.isExcavator) }
    public var trucks: [FleetMachine] { machines.filter { !$0.isExcavator } }
}

/// What a cluster's supervisor wants each figure to be; each is optional. A figure without a target is judged
/// against its own spread instead.
public struct FleetTargets: Equatable, Sendable {
    /// Least excavator EEU, in percent.
    public var excEEU: Double?
    /// Least truck EEU, in percent.
    public var truckEEU: Double?
    /// Longest a truck should queue, in seconds.
    public var maxQueueS: Double?
    /// Longest a cycle should take, in seconds.
    public var maxCycleS: Double?

    public init(excEEU: Double? = nil, truckEEU: Double? = nil, maxQueueS: Double? = nil, maxCycleS: Double? = nil) {
        self.excEEU = excEEU
        self.truckEEU = truckEEU
        self.maxQueueS = maxQueueS
        self.maxCycleS = maxCycleS
    }

    public var isEmpty: Bool { excEEU == nil && truckEEU == nil && maxQueueS == nil && maxCycleS == nil }
    /// Cycles are judged against targets when a queue or cycle target is set; otherwise by their spread.
    public var judgesCycles: Bool { maxQueueS != nil || maxCycleS != nil }

    /// The set targets in words: "Excavator EEU ≥ 65%", "Queue ≤ 35s"…
    public var phrases: [String] {
        var out: [String] = []
        if let excEEU { out.append("Excavator EEU ≥ \(Int(excEEU))%") }
        if let truckEEU { out.append("Truck EEU ≥ \(Int(truckEEU))%") }
        if let maxQueueS { out.append("Queue ≤ \(FleetAnalysis.dur(maxQueueS))") }
        if let maxCycleS { out.append("Cycle ≤ \(FleetAnalysis.dur(maxCycleS))") }
        return out
    }
}

/// Whether the selection is judged against its cluster's targets, or only against its own spread.
public enum BenchmarkMode: Hashable, Sendable {
    case statistical, targets
}

// MARK: - Analysis

/// The dashboard's figures, worked out from the selected recordings: totals and means, a one-line diagnosis, the
/// shift timeline, each machine's share, and each cycle judged against targets or its recording's spread.
public enum FleetAnalysis {
    /// A cycle the detector is less sure of than this is uncertain.
    public static let uncertainBelow = 0.70
    /// A cycle further than this many standard deviations above its recording's mean is an outlier.
    public static let outlierSigmas = 1.5

    // MARK: Totals

    public struct Aggregate: Sendable {
        public var clipCount = 0
        /// Complete cycles: the ones every figure is worked out from.
        public var totalCycles = 0
        public var incompleteCycles = 0
        public var totalDurationMin = 0.0
        public var cyclesPerHour = 0.0
        public var cyclesPerClip = 0.0
        public var meanPasses = 0.0
        public var meanCycleS = 0.0
        public var cycleSdS = 0.0
        public var meanQueueS = 0.0
        public var meanLoadS = 0.0
        public var meanSpotS = 0.0
        public var meanDepartS = 0.0
        public var excIdleMeanS = 0.0
        public var excIdleSdS = 0.0
        public var truckIdleMeanS = 0.0
        public var truckIdleSdS = 0.0
        public var excEEU = 0.0
        public var truckEEU = 0.0
        public var excCount = 0
        public var truckCount = 0
        public var maxDurationMin = 0.0
        public var minDurationMin = 0.0
        public var hasMixedDurations: Bool { maxDurationMin != minDurationMin }
        public var isBunching: Bool { excIdleSdS > excIdleMeanS }
    }

    /// Cycle figures weighted by each recording's cycles; idle and utilisation by its footage.
    public static func aggregate(_ recs: [FleetRecording]) -> Aggregate {
        var a = Aggregate()
        guard !recs.isEmpty else { return a }
        let cycles = Double(recs.reduce(0) { $0 + $1.completeCycles })
        let minutes = recs.reduce(0) { $0 + $1.durationMin }
        func byCycles(_ f: (FleetRecording) -> Double) -> Double {
            cycles > 0 ? recs.reduce(0) { $0 + f($1) * Double($1.completeCycles) } / cycles : 0
        }
        func byMinutes(_ f: (FleetRecording) -> Double) -> Double {
            minutes > 0 ? recs.reduce(0) { $0 + f($1) * $1.durationMin } / minutes : 0
        }
        a.clipCount = recs.count
        a.totalCycles = Int(cycles)
        a.incompleteCycles = recs.reduce(0) { $0 + $1.totalCycles - $1.completeCycles }
        a.totalDurationMin = minutes
        a.cyclesPerHour = minutes > 0 ? cycles / (minutes / 60) : 0
        a.cyclesPerClip = cycles / Double(recs.count)
        a.meanPasses = byCycles(\.meanPasses)
        a.meanCycleS = byCycles(\.meanCycleS)
        a.cycleSdS = byCycles { $0.cycleSdS * $0.cycleSdS }.squareRoot()
        a.meanQueueS = byCycles(\.meanQueueS)
        a.meanLoadS = byCycles(\.meanLoadS)
        a.meanSpotS = byCycles(\.meanSpotS)
        a.meanDepartS = byCycles(\.meanDepartS)
        a.excIdleMeanS = byMinutes(\.excIdleMeanS)
        a.excIdleSdS = byMinutes { $0.excIdleSdS * $0.excIdleSdS }.squareRoot()
        a.truckIdleMeanS = byMinutes(\.truckIdleMeanS)
        a.truckIdleSdS = byMinutes { $0.truckIdleSdS * $0.truckIdleSdS }.squareRoot()
        a.excEEU = byMinutes(\.excEEU)
        a.truckEEU = byMinutes(\.truckEEU)
        // Counted per recording: a label like "T1" names a machine within one video, not across videos.
        a.excCount = recs.reduce(0) { $0 + $1.excavators.count }
        a.truckCount = recs.reduce(0) { $0 + $1.trucks.count }
        a.maxDurationMin = recs.map(\.durationMin).max() ?? 0
        a.minDurationMin = recs.map(\.durationMin).min() ?? 0
        return a
    }

    /// As `aggregate(_:)`, with the figures the app's metrics pool across every cycle and idle spell (rather than
    /// weighting each recording's) taken from them.
    public static func aggregate(_ recs: [FleetRecording], pooled m: DashboardMetricsSummary) -> Aggregate {
        var a = aggregate(recs)
        guard m.recordingCount > 0, m.completeCycleCount > 0 || m.excavatorEEU != nil else { return a }
        a.meanPasses = m.meanPassesPerCycle
        a.meanCycleS = m.meanCycleTimeS
        a.cycleSdS = m.cycleTimeStdDevS
        a.excIdleMeanS = m.excavatorMeanIdleS
        a.excIdleSdS = m.excavatorIdleStdDevS
        a.truckIdleMeanS = m.truckMeanIdleS
        a.truckIdleSdS = m.truckIdleStdDevS
        if let e = m.excavatorEEU { a.excEEU = e * 100 }
        if let e = m.truckEEU { a.truckEEU = e * 100 }
        return a
    }

    // MARK: Diagnosis

    public struct Diagnosis: Sendable {
        public enum Severity: Sendable { case critical, warning, insight, healthy }
        public let severity: Severity
        public let title: String
        public let detail: String
    }

    // MARK: Targets, recording by recording

    /// How one target fares across the picked recordings, each judged on its own figures: an average of several
    /// would hide a recording that misses.
    public struct TargetCheck: Identifiable, Sendable {
        public struct Miss: Sendable {
            public let camera: String
            /// "25.0% excavator EEU (≥ 60%)", "queue 3m 25s (≤ 45s)".
            public let detail: String
            /// How far off, as a share of the target: 0.5 is half the target away.
            public let gap: Double
        }
        public let phrase: String
        public let met: Int
        public let judged: Int
        public let misses: [Miss]
        public var id: String { phrase }
        public var allMet: Bool { met == judged }
    }

    /// One check per target that is set. A recording without cycles isn't judged on queue or cycle time.
    public static func targetChecks(_ recs: [FleetRecording], targets t: FleetTargets) -> [TargetCheck] {
        func check(_ phrase: String, _ judged: [FleetRecording], meets: (FleetRecording) -> Bool,
                   miss: (FleetRecording) -> (String, Double)) -> TargetCheck {
            let missing = judged.filter { !meets($0) }
            return TargetCheck(phrase: phrase, met: judged.count - missing.count, judged: judged.count,
                               misses: missing.map { r in let (d, g) = miss(r); return .init(camera: r.camera, detail: d, gap: g) })
        }
        let withCycles = recs.filter { $0.completeCycles > 0 }
        var checks: [TargetCheck] = []
        if let v = t.excEEU {
            checks.append(check("Excavator EEU ≥ \(Int(v))%", recs, meets: { $0.excEEU >= v },
                                miss: { ("\(pct($0.excEEU)) excavator EEU (≥ \(Int(v))%)", (v - $0.excEEU) / v) }))
        }
        if let v = t.truckEEU {
            checks.append(check("Truck EEU ≥ \(Int(v))%", recs, meets: { $0.truckEEU >= v },
                                miss: { ("\(pct($0.truckEEU)) truck EEU (≥ \(Int(v))%)", (v - $0.truckEEU) / v) }))
        }
        if let v = t.maxQueueS {
            checks.append(check("Queue ≤ \(dur(v))", withCycles, meets: { $0.meanQueueS <= v },
                                miss: { ("queue \(dur($0.meanQueueS)) (≤ \(dur(v)))", ($0.meanQueueS - v) / v) }))
        }
        if let v = t.maxCycleS {
            checks.append(check("Cycle ≤ \(dur(v))", withCycles, meets: { $0.meanCycleS <= v },
                                miss: { ("cycle \(dur($0.meanCycleS)) (≤ \(dur(v)))", ($0.meanCycleS - v) / v) }))
        }
        return checks
    }

    /// Several recordings against the cluster's targets: how many miss, and the worst of them, each by its own figures.
    private static func perRecordingDiagnosis(_ recs: [FleetRecording], targets t: FleetTargets) -> Diagnosis {
        let checks = targetChecks(recs, targets: t)
        var byCamera: [String: [TargetCheck.Miss]] = [:]
        for miss in checks.flatMap(\.misses) { byCamera[miss.camera, default: []].append(miss) }
        guard !byCamera.isEmpty else {
            return Diagnosis(severity: .healthy, title: "Every recording on target",
                             detail: "All \(recs.count) recordings meet each target set for this cluster: " + t.phrases.joined(separator: ", ") + ".")
        }
        let ranked = byCamera.sorted { ($0.value.map(\.gap).max() ?? 0) > ($1.value.map(\.gap).max() ?? 0) }
        let shown = ranked.prefix(3).map { camera, misses in
            let sorted = misses.sorted { $0.gap > $1.gap }
            return "\(camera): \(sorted[0].detail)" + (sorted.count > 1 ? " and \(sorted.count - 1) other miss\(sorted.count == 2 ? "" : "es")" : "")
        }
        let more = ranked.count > 3 ? (ranked.count == 4 ? " 1 more recording misses too." : " \(ranked.count - 3) more recordings miss too.") : ""
        let far = checks.flatMap(\.misses).contains { $0.gap > 0.25 }
        return Diagnosis(severity: far ? .critical : .warning,
                         title: "\(byCamera.count) of \(recs.count) recordings below target",
                         detail: shown.joined(separator: "; ") + "." + more)
    }

    /// The one thing most worth saying about the selection: against the cluster's targets when it has some (each
    /// recording on its own when there are several), otherwise against its own spread.
    public static func diagnosis(_ s: Aggregate, recordings recs: [FleetRecording], targets t: FleetTargets) -> Diagnosis {
        let gap = s.truckEEU - s.excEEU
        let worst = recs.max { $0.meanQueueS < $1.meanQueueS }
        if !t.isEmpty, recs.count > 1 {
            return perRecordingDiagnosis(recs, targets: t)
        }
        if !t.isEmpty {
            let excDelta = t.excEEU.map { s.excEEU - $0 }
            let truckDelta = t.truckEEU.map { s.truckEEU - $0 }
            let queueDelta = t.maxQueueS.map { s.meanQueueS - $0 }
            let cycleDelta = t.maxCycleS.map { s.meanCycleS - $0 }
            var misses: [String] = []
            if let excDelta, excDelta < 0, let target = t.excEEU {
                misses.append("excavator EEU is \(pct(s.excEEU)), \(abs(excDelta).formatted(.number.precision(.fractionLength(1)))) pts under \(Int(target))%")
            }
            if let truckDelta, truckDelta < 0, let target = t.truckEEU {
                misses.append("truck EEU is \(pct(s.truckEEU)), under \(Int(target))%")
            }
            if let queueDelta, queueDelta > 0, let target = t.maxQueueS {
                misses.append("the mean queue is \(dur(s.meanQueueS)), over \(dur(target))")
            }
            if let cycleDelta, cycleDelta > 0, let target = t.maxCycleS {
                misses.append("the mean cycle is \(dur(s.meanCycleS)), over \(dur(target))")
            }
            guard !misses.isEmpty else {
                return Diagnosis(severity: .healthy, title: "On target",
                                 detail: "Every target set for this cluster is met: " + t.phrases.joined(separator: ", ") + ".")
            }
            let far = (excDelta ?? 0) < -15 || (truckDelta ?? 0) < -15 || (queueDelta ?? 0) > 20 || (cycleDelta ?? 0) > 60
            var detail = misses.joined(separator: "; ").capitalizedFirst + "."
            if s.clipCount > 1, let worst, t.maxQueueS != nil {
                detail += " Most queueing: \(worst.camera) (\(worst.location)), \(dur(worst.meanQueueS)) per truck."
            } else if s.isBunching {
                detail += " Excavator idle varies (σ \(dur(s.excIdleSdS))) more than it lasts (\(dur(s.excIdleMeanS))): trucks arrive in waves."
            }
            return Diagnosis(severity: far ? .critical : .warning, title: far ? "Below target" : "Close to target", detail: detail)
        }
        if s.excIdleSdS > s.excIdleMeanS * 1.15, gap > 25 {
            return Diagnosis(severity: .insight, title: "Trucks arrive in waves",
                             detail: "Excavator idle varies \((s.excIdleSdS / max(1, s.excIdleMeanS)).formatted(.number.precision(.fractionLength(1))))× more (σ \(dur(s.excIdleSdS))) than it lasts on average (\(dur(s.excIdleMeanS))), and trucks are busy \(gap.formatted(.number.precision(.fractionLength(1)))) pts more than excavators: excavators sit starved between bunches of trucks.")
        }
        if s.clipCount > 1, let worst, worst.meanQueueS > s.meanQueueS * 1.45 {
            return Diagnosis(severity: .warning, title: "\(worst.camera) queues far more",
                             detail: "\(worst.camera) (\(worst.location), \(hm(worst.durationMin))) averages \(dur(worst.meanQueueS)) of queue, \((worst.meanQueueS / max(1, s.meanQueueS)).formatted(.number.precision(.fractionLength(1))))× the selection's \(dur(s.meanQueueS)).")
        }
        return Diagnosis(severity: .healthy, title: "Cycles are steady",
                         detail: "\(s.cyclesPerHour.formatted(.number.precision(.fractionLength(1)))) cycles an hour over \(hm(s.totalDurationMin)) of footage, and excavator idle varies little (σ \(dur(s.excIdleSdS))).")
    }

    // MARK: Timeline

    public struct Bin: Identifiable, Sendable {
        public let index: Int
        public let startMin: Double
        public let endMin: Double
        public let activeClips: Int
        public let cycleCount: Int
        /// Cycles per hour of footage that was recording in this bin: a shorter clip ending is no drop.
        public let normalizedRate: Double
        public let meanQueueS: Double
        public var id: Int { index }
        /// Time into the video, never a clock time: "0h", "1h 30m", "45m".
        public var label: String { elapsed(startMin) }
        public var rangeLabel: String { "\(elapsed(startMin)) – \(elapsed(endMin)) in" }
    }

    public struct Timeline: Sendable {
        public let bins: [Bin]
        public let binMin: Double
        public let maxRate: Double
        public let maxQueueS: Double
        public let outlierQueueS: Double
    }

    /// The bin size for videos up to this long: an hour each for long ones, 30 or 15 minutes for shorter.
    public static func binMinutes(forLongest maxMin: Double) -> Double {
        maxMin <= 180 ? 15 : (maxMin <= 360 ? 30 : 60)
    }

    /// Bins from the start of the video (or videos) to the end of the longest, each with its cycles' rate and mean
    /// queue. Time is measured from each video's own start: a video's clock can't be trusted, as it may be trimmed.
    public static func timeline(_ recs: [FleetRecording], targets: FleetTargets, binMin fixed: Double? = nil) -> Timeline {
        let maxMin = recs.map(\.durationMin).max() ?? 0
        let binMin = fixed ?? binMinutes(forLongest: maxMin)
        let count = max(1, Int((maxMin / binMin).rounded(.up)))
        let bins = (0..<count).map { k -> Bin in
            let start = Double(k) * binMin, end = min(maxMin, Double(k + 1) * binMin)
            var active = 0, hours = 0.0
            for r in recs where r.durationMin > start {
                active += 1
                hours += (min(r.durationMin, end) - start) / 60
            }
            let cycles = recs.flatMap { $0.cycles.filter { $0.isComplete && $0.offsetMin >= start && $0.offsetMin < end } }
            return Bin(index: k, startMin: start, endMin: end, activeClips: active, cycleCount: cycles.count,
                       normalizedRate: hours > 0 ? Double(cycles.count) / hours : 0,
                       meanQueueS: cycles.isEmpty ? 0 : cycles.reduce(0) { $0 + $1.queueS } / Double(cycles.count))
        }
        let queues = bins.map(\.meanQueueS)
        let mean = queues.reduce(0, +) / Double(max(1, queues.count))
        let sd = (queues.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, queues.count))).squareRoot()
        return Timeline(bins: bins, binMin: binMin, maxRate: max(10, bins.map(\.normalizedRate).max() ?? 0),
                        maxQueueS: max(targets.maxQueueS.map { $0 * 1.3 } ?? 45, queues.max() ?? 0),
                        outlierQueueS: mean + 1.25 * sd)
    }

    // MARK: Fleet

    public struct MachineRow: Identifiable, Sendable {
        public let id: String
        public let isExcavator: Bool
        public let eeu: Double
        public let cycles: Int
        public let meanLoadS: Double
        public let meanQueueS: Double
    }

    /// Each machine of one recording: its utilisation, and its cycles (within the picked bin, when one is). Machines
    /// are never merged across recordings, since a label like "T1" only names a machine within its own video.
    public static func fleet(_ rec: FleetRecording, within bin: Bin?) -> (excavators: [MachineRow], trucks: [MachineRow]) {
        let cycles = rec.cycles.filter { c in c.isComplete && bin.map { c.offsetMin >= $0.startMin && c.offsetMin < $0.endMin } ?? true }
        var excavators: [MachineRow] = [], trucks: [MachineRow] = []
        for m in rec.machines {
            let mine = cycles.filter { m.isExcavator ? $0.excavator == m.id : $0.truck == m.id }
            let n = Double(max(1, mine.count))
            let row = MachineRow(id: m.id, isExcavator: m.isExcavator, eeu: m.eeu, cycles: mine.count,
                                 meanLoadS: mine.reduce(0) { $0 + $1.loadS } / n, meanQueueS: mine.reduce(0) { $0 + $1.queueS } / n)
            if m.isExcavator { excavators.append(row) } else { trucks.append(row) }
        }
        return (excavators, trucks)
    }

    // MARK: Cycles

    public struct JudgedCycle: Identifiable, Sendable {
        public let cycle: FleetCycle
        public let isOutlier: Bool
        public let breachesTarget: Bool
        public let isFlagged: Bool
        public let isHighQueue: Bool
        public var id: String { cycle.id }
    }

    /// A recording's cycles, each judged: over target when the cluster has a queue or cycle target, otherwise an
    /// outlier (beyond mean + 1.5σ of the recording's cycle or queue time). Incomplete visits are never flagged.
    public static func judge(_ cycles: [FleetCycle], targets t: FleetTargets) -> [JudgedCycle] {
        func threshold(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(max(1, values.count))
            let sd = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, values.count))).squareRoot()
            return mean + outlierSigmas * sd
        }
        let complete = cycles.filter(\.isComplete)
        let totalLimit = threshold(complete.map(\.totalS)), queueLimit = threshold(complete.map(\.queueS))
        return cycles.map { c in
            guard c.isComplete else {
                return JudgedCycle(cycle: c, isOutlier: false, breachesTarget: false, isFlagged: false, isHighQueue: false)
            }
            let outlier = c.totalS > totalLimit || c.queueS > queueLimit
            let breach = (t.maxQueueS.map { c.queueS > $0 } ?? false) || (t.maxCycleS.map { c.totalS > $0 } ?? false)
            return JudgedCycle(cycle: c, isOutlier: outlier, breachesTarget: breach,
                               isFlagged: t.judgesCycles ? breach : outlier,
                               isHighQueue: t.maxQueueS.map { c.queueS > $0 } ?? (c.queueS > queueLimit))
        }
    }

    // MARK: Recording status

    public enum RecordingStatus: Sendable { case breach, outlier, watch, balanced }

    /// How a recording looks at a glance: below target (or unusual), worth watching, or balanced.
    public static func status(of r: FleetRecording, targets t: FleetTargets) -> RecordingStatus {
        guard t.isEmpty else {
            let far = (t.excEEU.map { r.excEEU < $0 - 15 } ?? false) || (t.maxQueueS.map { r.meanQueueS > $0 * 1.4 } ?? false)
            if far { return .breach }
            let miss = (t.excEEU.map { r.excEEU < $0 } ?? false) || (t.truckEEU.map { r.truckEEU < $0 } ?? false)
                || (t.maxQueueS.map { r.meanQueueS > $0 } ?? false) || (t.maxCycleS.map { r.meanCycleS > $0 } ?? false)
            return miss ? .watch : .balanced
        }
        if r.excIdleSdS > r.excIdleMeanS * 1.25 || r.meanQueueS > 75 { return .outlier }
        return r.meanQueueS > 45 ? .watch : .balanced
    }

    // MARK: Words

    /// 2m 23s, or 45s.
    public static func dur(_ s: Double) -> String {
        let n = Int(s.rounded())
        return n < 60 ? "\(n)s" : "\(n / 60)m \(String(format: "%02d", n % 60))s"
    }

    /// 12h 00m.
    public static func hm(_ minutes: Double) -> String {
        let n = Int(minutes.rounded())
        return "\(n / 60)h \(String(format: "%02d", n % 60))m"
    }

    /// 01h 10m into a video.
    public static func offset(_ minutes: Double) -> String {
        let n = Int(minutes)
        return "\(String(format: "%02d", n / 60))h \(String(format: "%02d", n % 60))m"
    }

    /// Time into a video, for an axis: "0h", "2h", "1h 30m", "45m".
    public static func elapsed(_ minutes: Double) -> String {
        let n = Int(minutes.rounded())
        if n == 0 { return "0h" }
        if n < 60 { return "\(n)m" }
        return n % 60 == 0 ? "\(n / 60)h" : "\(n / 60)h \(n % 60)m"
    }

    public static func pct(_ x: Double) -> String { "\(x.formatted(.number.precision(.fractionLength(1))))%" }

    static func signed(_ x: Double) -> String { (x >= 0 ? "+" : "") + x.formatted(.number.precision(.fractionLength(1))) }
}

/// The cycle phases' colours, the same in every bar, legend and card.
public enum FleetPalette {
    public static let queue = Color.dynamic(light: Color(hex: 0xE2A43A), dark: Color(hex: 0xD7A245))
    public static let load = Color.dynamic(light: Color(hex: 0x5C9A86), dark: Color(hex: 0x6FB59D))
    public static let spot = Color.dynamic(light: Color(hex: 0xB4B4AF), dark: Color(hex: 0x6E6E6A))
    public static let depart = Color.dynamic(light: Color(hex: 0xD9D9D4), dark: Color(hex: 0x4A4A47))
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
