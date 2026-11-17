import Foundation

/// Pure client-side analytics engine implementing the Zero-Backend-Math invariant.
/// Transforms raw cloud DTOs (`RecordingDTO`, `HaulCycleDTO`, `StateSegmentDTO`) and `TelemetryCalculationConfig`
/// into `SectionMetricsSnapshot` and `ClusterBaselineStats` values.
public enum TelemetryMetricsCalculator {

    // MARK: - Public API

    /// Computes KPI metrics, histograms, hourly curves, Gantt items, and audit rows for one section.
    /// When segments span a narrower sub-window than cycles (e.g., recent 24h segments paired with a 7-14d cycle horizon),
    /// pass `segmentScopeRecordings` and `segmentScopeCycles` so segment-derived denominators stay 100% aligned.
    public static func computeSectionSnapshot(
        sectionId: String,
        sectionName: String,
        recordings: [RecordingDTO],
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        config: TelemetryCalculationConfig,
        segmentScopeRecordings: [RecordingDTO]? = nil,
        segmentScopeCycles: [HaulCycleDTO]? = nil,
        todStartS: Double? = nil,
        todEndS: Double? = nil,
        todBaseMinuteUTC: Int? = nil
    ) -> SectionMetricsSnapshot {
        let recordingDates = buildRecordingDateMap(recordings)
        let segRecordings = segmentScopeRecordings ?? recordings
        let segRecordingDates = segmentScopeRecordings == nil ? recordingDates : buildRecordingDateMap(segRecordings)

        let cycleBoundsByRec = buildClipBoundsMap(
            recordings: recordings,
            recordingDates: recordingDates,
            todStartS: todStartS,
            todEndS: todEndS,
            todBaseMinuteUTC: todBaseMinuteUTC
        )
        let segBoundsByRec = segmentScopeRecordings == nil
            ? cycleBoundsByRec
            : buildClipBoundsMap(
                recordings: segRecordings,
                recordingDates: segRecordingDates,
                todStartS: todStartS,
                todEndS: todEndS,
                todBaseMinuteUTC: todBaseMinuteUTC
            )

        let slicedCycles = Self.filterCycles(
            cycles,
            todStartS: todStartS,
            todEndS: todEndS,
            boundsByRecordingId: cycleBoundsByRec
        )
        let slicedSegments = Self.clipSegments(
            segments,
            todStartS: todStartS,
            todEndS: todEndS,
            boundsByRecordingId: segBoundsByRec
        )
        let rawSegCycles = segmentScopeCycles ?? cycles
        let segCycles = Self.filterCycles(
            rawSegCycles,
            todStartS: todStartS,
            todEndS: todEndS,
            boundsByRecordingId: segBoundsByRec
        )
        let totalCameraHours = computeTotalCameraHours(
            recordings: recordings,
            cycles: slicedCycles,
            segments: slicedSegments,
            boundsByRecordingId: cycleBoundsByRec,
            todStartS: todStartS,
            todEndS: todEndS
        )

        let windowOverlapsBreak = doesActiveSliceOverlapBreak(
            recordings: recordings,
            recordingDates: recordingDates,
            boundsByRecordingId: cycleBoundsByRec,
            config: config,
            todStartS: todStartS,
            todEndS: todEndS
        )

        let completeCycles = slicedCycles.filter { $0.cycleStatus == CycleStatus.complete.rawValue }
        let incompleteCycles = slicedCycles.filter { $0.cycleStatus != CycleStatus.complete.rawValue }

        let phaseTotals = computePhaseMetrics(completeCycles: completeCycles)
        let arrivalMetrics = computeArrivalMetrics(
            cycles: slicedCycles,
            unclippedCycles: cycles,
            boundsByRecordingId: cycleBoundsByRec,
            todStartS: todStartS,
            todEndS: todEndS,
            totalCameraHours: totalCameraHours,
            recordingDates: recordingDates,
            pocketServiceTimeS: phaseTotals.pocketServiceTimeS,
            windowOverlapsBreak: windowOverlapsBreak,
            config: config
        )
        let segmentSummary = analyzeSegments(
            segments: slicedSegments,
            unclippedSegments: segments,
            cycles: segCycles,
            boundsByRecordingId: segBoundsByRec,
            recordingDates: segRecordingDates,
            todStartS: todStartS,
            todEndS: todEndS,
            windowOverlapsBreak: windowOverlapsBreak,
            config: config
        )

        let completeCount = completeCycles.count
        let totalCount = slicedCycles.count
        let totalVolumeM3 = Double(completeCount) * config.meanPayloadM3
        let struckVolumeM3 = Double(completeCount) * config.struckPayloadM3
        let heapedVolumeM3 = Double(completeCount) * config.heapedPayloadM3
        let volumetricRateM3Hr = totalCameraHours > 0 ? totalVolumeM3 / totalCameraHours : 0.0
        let incompleteRatio = totalCount > 0 ? Double(incompleteCycles.count) / Double(totalCount) : 0.0

        let hourlySeries = buildHourlySeries(
            recordings: recordings,
            cycles: slicedCycles,
            segmentRecordings: segRecordings,
            segments: slicedSegments,
            recordingDates: recordingDates,
            segRecordingDates: segRecordingDates,
            cycleBoundsByRec: cycleBoundsByRec,
            segBoundsByRec: segBoundsByRec,
            config: config,
            todStartS: todStartS,
            todEndS: todEndS
        )
        let hourlySlumpConcentration = computeHourlySlumpConcentration(from: hourlySeries)

        let metricValues: [MetricKey: Double] = [
            .avgQueueTimeS: phaseTotals.avgQueueS,
            .avgSpotTimeS: phaseTotals.avgSpotS,
            .avgLoadDurationS: phaseTotals.avgLoadS,
            .avgDepartureLagS: phaseTotals.avgDepartS,
            .excavatorHangRatio: segmentSummary.excavatorHangRatio,
            .trueIdleExcessS: segmentSummary.maxIdleExcessS,
            .volumetricRateM3Hr: volumetricRateM3Hr,
            .truckArrivalRateHr: arrivalMetrics.ratePerHour,
            .shiftEdgeIdleRatio: segmentSummary.shiftEdgeIdleRatio,
            .breakWindowIdleExcessS: max(segmentSummary.breakIdleExcessS, arrivalMetrics.breakGapExcessS),
            .hourlySlumpConcentration: hourlySlumpConcentration,
            .incompleteCycleRatio: incompleteRatio,
            .outOfFrameRatio: segmentSummary.outOfFrameRatio,
        ]

        let ganttItems = buildGanttItems(segments: slicedSegments, cutoff: config.uncertaintyConfidenceCutoff)
        let auditRows = buildCycleAuditRows(cycles: segCycles, segments: slicedSegments, cutoff: config.uncertaintyConfidenceCutoff)
        let headwaySamples = buildArrivalHeadwaySamples(
            cycles: slicedCycles,
            segments: slicedSegments,
            maxSamples: 90
        )

        return SectionMetricsSnapshot(
            sectionId: sectionId,
            sectionName: sectionName,
            recordingCount: recordings.count,
            totalCameraHours: totalCameraHours,
            totalCycleCount: totalCount,
            completeCycleCount: completeCount,
            incompleteCycleCount: incompleteCycles.count,
            totalSegmentCount: slicedSegments.count,
            uncertainSegmentCount: segmentSummary.uncertainCount,
            totalVolumeM3: totalVolumeM3,
            struckVolumeM3: struckVolumeM3,
            heapedVolumeM3: heapedVolumeM3,
            avgCycleDurationS: phaseTotals.avgTotalCycleS,
            totalPostAllowanceIdleS: segmentSummary.totalIdleExcessS,
            metricValues: metricValues,
            queueTimeHistogram: buildHistogram(
                values: completeCycles.compactMap { extractQueueS($0) },
                binSizeS: 30,
                maxBins: 10
            ),
            interArrivalGapHistogram: buildHistogram(
                values: arrivalMetrics.interArrivalGapsS,
                binSizeS: 120,
                maxBins: 10
            ),
            hourlySeries: hourlySeries,
            ganttSegments: ganttItems,
            cycleAuditRows: auditRows,
            pocketServiceTimeS: phaseTotals.pocketServiceTimeS,
            queueDepthSummary: arrivalMetrics.queueDepthSummary,
            excavatorPocketSplit: segmentSummary.pocketSplit,
            arrivalHeadwaySamples: headwaySamples,
            gapCoeffOfVariation: arrivalMetrics.gapCoeffOfVariation,
            topIdleSpells: segmentSummary.topIdleSpells,
            syncedStoppageWindowCount: segmentSummary.syncedStoppageWindowCount
        )
    }

