import Foundation

/// Recording-level summary metrics rendered across the 3 Dashboard metric cards.
public struct DashboardMetricsSummary: Sendable, Equatable {
    // Card 1: Cycles & Passes
    public let recordingCount: Int
    public let completeCycleCount: Int
    public let totalCycleCount: Int
    public let meanCyclesPerRecording: Double
    public let meanPassesPerCycle: Double
    public let meanCycleTimeS: Double
    public let cycleTimeStdDevS: Double

    // Card 2: Per-Equipment Idle Time (Raw merged contiguous spells, no allowance discount)
    public let excavatorIdleSpellCount: Int
    public let excavatorMeanIdleS: Double
    public let excavatorIdleStdDevS: Double
    public let truckIdleSpellCount: Int
    public let truckMeanIdleS: Double
    public let truckIdleStdDevS: Double

    // Card 3: Effective Equipment Utilization (excluding out_of_frame)
    public let excavatorEEU: Double?
    public let truckEEU: Double?

    public init(
        recordingCount: Int = 0,
        completeCycleCount: Int = 0,
        totalCycleCount: Int = 0,
        meanCyclesPerRecording: Double = 0,
        meanPassesPerCycle: Double = 0,
        meanCycleTimeS: Double = 0,
        cycleTimeStdDevS: Double = 0,
        excavatorIdleSpellCount: Int = 0,
        excavatorMeanIdleS: Double = 0,
        excavatorIdleStdDevS: Double = 0,
        truckIdleSpellCount: Int = 0,
        truckMeanIdleS: Double = 0,
        truckIdleStdDevS: Double = 0,
        excavatorEEU: Double? = nil,
        truckEEU: Double? = nil
    ) {
        self.recordingCount = recordingCount
        self.completeCycleCount = completeCycleCount
        self.totalCycleCount = totalCycleCount
        self.meanCyclesPerRecording = meanCyclesPerRecording
        self.meanPassesPerCycle = meanPassesPerCycle
        self.meanCycleTimeS = meanCycleTimeS
        self.cycleTimeStdDevS = cycleTimeStdDevS
        self.excavatorIdleSpellCount = excavatorIdleSpellCount
        self.excavatorMeanIdleS = excavatorMeanIdleS
        self.excavatorIdleStdDevS = excavatorIdleStdDevS
        self.truckIdleSpellCount = truckIdleSpellCount
        self.truckMeanIdleS = truckMeanIdleS
        self.truckIdleStdDevS = truckIdleStdDevS
        self.excavatorEEU = excavatorEEU
        self.truckEEU = truckEEU
    }

    public static let empty = DashboardMetricsSummary()
}

/// Pre-aggregated per-recording metrics contribution enabling `O(selected_recordings)` dashboard
/// recomputation without rescanning raw segments or allocating per-segment key strings.
public struct RecordingMetricsContribution: Sendable, Equatable {
    public let recordingId: String
    public let totalCycleCount: Int
    public let completeCycleCount: Int
    public let passCounts: [Double]
    public let cycleDurations: [Double]
    public let excavatorIdleDurations: [Double]
    public let truckIdleDurations: [Double]
    public let excavatorWorkS: Double
    public let excavatorInViewS: Double
    public let truckWorkS: Double
    public let truckInViewS: Double

    public init(
        recordingId: String,
        totalCycleCount: Int = 0,
        completeCycleCount: Int = 0,
        passCounts: [Double] = [],
        cycleDurations: [Double] = [],
        excavatorIdleDurations: [Double] = [],
        truckIdleDurations: [Double] = [],
        excavatorWorkS: Double = 0,
        excavatorInViewS: Double = 0,
        truckWorkS: Double = 0,
        truckInViewS: Double = 0
    ) {
        self.recordingId = recordingId
        self.totalCycleCount = totalCycleCount
        self.completeCycleCount = completeCycleCount
        self.passCounts = passCounts
        self.cycleDurations = cycleDurations
        self.excavatorIdleDurations = excavatorIdleDurations
        self.truckIdleDurations = truckIdleDurations
        self.excavatorWorkS = excavatorWorkS
        self.excavatorInViewS = excavatorInViewS
        self.truckWorkS = truckWorkS
        self.truckInViewS = truckInViewS
    }
}

