import Foundation

/// Pure client-side builders producing Layer 1, Layer 2, and Layer 3 Data Explorer rows
/// directly from recording-level telemetry DTOs.
public enum DataExplorerBuilder {

    /// Layer 1: Aggregates `haul_cycles` per selected `RecordingDTO`.
    public static func buildRecordingRows(
        recordings: [RecordingDTO],
        sectionNamesByRecordingId: [String: (sectionId: String, sectionName: String)],
        cycles: [HaulCycleDTO]
    ) -> [RecordingExplorerRow] {
        let cyclesByRec = Dictionary(grouping: cycles, by: \.recordingId)

        return recordings.map { rec in
            buildRecordingRow(
                for: rec,
                sectionInfo: sectionNamesByRecordingId[rec.recordingId],
                cycles: cyclesByRec[rec.recordingId] ?? []
            )
        }
        .sorted { $0.startDate > $1.startDate }
    }

    /// Builds and aggregates a single Layer 1 Data Explorer row for `rec` so `DashboardViewModel`
    /// can pre-compute and cache each recording's row once on arrival.
    public static func buildRecordingRow(
        for rec: RecordingDTO,
        sectionInfo: (sectionId: String, sectionName: String)?,
        cycles recCycles: [HaulCycleDTO]
    ) -> RecordingExplorerRow {
        var completeCount = 0
        var passCounts: [Double] = []
        var queueTimes: [Double] = []
        var spotTimes: [Double] = []
        var loadDurations: [Double] = []
        var departLags: [Double] = []
        var totalCycleDurations: [Double] = []
        var excavators: Set<String> = []
        var trucks: Set<String> = []

        passCounts.reserveCapacity(recCycles.count)
        queueTimes.reserveCapacity(recCycles.count)
        spotTimes.reserveCapacity(recCycles.count)
        loadDurations.reserveCapacity(recCycles.count)
        departLags.reserveCapacity(recCycles.count)
        totalCycleDurations.reserveCapacity(recCycles.count)

        for cyc in recCycles {
            excavators.insert(cyc.excavatorId)
            trucks.insert(cyc.truckLabel)

            guard cyc.cycleStatus == CycleStatus.complete.rawValue else { continue }
            completeCount += 1

            if let scoops = cyc.scoops, !scoops.isEmpty {
                passCounts.append(Double(scoops.count))
            }
            if let q = TelemetryMetricsCalculator.extractQueueS(cyc) { queueTimes.append(q) }
            if let s = TelemetryMetricsCalculator.extractSpotS(cyc) { spotTimes.append(s) }
            if let l = TelemetryMetricsCalculator.extractLoadS(cyc) { loadDurations.append(l) }
            if let d = TelemetryMetricsCalculator.extractDepartS(cyc) { departLags.append(d) }
            if let t = TelemetryMetricsCalculator.extractTotalCycleS(cyc) { totalCycleDurations.append(t) }
        }

        let resolvedSec = sectionInfo ?? ("UNASSIGNED", "Unassigned")
        let startDate = rec.startDate ?? OviusFormat.parseISODate(rec.timestamp) ?? .distantPast
        let formattedTimestamp = rec.formattedTimestampLabel.isEmpty
            ? OviusFormat.utcDateTime(startDate)
            : rec.formattedTimestampLabel

        return RecordingExplorerRow(
            recordingId: rec.recordingId,
            filename: rec.filename,
            timestamp: rec.timestamp,
            startDate: startDate,
            formattedTimestamp: formattedTimestamp,
            sectionId: resolvedSec.sectionId,
            sectionName: resolvedSec.sectionName,
            cameraId: rec.cameraId,
            locationTag: rec.locationTag,
            resolution: rec.resolution,
            fps: rec.fps,
            durationS: rec.durationS,
            totalCycleCount: recCycles.count,
            completeCycleCount: completeCount,
            incompleteCycleCount: recCycles.count - completeCount,
            avgPassesPerCycle: TelemetryMetricsCalculator.mean(passCounts),
            avgQueueTimeS: TelemetryMetricsCalculator.mean(queueTimes),
            avgSpotTimeS: TelemetryMetricsCalculator.mean(spotTimes),
            avgLoadDurationS: TelemetryMetricsCalculator.mean(loadDurations),
            avgDepartureLagS: TelemetryMetricsCalculator.mean(departLags),
            avgTotalCycleS: TelemetryMetricsCalculator.mean(totalCycleDurations),
            excavatorCount: excavators.count,
            truckCount: trucks.count
        )
    }