    /// Builds Gantt timeline items, concurrency audit metrics, conflict track, and Rule 4.2/4.3 audit rows for a single recording drilldown.
    public static func extractDrilldown(
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        config: TelemetryCalculationConfig
    ) -> (
        ganttSegments: [GanttSegmentItem],
        cycleAuditRows: [CycleAuditRow],
        audit: GanttConcurrencyAudit,
        conflicts: [GanttConflictInterval]
    ) {
        let gantt = buildGanttItems(segments: segments, cutoff: config.uncertaintyConfidenceCutoff)
        let auditRows = buildCycleAuditRows(cycles: cycles, segments: segments, cutoff: config.uncertaintyConfidenceCutoff)
        let (audit, conflicts) = buildGanttConcurrencyAudit(cycles: cycles, segments: segments)
        return (gantt, auditRows, audit, conflicts)
    }

    /// Overload preserving 2-tuple signature for existing callers/tests if needed.
    public static func extractDrilldownSummary(
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        config: TelemetryCalculationConfig
    ) -> (ganttSegments: [GanttSegmentItem], cycleAuditRows: [CycleAuditRow]) {
        (
            buildGanttItems(segments: segments, cutoff: config.uncertaintyConfidenceCutoff),
            buildCycleAuditRows(cycles: cycles, segments: segments, cutoff: config.uncertaintyConfidenceCutoff)
        )
    }

    /// Computes Cluster Horizon `μ` and `σ` plus hourly baseline averages and `±1σ` dispersion across sibling sections.
    public static func computeClusterBaseline(
        clusterId: String,
        sectionSnapshots: [SectionMetricsSnapshot]
    ) -> ClusterBaselineStats {
        let byId = Dictionary(uniqueKeysWithValues: sectionSnapshots.map { ($0.sectionId, $0) })
        var means: [MetricKey: Double] = [:]
        var stdDevs: [MetricKey: Double] = [:]

        for key in MetricKey.allCases {
            let values = sectionSnapshots.map { $0.value(for: key) }
            let stats = meanAndStdDev(values)
            means[key] = stats.mean
            stdDevs[key] = stats.stdDev
        }

        let hourlyBaselines = (0..<24).map { hour -> HourlyMetricPoint in
            let matching = sectionSnapshots.compactMap { snap in
                snap.hourlySeries.first { $0.hourUTC == hour }
            }
            let loadStats = meanAndStdDev(matching.map(\.avgLoadDurationS))
            let queueStats = meanAndStdDev(matching.map(\.avgQueueTimeS))
            let hangStats = meanAndStdDev(matching.map(\.excavatorHangRatio))
            return HourlyMetricPoint(
                hourUTC: hour,
                volumetricRateM3Hr: mean(matching.map(\.volumetricRateM3Hr)),
                truckArrivalRateHr: mean(matching.map(\.truckArrivalRateHr)),
                avgLoadDurationS: loadStats.mean,
                avgQueueTimeS: queueStats.mean,
                avgSpotDurationS: mean(matching.map(\.avgSpotDurationS)),
                avgDepartureLagS: mean(matching.map(\.avgDepartureLagS)),
                excavatorHangRatio: hangStats.mean,
                delayDurationS: mean(matching.map(\.delayDurationS)),
                delayPerCamHr: mean(matching.map(\.delayPerCamHr)),
                avgLoadStdDevS: loadStats.stdDev,
                avgQueueStdDevS: queueStats.stdDev,
                excavatorHangStdDev: hangStats.stdDev,
                isShiftEdge: matching.first?.isShiftEdge ?? false,
                isBreakWindow: matching.first?.isBreakWindow ?? false
            )
        }

        return ClusterBaselineStats(
            clusterId: clusterId,
            sectionSnapshots: byId,
            means: means,
            stdDevs: stdDevs,
            hourlyBaselines: hourlyBaselines
        )
    }

    // MARK: - Private Calculation Helpers

    private struct PhaseMetricsSummary {
        let avgQueueS: Double
        let avgSpotS: Double
        let avgLoadS: Double
        let avgDepartS: Double
        let avgTotalCycleS: Double
        let pocketServiceTimeS: Double
    }

    private struct ArrivalMetricsSummary {
        let ratePerHour: Double
        let interArrivalGapsS: [Double]
        let breakGapExcessS: Double
        let queueDepthSummary: QueueDepthSummary
        let gapCoeffOfVariation: Double
    }

    private struct SegmentAnalysisSummary {
        let uncertainCount: Int
        let outOfFrameRatio: Double
        let excavatorHangRatio: Double
        let maxIdleExcessS: Double
        let totalIdleExcessS: Double
        let shiftEdgeIdleRatio: Double
        let breakIdleExcessS: Double
        let pocketSplit: ExcavatorPocketSplit
        let topIdleSpells: [IdleSpellSummary]
        let syncedStoppageWindowCount: Int
    }

    private static func buildRecordingDateMap(_ recordings: [RecordingDTO]) -> [String: Date] {
        var map: [String: Date] = [:]
        map.reserveCapacity(recordings.count)
        for rec in recordings {
            if let parsed = OviusFormat.parseISODate(rec.timestamp) {
                map[rec.recordingId] = parsed
            }
        }
        return map
    }

    public static func buildClipBoundsMap(
        recordings: [RecordingDTO],
        recordingDates: [String: Date],
        todStartS: Double?,
        todEndS: Double?,
        todBaseMinuteUTC: Int?
    ) -> [String: (lo: Double, hi: Double)] {
        guard todStartS != nil || todEndS != nil else { return [:] }
        var map: [String: (lo: Double, hi: Double)] = [:]
        map.reserveCapacity(recordings.count)
        for rec in recordings {
            let bounds = clipBounds(
                for: rec,
                baseDate: recordingDates[rec.recordingId],
                todStartS: todStartS,
                todEndS: todEndS,
                todBaseMinuteUTC: todBaseMinuteUTC
            )
            map[rec.recordingId] = bounds
        }
        return map
    }