/// Pure client-side recording-level metrics, cycle-duration extraction, and machine-role
/// helpers backing the Dashboard metric cards and 3-layer Data Explorer.
public enum TelemetryMetricsCalculator {
    /// Business Rule 4.3 uncertainty threshold highlighted in the Data Explorer.
    public static let defaultUncertaintyCutoff: Double = 0.70

    // MARK: - 3-Card Dashboard Metrics

    /// Computes recording-only cycle, pass, idle (mean & sample stdev), and EEU metrics across `recordings`.
    public static func computeDashboardMetrics(
        recordings: [RecordingDTO],
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO]
    ) -> DashboardMetricsSummary {
        let knownExcavators = resolveExcavatorMachineIds(cycles: cycles, segments: segments)
        let cyclesByRec = Dictionary(grouping: cycles, by: \.recordingId)
        let segmentsByRec = Dictionary(grouping: segments, by: \.recordingId)

        var recIds: Set<String> = []
        recIds.reserveCapacity(recordings.count)
        for rec in recordings { recIds.insert(rec.recordingId) }
        for recId in cyclesByRec.keys { recIds.insert(recId) }
        for recId in segmentsByRec.keys { recIds.insert(recId) }

        var contributions: [RecordingMetricsContribution] = []
        contributions.reserveCapacity(recIds.count)
        for recId in recIds {
            contributions.append(
                computeRecordingContribution(
                    recordingId: recId,
                    cycles: cyclesByRec[recId] ?? [],
                    segments: segmentsByRec[recId] ?? [],
                    additionalKnownExcavators: knownExcavators
                )
            )
        }

        return combineContributions(contributions, recordingCount: recordings.count)
    }

    /// Computes and caches a single recording's raw statistical contribution once when its telemetry arrives.
    public static func computeRecordingContribution(
        recordingId: String,
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        additionalKnownExcavators: Set<String> = []
    ) -> RecordingMetricsContribution {
        var passCounts: [Double] = []
        var cycleDurations: [Double] = []
        passCounts.reserveCapacity(cycles.count)
        cycleDurations.reserveCapacity(cycles.count)

        var completeCount = 0
        for cycle in cycles {
            guard cycle.cycleStatus == CycleStatus.complete.rawValue else { continue }
            completeCount += 1
            if let scoops = cycle.scoops, !scoops.isEmpty {
                passCounts.append(Double(scoops.count))
            }
            if let dur = extractTotalCycleS(cycle) {
                cycleDurations.append(dur)
            }
        }

        var excavatorMachines = resolveExcavatorMachineIds(cycles: cycles, segments: segments)
        if !additionalKnownExcavators.isEmpty {
            excavatorMachines.formUnion(additionalKnownExcavators)
        }

        // Single recording scope: machineId alone uniquely identifies each machine timeline (no string join allocations).
        var excIdleSpansByMachine: [String: [(startS: Double, endS: Double)]] = [:]
        var trkIdleSpansByMachine: [String: [(startS: Double, endS: Double)]] = [:]
        var excWorkS = 0.0
        var excInViewS = 0.0
        var trkWorkS = 0.0
        var trkInViewS = 0.0

        for seg in segments {
            let dur = seg.durationS
            guard dur > 0, let state = seg.typedState, state != .outOfFrame else { continue }

            if isExcavatorMachine(seg.machineId, knownExcavators: excavatorMachines) {
                excInViewS += dur
                switch state {
                case .loadingScoop, .facePrep:
                    excWorkS += dur
                case .idle:
                    excIdleSpansByMachine[seg.machineId, default: []].append((seg.startS, seg.endS))
                default:
                    break
                }
            } else {
                trkInViewS += dur
                switch state {
                case .spotting, .beingLoaded, .departing:
                    trkWorkS += dur
                case .idle, .queuingIdle:
                    trkIdleSpansByMachine[seg.machineId, default: []].append((seg.startS, seg.endS))
                default:
                    break
                }
            }
        }

        let excIdleDurations = mergedSpellDurations(from: excIdleSpansByMachine)
        let trkIdleDurations = mergedSpellDurations(from: trkIdleSpansByMachine)

        return RecordingMetricsContribution(
            recordingId: recordingId,
            totalCycleCount: cycles.count,
            completeCycleCount: completeCount,
            passCounts: passCounts,
            cycleDurations: cycleDurations,
            excavatorIdleDurations: excIdleDurations,
            truckIdleDurations: trkIdleDurations,
            excavatorWorkS: excWorkS,
            excavatorInViewS: excInViewS,
            truckWorkS: trkWorkS,
            truckInViewS: trkInViewS
        )
    }

    /// Combines precomputed per-recording contributions into a `DashboardMetricsSummary` with zero large array allocations.
    public static func combineContributions(
        _ contributions: [RecordingMetricsContribution],
        recordingCount: Int
    ) -> DashboardMetricsSummary {
        var totalCycles = 0
        var completeCycles = 0
        var passSum = 0.0
        var passCount = 0
        var durSum = 0.0
        var durCount = 0
        var excIdleSum = 0.0
        var excIdleCount = 0
        var trkIdleSum = 0.0
        var trkIdleCount = 0
        var excWorkS = 0.0
        var excInViewS = 0.0
        var trkWorkS = 0.0
        var trkInViewS = 0.0

        for c in contributions {
            totalCycles += c.totalCycleCount
            completeCycles += c.completeCycleCount

            for p in c.passCounts {
                passSum += p
                passCount += 1
            }
            for d in c.cycleDurations {
                durSum += d
                durCount += 1
            }
            for e in c.excavatorIdleDurations {
                excIdleSum += e
                excIdleCount += 1
            }
            for t in c.truckIdleDurations {
                trkIdleSum += t
                trkIdleCount += 1
            }

            excWorkS += c.excavatorWorkS
            excInViewS += c.excavatorInViewS
            trkWorkS += c.truckWorkS
            trkInViewS += c.truckInViewS
        }

        let meanCycles = recordingCount == 0 ? 0.0 : Double(completeCycles) / Double(recordingCount)
        let meanPasses = passCount > 0 ? passSum / Double(passCount) : 0.0
        let meanCycleTime = durCount > 0 ? durSum / Double(durCount) : 0.0
        let excMeanIdle = excIdleCount > 0 ? excIdleSum / Double(excIdleCount) : 0.0
        let trkMeanIdle = trkIdleCount > 0 ? trkIdleSum / Double(trkIdleCount) : 0.0

        var durSqSum = 0.0
        var excSqSum = 0.0
        var trkSqSum = 0.0

        if durCount >= 2 || excIdleCount >= 2 || trkIdleCount >= 2 {
            for c in contributions {
                if durCount >= 2 {
                    for d in c.cycleDurations {
                        let diff = d - meanCycleTime
                        durSqSum += diff * diff
                    }
                }
                if excIdleCount >= 2 {
                    for e in c.excavatorIdleDurations {
                        let diff = e - excMeanIdle
                        excSqSum += diff * diff
                    }
                }
                if trkIdleCount >= 2 {
                    for t in c.truckIdleDurations {
                        let diff = t - trkMeanIdle
                        trkSqSum += diff * diff
                    }
                }
            }
        }

        let cycleStdDev = durCount >= 2 ? sqrt(durSqSum / Double(durCount - 1)) : 0.0
        let excIdleStdDev = excIdleCount >= 2 ? sqrt(excSqSum / Double(excIdleCount - 1)) : 0.0
        let trkIdleStdDev = trkIdleCount >= 2 ? sqrt(trkSqSum / Double(trkIdleCount - 1)) : 0.0

        let excEEU: Double? = excInViewS > 0 ? min(1.0, max(0.0, excWorkS / excInViewS)) : nil
        let trkEEU: Double? = trkInViewS > 0 ? min(1.0, max(0.0, trkWorkS / trkInViewS)) : nil

        return DashboardMetricsSummary(
            recordingCount: recordingCount,
            completeCycleCount: completeCycles,
            totalCycleCount: totalCycles,
            meanCyclesPerRecording: meanCycles,
            meanPassesPerCycle: meanPasses,
            meanCycleTimeS: meanCycleTime,
            cycleTimeStdDevS: cycleStdDev,
            excavatorIdleSpellCount: excIdleCount,
            excavatorMeanIdleS: excMeanIdle,
            excavatorIdleStdDevS: excIdleStdDev,
            truckIdleSpellCount: trkIdleCount,
            truckMeanIdleS: trkMeanIdle,
            truckIdleStdDevS: trkIdleStdDev,
            excavatorEEU: excEEU,
            truckEEU: trkEEU
        )
    }

    // MARK: - Cycle Phase Duration Extractors

    public static func extractQueueS(_ cycle: HaulCycleDTO) -> Double? {
        if let queue = cycle.queueTimeS, queue >= 0 {
            return queue
        }
        if let arrive = cycle.tArriveS, let spot = cycle.tSpotS, spot >= arrive {
            return spot - arrive
        }
        return nil
    }

    public static func extractSpotS(_ cycle: HaulCycleDTO) -> Double? {
        guard let spot = cycle.tSpotS, let start = cycle.tLoadStartS, start >= spot else { return nil }
        return start - spot
    }

    public static func extractLoadS(_ cycle: HaulCycleDTO) -> Double? {
        guard let start = cycle.tLoadStartS, let end = cycle.tLoadEndS, end >= start else { return nil }
        return end - start
    }

    public static func extractDepartS(_ cycle: HaulCycleDTO) -> Double? {
        guard let end = cycle.tLoadEndS, let depart = cycle.tDepartS, depart >= end else { return nil }
        return depart - end
    }

    public static func extractTotalCycleS(_ cycle: HaulCycleDTO) -> Double? {
        if let arrive = cycle.tArriveS, let depart = cycle.tDepartS, depart >= arrive {
            return depart - arrive
        }
        if let spot = cycle.tSpotS, let depart = cycle.tDepartS, depart >= spot {
            return depart - spot
        }
        return nil
    }

    // MARK: - Machine Role Classification & Statistics Helpers

    public static func resolveExcavatorMachineIds(
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO]
    ) -> Set<String> {
        var ids = Set(cycles.map(\.excavatorId))
        for seg in segments {
            if seg.typedState == .loadingScoop || seg.typedState == .facePrep {
                ids.insert(seg.machineId)
            }
        }
        return ids
    }

    public static func isExcavatorMachine(_ id: String, knownExcavators: Set<String>) -> Bool {
        if knownExcavators.contains(id) { return true }
        let upper = id.uppercased()
        if upper.hasPrefix("EXC") { return true }
        return upper.hasPrefix("E") && upper.count > 1 && upper.dropFirst().allSatisfy(\.isNumber)
    }

    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        return values.reduce(0.0, +) / Double(values.count)
    }

    public static func sampleStdDev(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0.0 }
        let avg = mean(values)
        let sumSq = values.reduce(0.0) { $0 + ($1 - avg) * ($1 - avg) }
        return sqrt(sumSq / Double(values.count - 1))
    }

    private static func mergedSpellDurations(
        from spansByMachine: [String: [(startS: Double, endS: Double)]]
    ) -> [Double] {
        var durations: [Double] = []
        for spans in spansByMachine.values {
            let valid = spans
                .filter { $0.endS > $0.startS }
                .sorted {
                    if $0.startS != $1.startS { return $0.startS < $1.startS }
                    return $0.endS < $1.endS
                }
            guard var current = valid.first else { continue }
            for next in valid.dropFirst() {
                if next.startS <= current.endS + 0.001 {
                    current.endS = max(current.endS, next.endS)
                } else {
                    durations.append(current.endS - current.startS)
                    current = next
                }
            }
            durations.append(current.endS - current.startS)
        }
        return durations
    }
}