    /// Layer 2: Builds cycle rows for an opened recording, enforcing Business Rule 4.2 & Rule 4.3.
    public static func buildCycleRows(
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        uncertaintyCutoff: Double = TelemetryMetricsCalculator.defaultUncertaintyCutoff
    ) -> [CycleExplorerRow] {
        var uncertainCounts: [String: Int] = [:]
        for seg in segments where seg.confidence < uncertaintyCutoff {
            uncertainCounts[seg.cycleId, default: 0] += 1
        }

        return cycles
            .sorted { ($0.tLoadStartS ?? $0.tArriveS ?? 0) < ($1.tLoadStartS ?? $1.tArriveS ?? 0) }
            .map { cycle in
                let isComplete = cycle.cycleStatus == CycleStatus.complete.rawValue
                let totalDur = isComplete ? TelemetryMetricsCalculator.extractTotalCycleS(cycle) : nil
                return CycleExplorerRow(
                    cycleId: cycle.cycleId,
                    recordingId: cycle.recordingId,
                    truckLabel: cycle.truckLabel,
                    excavatorId: cycle.excavatorId,
                    cycleStatus: cycle.cycleStatus,
                    isComplete: isComplete,
                    tArriveS: cycle.tArriveS ?? 0,
                    tSpotS: cycle.tSpotS ?? 0,
                    tLoadStartS: cycle.tLoadStartS ?? 0,
                    tLoadEndS: cycle.tLoadEndS ?? 0,
                    tDepartS: cycle.tDepartS ?? 0,
                    queueTimeS: TelemetryMetricsCalculator.extractQueueS(cycle) ?? 0,
                    spotDurationS: TelemetryMetricsCalculator.extractSpotS(cycle) ?? 0,
                    loadDurationS: TelemetryMetricsCalculator.extractLoadS(cycle) ?? 0,
                    departureLagS: TelemetryMetricsCalculator.extractDepartS(cycle) ?? 0,
                    totalCycleDurationS: totalDur,
                    scoopCount: cycle.scoops?.count ?? 0,
                    uncertainSegmentCount: uncertainCounts[cycle.cycleId] ?? 0
                )
            }
    }

    /// Layer 3: Builds specific machine `StateSegmentDTO` timing rows and embedded `ScoopTimingDTO` rows
    /// for an opened cycle (`cycle_id` match plus overlapping excavator `NONE` intervals near the cycle window).
    public static func buildStateTimingRows(
        cycle: HaulCycleDTO,
        allRecordingSegments: [StateSegmentDTO],
        uncertaintyCutoff: Double = TelemetryMetricsCalculator.defaultUncertaintyCutoff
    ) -> (segments: [StateTimingExplorerRow], scoops: [ScoopTimingExplorerRow]) {
        let cycleStart = [cycle.tArriveS, cycle.tSpotS, cycle.tLoadStartS].compactMap { $0 }.min() ?? 0
        let cycleEnd = [cycle.tDepartS, cycle.tLoadEndS].compactMap { $0 }.max() ?? cycleStart

        let truckSegIds = Set(cycle.truckSegments ?? [])
        let scoopSegIds = Set((cycle.scoops ?? []).map(\.excavatorSegmentId))
        let excavatorIds = TelemetryMetricsCalculator.resolveExcavatorMachineIds(
            cycles: [cycle],
            segments: allRecordingSegments
        )

        let matched = allRecordingSegments.filter { seg in
            if seg.cycleId == cycle.cycleId || truckSegIds.contains(seg.segmentId) || scoopSegIds.contains(seg.segmentId) {
                return true
            }
            // Include adjacent excavator face_prep/idle context intervals within -60s/+30s of this cycle.
            return seg.machineId == cycle.excavatorId
                && seg.endS >= (cycleStart - 60)
                && seg.startS <= (cycleEnd + 30)
        }
        .sorted { lhs, rhs in
            if lhs.startS != rhs.startS { return lhs.startS < rhs.startS }
            return lhs.machineId < rhs.machineId
        }

        let segRows = matched.map { seg in
            let isExc = TelemetryMetricsCalculator.isExcavatorMachine(seg.machineId, knownExcavators: excavatorIds)
            return StateTimingExplorerRow(
                segmentId: seg.segmentId,
                recordingId: seg.recordingId,
                cycleId: seg.cycleId,
                machineId: seg.machineId,
                machineRole: isExc ? "Excavator" : "Truck",
                state: seg.state,
                typedState: seg.typedState,
                startS: seg.startS,
                endS: seg.endS,
                durationS: seg.durationS,
                confidence: seg.confidence,
                isUncertain: seg.confidence < uncertaintyCutoff
            )
        }

        let sortedScoops = (cycle.scoops ?? []).sorted { $0.scoopNumber < $1.scoopNumber }
        let scoopRows = sortedScoops.enumerated().map { idx, scoop in
            let gap: Double? = idx > 0 ? max(0.0, scoop.startS - sortedScoops[idx - 1].endS) : nil
            return ScoopTimingExplorerRow(
                scoopNumber: scoop.scoopNumber,
                excavatorSegmentId: scoop.excavatorSegmentId,
                startS: scoop.startS,
                dumpS: scoop.dumpS,
                endS: scoop.endS,
                durationS: max(0.0, scoop.endS - scoop.startS),
                interScoopGapS: gap
            )
        }

        return (segRows, scoopRows)
    }
}