    public static func clipBounds(
        for recording: RecordingDTO,
        baseDate: Date? = nil,
        todStartS: Double?,
        todEndS: Double?,
        todBaseMinuteUTC: Int?
    ) -> (lo: Double, hi: Double) {
        let dur = max(0.0, recording.durationS)
        guard todStartS != nil || todEndS != nil else { return (0.0, dur) }

        guard let todBaseMinuteUTC,
              let startDate = baseDate ?? OviusFormat.parseISODate(recording.timestamp),
              dur > 0 else {
            let lo = max(0.0, todStartS ?? 0.0)
            let hi = min(dur, todEndS ?? dur)
            return (lo, max(lo, hi))
        }

        let recStartSecOfDay = OviusFormat.utcSecondsSinceMidnight(for: startDate)
        let wallStartSec = Double(todBaseMinuteUTC) * 60.0 + (todStartS ?? 0.0)
        let wallEndSec = Double(todBaseMinuteUTC) * 60.0 + (todEndS ?? 43_200.0)

        for dayShift in [-86_400.0, 0.0, 86_400.0] {
            let rawLo = (wallStartSec + dayShift) - recStartSecOfDay
            let rawHi = (wallEndSec + dayShift) - recStartSecOfDay
            let lo = max(0.0, rawLo)
            let hi = min(dur, rawHi)
            if hi > lo {
                return (lo, hi)
            }
        }
        return (0.0, 0.0)
    }

    public static func filterCycles(
        _ cycles: [HaulCycleDTO],
        todStartS: Double?,
        todEndS: Double?,
        boundsByRecordingId: [String: (lo: Double, hi: Double)] = [:]
    ) -> [HaulCycleDTO] {
        guard todStartS != nil || todEndS != nil else { return cycles }
        let fallbackLo = todStartS ?? 0.0
        let fallbackHi = todEndS ?? Double.greatestFiniteMagnitude
        return cycles.filter { cycle in
            let bounds = boundsByRecordingId[cycle.recordingId] ?? (fallbackLo, fallbackHi)
            guard bounds.hi > bounds.lo else { return false }
            let anchor = cycle.tLoadStartS ?? cycle.tArriveS ?? cycle.tSpotS ?? 0.0
            return anchor >= bounds.lo && anchor <= bounds.hi
        }
    }

    public static func clipSegments(
        _ segments: [StateSegmentDTO],
        todStartS: Double?,
        todEndS: Double?,
        boundsByRecordingId: [String: (lo: Double, hi: Double)] = [:]
    ) -> [StateSegmentDTO] {
        guard todStartS != nil || todEndS != nil else { return segments }
        let fallbackLo = todStartS ?? 0.0
        let fallbackHi = todEndS ?? Double.greatestFiniteMagnitude
        return segments.compactMap { seg in
            let bounds = boundsByRecordingId[seg.recordingId] ?? (fallbackLo, fallbackHi)
            guard bounds.hi > bounds.lo else { return nil }
            let s = max(seg.startS, bounds.lo)
            let e = min(seg.endS, bounds.hi)
            guard e > s else { return nil }
            if s == seg.startS && e == seg.endS { return seg }
            return StateSegmentDTO(
                segmentId: seg.segmentId,
                recordingId: seg.recordingId,
                cycleId: seg.cycleId,
                cycleSortKey: seg.cycleSortKey,
                machineId: seg.machineId,
                scoopNumber: seg.scoopNumber,
                state: seg.state,
                startS: s,
                endS: e,
                confidence: seg.confidence
            )
        }
    }

    public static func computeEffectiveCameraHours(
        for recording: RecordingDTO,
        todStartS: Double?,
        todEndS: Double?,
        todBaseMinuteUTC: Int? = nil
    ) -> Double {
        let dur = max(0.0, recording.durationS)
        guard dur > 0 else { return 0.0 }
        let bounds = clipBounds(
            for: recording,
            todStartS: todStartS,
            todEndS: todEndS,
            todBaseMinuteUTC: todBaseMinuteUTC
        )
        return max(0.0, bounds.hi - bounds.lo) / 3600.0
    }

    private static func computeTotalCameraHours(
        recordings: [RecordingDTO],
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        boundsByRecordingId: [String: (lo: Double, hi: Double)] = [:],
        todStartS: Double? = nil,
        todEndS: Double? = nil
    ) -> Double {
        if !recordings.isEmpty {
            let recHours = recordings.reduce(0.0) { total, rec in
                if let b = boundsByRecordingId[rec.recordingId] {
                    return total + max(0.0, b.hi - b.lo) / 3600.0
                }
                return total + computeEffectiveCameraHours(for: rec, todStartS: todStartS, todEndS: todEndS)
            }
            if recHours > 0 || (todStartS != nil || todEndS != nil) {
                return recHours
            }
        }
        // Fallback when raw recording rows were omitted: infer span per recording_id from segments or cycles.
        var spans: [String: (minS: Double, maxS: Double)] = [:]
        for seg in segments {
            let cur = spans[seg.recordingId] ?? (seg.startS, seg.endS)
            spans[seg.recordingId] = (min(cur.minS, seg.startS), max(cur.maxS, seg.endS))
        }
        for cycle in cycles {
            let points = [cycle.tArriveS, cycle.tSpotS, cycle.tLoadStartS, cycle.tLoadEndS, cycle.tDepartS].compactMap { $0 }
            guard let lo = points.min(), let hi = points.max() else { continue }
            let cur = spans[cycle.recordingId] ?? (lo, hi)
            spans[cycle.recordingId] = (min(cur.minS, lo), max(cur.maxS, hi))
        }
        let inferredS = spans.values.reduce(0.0) { $0 + max(0, $1.maxS - $1.minS) }
        return inferredS > 0 ? inferredS / 3600.0 : 0.0
    }

    private static func doesActiveSliceOverlapBreak(
        recordings: [RecordingDTO],
        recordingDates: [String: Date],
        boundsByRecordingId: [String: (lo: Double, hi: Double)],
        config: TelemetryCalculationConfig,
        todStartS: Double?,
        todEndS: Double?
    ) -> Bool {
        let breakRanges = config.parsedBreakMinuteRanges
        guard !breakRanges.isEmpty else { return false }
        guard todStartS != nil || todEndS != nil else { return true }

        for rec in recordings {
            guard let startDate = recordingDates[rec.recordingId] else { continue }
            let b = boundsByRecordingId[rec.recordingId] ?? (max(0.0, todStartS ?? 0.0), min(rec.durationS, todEndS ?? rec.durationS))
            guard b.hi > b.lo else { continue }
            let sliceStart = startDate.addingTimeInterval(b.lo)
            let sliceEnd = startDate.addingTimeInterval(b.hi)
            if computeDailyRangeOverlap(startDate: sliceStart, endDate: sliceEnd, minuteRanges: breakRanges) > 0 {
                return true
            }
        }
        return recordings.isEmpty
    }

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

    private static func computePhaseMetrics(completeCycles: [HaulCycleDTO]) -> PhaseMetricsSummary {
        let q = mean(completeCycles.compactMap(extractQueueS))
        let s = mean(completeCycles.compactMap(extractSpotS))
        let l = mean(completeCycles.compactMap(extractLoadS))
        let d = mean(completeCycles.compactMap(extractDepartS))
        let t = mean(completeCycles.compactMap(extractTotalCycleS))
        let serviceSamples: [Double] = completeCycles.compactMap { cyc in
            guard let spot = extractSpotS(cyc), let load = extractLoadS(cyc), let dep = extractDepartS(cyc) else {
                return nil
            }
            return spot + load + dep
        }
        let service = serviceSamples.isEmpty ? (s + l + d) : mean(serviceSamples)
        return PhaseMetricsSummary(
            avgQueueS: q,
            avgSpotS: s,
            avgLoadS: l,
            avgDepartS: d,
            avgTotalCycleS: t,
            pocketServiceTimeS: service
        )
    }

    private static func computeArrivalMetrics(
        cycles: [HaulCycleDTO],
        unclippedCycles: [HaulCycleDTO],
        boundsByRecordingId: [String: (lo: Double, hi: Double)],
        todStartS: Double?,
        todEndS: Double?,
        totalCameraHours: Double,
        recordingDates: [String: Date],
        pocketServiceTimeS: Double,
        windowOverlapsBreak: Bool,
        config: TelemetryCalculationConfig
    ) -> ArrivalMetricsSummary {
        let byRecording = Dictionary(grouping: cycles, by: \.recordingId)
        var gaps: [Double] = []
        var arrivalCount = 0

        var qDepthZero = 0
        var qDepthOne = 0
        var qDepthTwoPlus = 0
        var maxDepth = 0

        for (_, group) in byRecording {
            let arrivalOffsets = group.compactMap { $0.tArriveS ?? $0.tSpotS ?? $0.tLoadStartS }.sorted()
            arrivalCount += arrivalOffsets.count
            if arrivalOffsets.count > 1 {
                for idx in 1..<arrivalOffsets.count {
                    let delta = arrivalOffsets[idx] - arrivalOffsets[idx - 1]
                    if delta >= 0 {
                        gaps.append(delta)
                    }
                }
            }

            // Concurrency depth at each cycle's arrival inside active recording + excavator
            let byExc = Dictionary(grouping: group, by: \.excavatorId)
            for (_, excGroup) in byExc {
                let windows: [(arrive: Double, spot: Double)] = excGroup.compactMap { cyc in
                    guard let arr = cyc.tArriveS ?? cyc.tSpotS else { return nil }
                    let sp = cyc.tSpotS ?? cyc.tLoadStartS ?? arr
                    return (arr, max(arr, sp))
                }
                for (i, current) in windows.enumerated() {
                    var aheadInQueue = 0
                    for (j, other) in windows.enumerated() where i != j {
                        if other.arrive <= current.arrive && current.arrive < other.spot {
                            aheadInQueue += 1
                        }
                    }
                    maxDepth = max(maxDepth, aheadInQueue)
                    if aheadInQueue == 0 {
                        qDepthZero += 1
                    } else if aheadInQueue == 1 {
                        qDepthOne += 1
                    } else {
                        qDepthTwoPlus += 1
                    }
                }
            }
        }

        // Break overrun check preserves gaps starting/spanning active break slice into post-break return.
        let breakRanges = config.parsedBreakMinuteRanges
        var maxBreakGapExcessS = 0.0
        if windowOverlapsBreak && !breakRanges.isEmpty {
            let fallbackLo = todStartS ?? 0.0
            let fallbackHi = todEndS ?? Double.greatestFiniteMagnitude
            let unclippedByRec = Dictionary(grouping: unclippedCycles, by: \.recordingId)

            for (recordingId, group) in unclippedByRec {
                guard let baseDate = recordingDates[recordingId] else { continue }
                let bounds = boundsByRecordingId[recordingId] ?? (fallbackLo, fallbackHi)
                guard bounds.hi > bounds.lo else { continue }

                let arrivalOffsets = group.compactMap { $0.tArriveS ?? $0.tSpotS ?? $0.tLoadStartS }.sorted()
                guard arrivalOffsets.count > 1 else { continue }
                for idx in 1..<arrivalOffsets.count {
                    let s0 = arrivalOffsets[idx - 1]
                    let s1 = arrivalOffsets[idx]
                    guard s1 >= bounds.lo && s0 <= bounds.hi else { continue }
                    let gapStart = baseDate.addingTimeInterval(s0)
                    let gapEnd = baseDate.addingTimeInterval(s1)
                    maxBreakGapExcessS = max(
                        maxBreakGapExcessS,
                        computeBreakOverrun(
                            startDate: gapStart,
                            endDate: gapEnd,
                            breakRanges: breakRanges,
                            requireFullGapExcess: true
                        )
                    )
                }
            }
        }

        let rate = totalCameraHours > 0 ? Double(arrivalCount) / totalCameraHours : 0.0
        let distinctShovelCount = max(1, Set(cycles.map { "\($0.recordingId)|\($0.excavatorId)" }).count)
        let recCount = max(1, Set(cycles.map(\.recordingId)).count)
        let avgExcPerRec = Double(distinctShovelCount) / Double(recCount)
        let perShovelMaxHr = pocketServiceTimeS > 0 ? (3600.0 / pocketServiceTimeS) * avgExcPerRec : 0.0
        let gapStats = meanAndStdDev(gaps)
        let gapCV = gapStats.mean > 1e-6 ? gapStats.stdDev / gapStats.mean : 0.0

        return ArrivalMetricsSummary(
            ratePerHour: rate,
            interArrivalGapsS: gaps,
            breakGapExcessS: maxBreakGapExcessS,
            queueDepthSummary: QueueDepthSummary(
                zero: qDepthZero,
                one: qDepthOne,
                twoPlus: qDepthTwoPlus,
                maxConcurrentDepth: maxDepth,
                shovelMaxRateHr: perShovelMaxHr
            ),
            gapCoeffOfVariation: gapCV
        )
    }

    private static func analyzeSegments(
        segments: [StateSegmentDTO],
        unclippedSegments: [StateSegmentDTO],
        cycles: [HaulCycleDTO],
        boundsByRecordingId: [String: (lo: Double, hi: Double)],
        recordingDates: [String: Date],
        todStartS: Double?,
        todEndS: Double?,
        windowOverlapsBreak: Bool,
        config: TelemetryCalculationConfig
    ) -> SegmentAnalysisSummary {
        guard !segments.isEmpty else {
            return SegmentAnalysisSummary(
                uncertainCount: 0,
                outOfFrameRatio: 0,
                excavatorHangRatio: 0,
                maxIdleExcessS: 0,
                totalIdleExcessS: 0,
                shiftEdgeIdleRatio: 0,
                breakIdleExcessS: 0,
                pocketSplit: ExcavatorPocketSplit(),
                topIdleSpells: [],
                syncedStoppageWindowCount: 0
            )
        }

        let excavatorMachines = resolveExcavatorMachineIds(cycles: cycles, segments: segments)
        let edgeWindows = buildShiftEdgeWindows(config: config)
        let breakRanges = config.parsedBreakMinuteRanges

        // Build per-(recording, excavator) occupied pocket windows [tSpotS..tDepartS] for conditional Excavator State Bar split.
        var occupiedByRecExc: [String: [(start: Double, end: Double)]] = [:]
        for cyc in cycles {
            let s = cyc.tSpotS ?? cyc.tLoadStartS
            let e = cyc.tDepartS ?? cyc.tLoadEndS
            if let s, let e, e > s {
                let key = "\(cyc.recordingId)|\(cyc.excavatorId)"
                occupiedByRecExc[key, default: []].append((s, e))
            }
        }
        for (k, intervals) in occupiedByRecExc {
            occupiedByRecExc[k] = mergeIntervals(intervals)
        }

        var uncertainCount = 0
        var totalDuration = 0.0
        var outOfFrameDuration = 0.0
        var excavatorLoadingDuration = 0.0
        var excavatorIdleDuration = 0.0
        var shiftEdgeTotalDuration = 0.0
        var shiftEdgeIdleDuration = 0.0

        var emptyPocketActiveS = 0.0
        var emptyPocketIdleS = 0.0
        var spottedActiveS = 0.0
        var spottedIdleS = 0.0

        var idleSpellsByMachine: [String: [StateSegmentDTO]] = [:]

        for seg in segments {
            let dur = seg.durationS
            totalDuration += dur
            if seg.confidence < config.uncertaintyConfidenceCutoff {
                uncertainCount += 1
            }

            let state = seg.typedState
            if state == .outOfFrame {
                outOfFrameDuration += dur
            }

            let isExcavator = isExcavatorMachine(seg.machineId, knownExcavators: excavatorMachines)
            let isExcActive = (state == .loadingScoop || state == .facePrep)
            let isExcIdle = (isExcavator && state == .idle)

            if isExcActive {
                excavatorLoadingDuration += dur
            } else if isExcIdle {
                excavatorIdleDuration += dur
            }

            if isExcActive || isExcIdle {
                let occ = occupiedByRecExc["\(seg.recordingId)|\(seg.machineId)"] ?? []
                let spottedOverlap = intervalOverlapDuration(segStart: seg.startS, segEnd: seg.endS, sortedMerged: occ)
                let emptyDur = max(0.0, dur - spottedOverlap)
                if isExcActive {
                    spottedActiveS += spottedOverlap
                    emptyPocketActiveS += emptyDur
                } else {
                    spottedIdleS += spottedOverlap
                    emptyPocketIdleS += emptyDur
                }
            }

            let isStationaryIdle = (state == .idle || state == .queuingIdle)
            if state == .idle {
                let spellKey = "\(seg.recordingId)|\(seg.machineId)"
                idleSpellsByMachine[spellKey, default: []].append(seg)
            }

            if let baseDate = recordingDates[seg.recordingId], dur > 0 {
                let segStartDate = baseDate.addingTimeInterval(seg.startS)
                let segEndDate = baseDate.addingTimeInterval(seg.endS)
                let edgeOverlap = computeDailyRangeOverlap(
                    startDate: segStartDate,
                    endDate: segEndDate,
                    minuteRanges: edgeWindows
                )
                if edgeOverlap > 0 {
                    shiftEdgeTotalDuration += edgeOverlap
                    if isStationaryIdle {
                        shiftEdgeIdleDuration += edgeOverlap
                    }
                }
            }
        }

        // Rule 4.1: Merge contiguous idle segments per (recording, machine) and subtract idleThresholdS (default 300s).
        var maxIdleExcessS = 0.0
        var totalIdleExcessS = 0.0
        var rawExcessSpells: [(recId: String, machineId: String, startS: Double, endS: Double, rawDur: Double, excess: Double)] = []
        var allIdleByRec: [String: [(machineId: String, startS: Double, endS: Double)]] = [:]

        for (spellKey, machineSegs) in idleSpellsByMachine {
            let parts = spellKey.split(separator: "|", maxSplits: 1)
            let recordingId = String(parts.first ?? "")
            let machineId = parts.count > 1 ? String(parts[1]) : ""
            let mergedSpells = mergeSegmentSpans(machineSegs)

            for spell in mergedSpells {
                allIdleByRec[recordingId, default: []].append((machineId, spell.startS, spell.endS))
                let spellDur = max(0.0, spell.endS - spell.startS)
                let excess = max(0.0, spellDur - config.idleThresholdS)
                maxIdleExcessS = max(maxIdleExcessS, excess)
                totalIdleExcessS += excess
                if excess > 0 {
                    rawExcessSpells.append((recordingId, machineId, spell.startS, spell.endS, spellDur, excess))
                }
            }
        }

        // Identify multi-machine synchronized stoppages (Rule 4.1 comparison layout)
        var syncedStoppageWindows = 0
        var syncedCheckedByRec: [String: Int] = [:]
        for (recId, intervals) in allIdleByRec where intervals.count >= 2 {
            let sorted = intervals.sorted { $0.startS < $1.startS }
            var windowCount = 0
            var activeMaxEnd = sorted[0].endS
            var activeMachines: Set<String> = [sorted[0].machineId]
            var countedCurrentWindow = false
            for item in sorted.dropFirst() {
                if item.startS < activeMaxEnd - 15.0 {
                    activeMachines.insert(item.machineId)
                    activeMaxEnd = max(activeMaxEnd, item.endS)
                    if activeMachines.count >= 2 && !countedCurrentWindow {
                        windowCount += 1
                        countedCurrentWindow = true
                    }
                } else {
                    activeMaxEnd = item.endS
                    activeMachines = [item.machineId]
                    countedCurrentWindow = false
                }
            }
            syncedCheckedByRec[recId] = windowCount
            syncedStoppageWindows += windowCount
        }

        let idleSummaries: [IdleSpellSummary] = rawExcessSpells
            .sorted { $0.excess > $1.excess }
            .prefix(12)
            .enumerated()
            .map { idx, spell in
                let siblings = allIdleByRec[spell.recId] ?? []
                let coIdleMachines = Set(siblings.filter {
                    $0.machineId != spell.machineId && min($0.endS, spell.endS) - max($0.startS, spell.startS) >= 30.0
                }.map(\.machineId))
                let totalSynced = coIdleMachines.isEmpty ? 1 : (coIdleMachines.count + 1)
                return IdleSpellSummary(
                    id: "\(spell.recId)-\(spell.machineId)-\(idx)",
                    recordingId: spell.recId,
                    machineId: spell.machineId,
                    startS: spell.startS,
                    endS: spell.endS,
                    rawDurationS: spell.rawDur,
                    allowanceS: config.idleThresholdS,
                    excessS: spell.excess,
                    isMultiMachineSynced: totalSynced >= 2,
                    syncedMachineCount: totalSynced
                )
            }

        // Break Overrun preserves unclipped recovery tail past brEnd when the active slice touches a break window.
        var maxBreakExcessS = 0.0
        if windowOverlapsBreak && !breakRanges.isEmpty {
            let fallbackLo = todStartS ?? 0.0
            let fallbackHi = todEndS ?? Double.greatestFiniteMagnitude
            let unclippedIdle = unclippedSegments.filter { $0.typedState == .idle }
            let unclippedByMachine = Dictionary(grouping: unclippedIdle) { "\($0.recordingId)|\($0.machineId)" }

            for (spellKey, machineSegs) in unclippedByMachine {
                let recordingId = String(spellKey.split(separator: "|", maxSplits: 1).first ?? "")
                guard let baseDate = recordingDates[recordingId] else { continue }
                let bounds = boundsByRecordingId[recordingId] ?? (fallbackLo, fallbackHi)
                guard bounds.hi > bounds.lo else { continue }

                for spell in mergeSegmentSpans(machineSegs) {
                    guard spell.endS > bounds.lo && spell.startS < bounds.hi else { continue }
                    let sDate = baseDate.addingTimeInterval(spell.startS)
                    let eDate = baseDate.addingTimeInterval(spell.endS)
                    maxBreakExcessS = max(
                        maxBreakExcessS,
                        computeBreakOverrun(
                            startDate: sDate,
                            endDate: eDate,
                            breakRanges: breakRanges,
                            requireFullGapExcess: false
                        )
                    )
                }
            }
        }

        let excTotal = excavatorLoadingDuration + excavatorIdleDuration
        return SegmentAnalysisSummary(
            uncertainCount: uncertainCount,
            outOfFrameRatio: totalDuration > 0 ? outOfFrameDuration / totalDuration : 0.0,
            excavatorHangRatio: excTotal > 0 ? excavatorIdleDuration / excTotal : 0.0,
            maxIdleExcessS: maxIdleExcessS,
            totalIdleExcessS: totalIdleExcessS,
            shiftEdgeIdleRatio: shiftEdgeTotalDuration > 0 ? shiftEdgeIdleDuration / shiftEdgeTotalDuration : 0.0,
            breakIdleExcessS: maxBreakExcessS,
            pocketSplit: ExcavatorPocketSplit(
                emptyPocketActiveS: emptyPocketActiveS,
                emptyPocketIdleS: emptyPocketIdleS,
                spottedActiveS: spottedActiveS,
                spottedIdleS: spottedIdleS
            ),
            topIdleSpells: idleSummaries,
            syncedStoppageWindowCount: syncedStoppageWindows
        )
    }

    private static func buildHourlySeries(
        recordings: [RecordingDTO],
        cycles: [HaulCycleDTO],
        segmentRecordings: [RecordingDTO],
        segments: [StateSegmentDTO],
        recordingDates: [String: Date],
        segRecordingDates: [String: Date],
        cycleBoundsByRec: [String: (lo: Double, hi: Double)],
        segBoundsByRec: [String: (lo: Double, hi: Double)],
        config: TelemetryCalculationConfig,
        todStartS: Double? = nil,
        todEndS: Double? = nil
    ) -> [HourlyMetricPoint] {
        var cameraSecondsPerHour = [Int: Double]()
        for rec in recordings {
            guard let startDate = recordingDates[rec.recordingId], rec.durationS > 0 else { continue }
            let bounds = cycleBoundsByRec[rec.recordingId] ?? (max(0.0, todStartS ?? 0.0), min(rec.durationS, todEndS ?? rec.durationS))
            guard bounds.hi > bounds.lo else { continue }
            accumulateClockHourSlices(
                startDate: startDate.addingTimeInterval(bounds.lo),
                endDate: startDate.addingTimeInterval(bounds.hi)
            ) { hour, seconds in
                cameraSecondsPerHour[hour, default: 0] += seconds
            }
        }

        var completeByHour = [Int: [HaulCycleDTO]]()
        var arrivalsByHour = [Int: Int]()
        for cycle in cycles {
            guard let base = recordingDates[cycle.recordingId] else { continue }
            let anchorS = cycle.tLoadStartS ?? cycle.tArriveS ?? cycle.tSpotS ?? 0
            let hour = OviusFormat.utcHourAndMinute(for: base.addingTimeInterval(anchorS)).hour
            arrivalsByHour[hour, default: 0] += 1
            if cycle.cycleStatus == CycleStatus.complete.rawValue {
                completeByHour[hour, default: []].append(cycle)
            }
        }

        var delayByHour = [Int: Double]()
        var segCameraSecondsPerHour = [Int: Double]()
        for rec in segmentRecordings {
            guard let startDate = segRecordingDates[rec.recordingId], rec.durationS > 0 else { continue }
            let bounds = segBoundsByRec[rec.recordingId] ?? (max(0.0, todStartS ?? 0.0), min(rec.durationS, todEndS ?? rec.durationS))
            guard bounds.hi > bounds.lo else { continue }
            accumulateClockHourSlices(
                startDate: startDate.addingTimeInterval(bounds.lo),
                endDate: startDate.addingTimeInterval(bounds.hi)
            ) { hour, seconds in
                segCameraSecondsPerHour[hour, default: 0] += seconds
            }
        }
        var excLoadByHour = [Int: Double]()
        var excIdleByHour = [Int: Double]()
        let excavatorMachines = resolveExcavatorMachineIds(cycles: cycles, segments: segments)

        for seg in segments {
            guard let base = segRecordingDates[seg.recordingId], seg.durationS > 0 else { continue }
            let segStart = base.addingTimeInterval(seg.startS)
            let segEnd = base.addingTimeInterval(seg.endS)
            let st = seg.typedState
            let isDelay = (st == .idle || st == .queuingIdle)
            let isExc = isExcavatorMachine(seg.machineId, knownExcavators: excavatorMachines)
            let isExcLoad = (st == .loadingScoop || st == .facePrep)
            let isExcIdle = (isExc && st == .idle)

            guard isDelay || isExcLoad || isExcIdle else { continue }
            accumulateClockHourSlices(startDate: segStart, endDate: segEnd) { hour, seconds in
                if isDelay {
                    delayByHour[hour, default: 0] += seconds
                }
                if isExcLoad {
                    excLoadByHour[hour, default: 0] += seconds
                } else if isExcIdle {
                    excIdleByHour[hour, default: 0] += seconds
                }
            }
        }

        let edgeRanges = buildShiftEdgeWindows(config: config)
        let breakRanges = config.parsedBreakMinuteRanges

        return (0..<24).map { hour in
            let camHours = max(0, (cameraSecondsPerHour[hour] ?? 0) / 3600.0)
            let segCamHours = max(0, (segCameraSecondsPerHour[hour] ?? 0) / 3600.0)
            let complete = completeByHour[hour] ?? []
            let arrivals = arrivalsByHour[hour] ?? 0
            let volRate = camHours > 0 ? (Double(complete.count) * config.meanPayloadM3) / camHours : 0
            let arrRate = camHours > 0 ? Double(arrivals) / camHours : 0
            let excLoad = excLoadByHour[hour] ?? 0
            let excIdle = excIdleByHour[hour] ?? 0
            let hangDenom = excLoad + excIdle
            let rawDelay = delayByHour[hour] ?? 0
            let delayPerCamHr = segCamHours > 0 ? rawDelay / segCamHours : rawDelay
            let midMinute = hour * 60 + 30

            return HourlyMetricPoint(
                hourUTC: hour,
                volumetricRateM3Hr: volRate,
                truckArrivalRateHr: arrRate,
                avgLoadDurationS: mean(complete.compactMap(extractLoadS)),
                avgQueueTimeS: mean(complete.compactMap(extractQueueS)),
                avgSpotDurationS: mean(complete.compactMap(extractSpotS)),
                avgDepartureLagS: mean(complete.compactMap(extractDepartS)),
                excavatorHangRatio: hangDenom > 0 ? excIdle / hangDenom : 0,
                delayDurationS: rawDelay,
                delayPerCamHr: delayPerCamHr,
                isShiftEdge: isMinuteInRanges(midMinute, ranges: edgeRanges),
                isBreakWindow: isMinuteInRanges(midMinute, ranges: breakRanges)
            )
        }
    }

    private static func computeHourlySlumpConcentration(from hourlySeries: [HourlyMetricPoint]) -> Double {
        let rates = hourlySeries.map { $0.delayPerCamHr > 0 ? $0.delayPerCamHr : $0.delayDurationS }
        let totalRate = rates.reduce(0.0, +)
        guard totalRate > 0 else { return 0.0 }
        var maxTwoHour = 0.0
        for idx in 0..<23 {
            maxTwoHour = max(maxTwoHour, rates[idx] + rates[idx + 1])
        }
        return maxTwoHour / totalRate
    }

    private static func buildShiftEdgeWindows(config: TelemetryCalculationConfig) -> [(start: Int, end: Int)] {
        let windowMin = max(1, config.shiftEdgeWindowMin)
        var windows: [(Int, Int)] = []
        for shiftStart in config.parsedShiftStartMinutes {
            windows.append((shiftStart, min(1440, shiftStart + windowMin)))
            let rawEnd = (shiftStart + 720) % 1440
            let shiftEnd = rawEnd == 0 ? 1440 : rawEnd
            let closingStart = max(0, shiftEnd - windowMin)
            if shiftEnd > closingStart {
                windows.append((closingStart, shiftEnd))
            }
        }
        return windows
    }

    private static func mergeSegmentSpans(_ segs: [StateSegmentDTO]) -> [(startS: Double, endS: Double)] {
        guard !segs.isEmpty else { return [] }
        let sorted = segs.sorted { $0.startS < $1.startS }
        var merged: [(startS: Double, endS: Double)] = []
        var curStart = sorted[0].startS
        var curEnd = sorted[0].endS
        for seg in sorted.dropFirst() {
            if seg.startS <= curEnd + 1.5 {
                curEnd = max(curEnd, seg.endS)
            } else {
                merged.append((curStart, curEnd))
                curStart = seg.startS
                curEnd = seg.endS
            }
        }
        merged.append((curStart, curEnd))
        return merged
    }

    private static func mergeIntervals(_ raw: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        guard !raw.isEmpty else { return [] }
        let sorted = raw.sorted { $0.start < $1.start }
        var merged: [(start: Double, end: Double)] = []
        var curS = sorted[0].start
        var curE = sorted[0].end
        for item in sorted.dropFirst() {
            if item.start <= curE {
                curE = max(curE, item.end)
            } else {
                merged.append((curS, curE))
                curS = item.start
                curE = item.end
            }
        }
        merged.append((curS, curE))
        return merged
    }

    private static func intervalOverlapDuration(
        segStart: Double,
        segEnd: Double,
        sortedMerged: [(start: Double, end: Double)]
    ) -> Double {
        guard segEnd > segStart else { return 0.0 }
        var overlap = 0.0
        for item in sortedMerged {
            if item.start >= segEnd { break }
            if item.end <= segStart { continue }
            overlap += min(segEnd, item.end) - max(segStart, item.start)
        }
        return overlap
    }

    private static func buildArrivalHeadwaySamples(
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        maxSamples: Int
    ) -> [ArrivalHeadwaySample] {
        let cycByRec = Dictionary(grouping: cycles, by: \.recordingId)
        let excIds = resolveExcavatorMachineIds(cycles: cycles, segments: segments)
        let excIdleByRec = Dictionary(
            grouping: segments.filter { $0.typedState == .idle && isExcavatorMachine($0.machineId, knownExcavators: excIds) },
            by: \.recordingId
        )

        var rawSamples: [(id: String, gapMin: Double, precedentHangS: Double)] = []
        for (recId, group) in cycByRec {
            let arrivals = group.compactMap { $0.tArriveS ?? $0.tSpotS ?? $0.tLoadStartS }.sorted()
            guard arrivals.count > 1 else { continue }
            let idleSegs = excIdleByRec[recId] ?? []
            for idx in 1..<arrivals.count {
                let t0 = arrivals[idx - 1]
                let t1 = arrivals[idx]
                let gapS = max(0.0, t1 - t0)
                let hangBefore = idleSegs.reduce(0.0) { acc, seg in
                    acc + max(0.0, min(t1, seg.endS) - max(t0, seg.startS))
                }
                rawSamples.append(("\(recId)-\(idx)", gapS / 60.0, hangBefore))
            }
        }

        let ordered = rawSamples.sorted { $0.gapMin > $1.gapMin }
        return ordered.prefix(maxSamples).enumerated().map { idx, item in
            ArrivalHeadwaySample(
                id: item.id,
                sequenceIndex: idx + 1,
                gapMin: item.gapMin,
                precedentHangS: item.precedentHangS
            )
        }
    }

    private static func buildGanttConcurrencyAudit(
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO]
    ) -> (GanttConcurrencyAudit, [GanttConflictInterval]) {
        let minS = segments.map(\.startS).min() ?? 0.0
        let maxS = segments.map(\.endS).max() ?? 0.0
        let spanS = max(1.0, maxS - minS)

        // Collect sweeping events for multi-truck queueing overlap & excavator starvation
        var queueEvents: [(t: Double, delta: Int)] = []
        for seg in segments where seg.typedState == .queuingIdle {
            queueEvents.append((seg.startS, 1))
            queueEvents.append((seg.endS, -1))
        }
        queueEvents.sort { $0.t < $1.t }

        var overlapQueueS = 0.0
        var conflictIntervals: [GanttConflictInterval] = []
        var activeQ = 0
        var prevT = minS
        var overlapStart: Double? = nil

        for ev in queueEvents {
            if activeQ >= 2 && ev.t > prevT {
                overlapQueueS += (ev.t - prevT)
            }
            activeQ += ev.delta
            if activeQ >= 2 && overlapStart == nil {
                overlapStart = ev.t
            } else if activeQ < 2, let start = overlapStart {
                if ev.t - start >= 5.0 {
                    conflictIntervals.append(
                        GanttConflictInterval(id: "q-\(conflictIntervals.count)", kind: "Queue Overlap", startS: start, endS: ev.t)
                    )
                }
                overlapStart = nil
            }
            prevT = ev.t
        }

        let excIds = resolveExcavatorMachineIds(cycles: cycles, segments: segments)
        let excSegs = segments.filter { isExcavatorMachine($0.machineId, knownExcavators: excIds) }
        let starvedS = excSegs.filter { $0.typedState == .idle }.reduce(0.0) { $0 + $1.durationS }
        let excObservedS = excSegs.filter {
            $0.typedState == .idle || $0.typedState == .loadingScoop || $0.typedState == .facePrep
        }.reduce(0.0) { $0 + $1.durationS }
        let starvedDenom = excObservedS > 0 ? excObservedS : (spanS * Double(max(1, Set(excSegs.map(\.machineId)).count)))

        // Synced fleet-wide halts: require >= 60% of observed machines (min 2) idle simultaneously for >= 120s.
        let idleIntervals = segments.filter { $0.typedState == .idle }
        var haltEvents: [(t: Double, delta: Int, machine: String)] = []
        for seg in idleIntervals {
            haltEvents.append((seg.startS, 1, seg.machineId))
            haltEvents.append((seg.endS, -1, seg.machineId))
        }
        haltEvents.sort { $0.t < $1.t }
        let uniqueMachines = max(2, Set(segments.map(\.machineId)).count)
        let syncedMachineQuorum = max(2, Int(ceil(Double(uniqueMachines) * 0.6)))
        var haltCount = 0
        var idleCounts: [String: Int] = [:]
        var activeSyncedStart: Double? = nil
        for ev in haltEvents {
            idleCounts[ev.machine, default: 0] += ev.delta
            let activeIdleMachines = idleCounts.values.filter { $0 > 0 }.count
            if activeIdleMachines >= syncedMachineQuorum && activeSyncedStart == nil {
                activeSyncedStart = ev.t
            } else if activeIdleMachines < syncedMachineQuorum, let start = activeSyncedStart {
                if ev.t - start >= 120.0 {
                    haltCount += 1
                    conflictIntervals.append(
                        GanttConflictInterval(id: "h-\(conflictIntervals.count)", kind: "Synced Halt", startS: start, endS: ev.t)
                    )
                }
                activeSyncedStart = nil
            }
        }

        let cutoffs = cycles.filter { $0.cycleStatus != CycleStatus.complete.rawValue }.count
        let audit = GanttConcurrencyAudit(
            queueOverlapPct: min(1.0, overlapQueueS / spanS),
            starvedPct: min(1.0, starvedS / max(1.0, starvedDenom)),
            syncedHaltCount: haltCount,
            boundaryCutoffCount: cutoffs
        )
        let orderedConflicts = conflictIntervals.sorted { $0.startS < $1.startS }
        return (audit, Array(orderedConflicts.prefix(120)))
    }

    private static func isMinuteInRanges(_ minute: Int, ranges: [(start: Int, end: Int)]) -> Bool {
        ranges.contains { minute >= $0.start && minute < $0.end }
    }

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

    private static func accumulateClockHourSlices(
        startDate: Date,
        endDate: Date,
        onSlice: (_ hourUTC: Int, _ seconds: Double) -> Void
    ) {
        guard endDate > startDate else { return }
        var cursor = startDate
        var guardCount = 0
        while cursor < endDate && guardCount < 96 {
            guardCount += 1
            let secInDay = OviusFormat.utcSecondsSinceMidnight(for: cursor)
            let hour = min(23, max(0, Int(secInDay / 3600.0)))
            let secPastHour = secInDay.truncatingRemainder(dividingBy: 3600.0)
            let nextBoundaryOffset = max(1e-6, 3600.0 - secPastHour)
            let nextBoundary = cursor.addingTimeInterval(nextBoundaryOffset)
            let sliceEnd = min(endDate, nextBoundary)
            let delta = sliceEnd.timeIntervalSince(cursor)
            if delta > 0 {
                onSlice(hour, delta)
            }
            cursor = sliceEnd
        }
    }

    private static func computeDailyRangeOverlap(
        startDate: Date,
        endDate: Date,
        minuteRanges: [(start: Int, end: Int)]
    ) -> Double {
        guard endDate > startDate, !minuteRanges.isEmpty else { return 0.0 }
        var dayStart = OviusFormat.utcStartOfDay(for: startDate)
        var totalOverlap = 0.0
        var guardDays = 0
        while dayStart < endDate && guardDays < 14 {
            guardDays += 1
            for range in minuteRanges {
                let winStart = dayStart.addingTimeInterval(Double(range.start) * 60.0)
                let winEnd = dayStart.addingTimeInterval(Double(range.end) * 60.0)
                let lo = max(startDate, winStart)
                let hi = min(endDate, winEnd)
                if hi > lo {
                    totalOverlap += hi.timeIntervalSince(lo)
                }
            }
            dayStart = dayStart.addingTimeInterval(86_400.0)
        }
        return totalOverlap
    }

    private static func computeBreakOverrun(
        startDate: Date,
        endDate: Date,
        breakRanges: [(start: Int, end: Int)],
        requireFullGapExcess: Bool
    ) -> Double {
        guard endDate > startDate else { return 0.0 }
        let totalSpanS = endDate.timeIntervalSince(startDate)
        var dayStart = OviusFormat.utcStartOfDay(for: startDate)
        var maxExcess = 0.0
        var guardDays = 0
        while dayStart < endDate && guardDays < 14 {
            guardDays += 1
            for br in breakRanges {
                let brStart = dayStart.addingTimeInterval(Double(br.start) * 60.0)
                let brEnd = dayStart.addingTimeInterval(Double(br.end) * 60.0)
                let brDur = brEnd.timeIntervalSince(brStart)
                if startDate <= brEnd && endDate > brEnd && endDate > brStart {
                    let overrun = endDate.timeIntervalSince(brEnd)
                    if requireFullGapExcess {
                        let bounded = min(overrun, max(0.0, totalSpanS - brDur))
                        maxExcess = max(maxExcess, bounded)
                    } else if startDate >= brStart.addingTimeInterval(-1800.0) {
                        maxExcess = max(maxExcess, overrun)
                    }
                }
            }
            dayStart = dayStart.addingTimeInterval(86_400.0)
        }
        return maxExcess
    }

    private static func buildHistogram(values: [Double], binSizeS: Double, maxBins: Int) -> [HistogramBin] {
        guard !values.isEmpty, binSizeS > 0, maxBins > 0 else { return [] }
        let maxVal = values.max() ?? 0
        let neededBins = min(maxBins, max(4, Int(ceil(maxVal / binSizeS))))
        var counts = Array(repeating: 0, count: neededBins)

        for value in values {
            let clamped = max(0, value)
            let binIdx = min(neededBins - 1, Int(clamped / binSizeS))
            counts[binIdx] += 1
        }

        return (0..<neededBins).map { idx in
            let lo = Double(idx) * binSizeS
            let hi = Double(idx + 1) * binSizeS
            let label = idx == neededBins - 1 && maxVal >= hi
                ? "\(Int(lo))s+"
                : "\(Int(lo))–\(Int(hi))s"
            return HistogramBin(label: label, lowerBoundS: lo, upperBoundS: hi, count: counts[idx])
        }
    }

    private static func buildGanttItems(segments: [StateSegmentDTO], cutoff: Double) -> [GanttSegmentItem] {
        segments
            .sorted { $0.startS < $1.startS }
            .prefix(5_000)
            .compactMap { seg in
                guard let state = seg.typedState else { return nil }
                return GanttSegmentItem(
                    segmentId: seg.segmentId,
                    recordingId: seg.recordingId,
                    machineId: seg.machineId,
                    state: state,
                    startS: seg.startS,
                    endS: seg.endS,
                    confidence: seg.confidence,
                    isUncertain: seg.confidence < cutoff
                )
            }
    }

    private static func buildCycleAuditRows(
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        cutoff: Double
    ) -> [CycleAuditRow] {
        var uncertainCountsByCycle: [String: Int] = [:]
        for seg in segments where seg.confidence < cutoff {
            uncertainCountsByCycle[seg.cycleId, default: 0] += 1
        }

        return cycles.map { cycle in
            let isComplete = cycle.cycleStatus == CycleStatus.complete.rawValue
            return CycleAuditRow(
                cycleId: cycle.cycleId,
                recordingId: cycle.recordingId,
                excavatorId: cycle.excavatorId,
                truckLabel: cycle.truckLabel,
                cycleStatus: cycle.cycleStatus,
                isComplete: isComplete,
                queueTimeS: extractQueueS(cycle),
                spotTimeS: extractSpotS(cycle),
                loadDurationS: extractLoadS(cycle),
                departureLagS: extractDepartS(cycle),
                totalCycleDurationS: isComplete ? extractTotalCycleS(cycle) : nil,
                uncertainSegmentCount: uncertainCountsByCycle[cycle.cycleId] ?? 0
            )
        }
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        return values.reduce(0.0, +) / Double(values.count)
    }

    private static func meanAndStdDev(_ values: [Double]) -> (mean: Double, stdDev: Double) {
        guard !values.isEmpty else { return (0.0, 0.0) }
        let avg = mean(values)
        guard values.count > 1 else { return (avg, 0.0) }
        let variance = values.reduce(0.0) { $0 + pow($1 - avg, 2) } / Double(values.count)
        return (avg, sqrt(variance))
    }
}
