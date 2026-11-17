import Foundation

/// Pure client-side builders producing Layer 1, Layer 2, and Layer 3 Data Explorer rows
/// directly from filtered raw telemetry DTOs.
public enum DataExplorerBuilder {

    /// Layer 1: Aggregates active-window `haul_cycles` per `RecordingDTO`.
    public static func buildRecordingRows(
        recordings: [RecordingDTO],
        sectionNamesByRecordingId: [String: (sectionId: String, sectionName: String)],
        cycles: [HaulCycleDTO],
        todStartS: Double?,
        todEndS: Double?,
        todBaseMinuteUTC: Int? = nil,
        config: TelemetryCalculationConfig
    ) -> [RecordingExplorerRow] {
        var boundsByRec: [String: (lo: Double, hi: Double)] = [:]
        if todStartS != nil || todEndS != nil {
            for rec in recordings {
                boundsByRec[rec.recordingId] = TelemetryMetricsCalculator.clipBounds(
                    for: rec,
                    todStartS: todStartS,
                    todEndS: todEndS,
                    todBaseMinuteUTC: todBaseMinuteUTC
                )
            }
        }
        let filteredCycles = TelemetryMetricsCalculator.filterCycles(
            cycles,
            todStartS: todStartS,
            todEndS: todEndS,
            boundsByRecordingId: boundsByRec
        )
        let cyclesByRec = Dictionary(grouping: filteredCycles, by: \.recordingId)

        return recordings.map { rec in
            let recCycles = cyclesByRec[rec.recordingId] ?? []
            let complete = recCycles.filter { $0.cycleStatus == CycleStatus.complete.rawValue }
            let incompleteCount = recCycles.count - complete.count
            let effHours = TelemetryMetricsCalculator.computeEffectiveCameraHours(
                for: rec,
                todStartS: todStartS,
                todEndS: todEndS,
                todBaseMinuteUTC: todBaseMinuteUTC
            )

            let volume = Double(complete.count) * config.meanPayloadM3
            let rate = effHours > 0 ? volume / effHours : 0.0
            let secInfo = sectionNamesByRecordingId[rec.recordingId] ?? ("UNASSIGNED", "Unassigned")

            return RecordingExplorerRow(
                recordingId: rec.recordingId,
                filename: rec.filename,
                timestamp: rec.timestamp,
                startDate: OviusFormat.parseISODate(rec.timestamp) ?? .distantPast,
                sectionId: secInfo.sectionId,
                sectionName: secInfo.sectionName,
                cameraId: rec.cameraId,
                locationTag: rec.locationTag,
                resolution: rec.resolution,
                fps: rec.fps,
                durationS: rec.durationS,
                effectiveWindowHours: effHours,
                totalCycleCount: recCycles.count,
                completeCycleCount: complete.count,
                incompleteCycleCount: incompleteCount,
                totalVolumeM3: volume,
                volumetricRateM3Hr: rate,
                avgQueueTimeS: mean(complete.compactMap(TelemetryMetricsCalculator.extractQueueS)),
                avgSpotTimeS: mean(complete.compactMap(TelemetryMetricsCalculator.extractSpotS)),
                avgLoadDurationS: mean(complete.compactMap(TelemetryMetricsCalculator.extractLoadS)),
                avgDepartureLagS: mean(complete.compactMap(TelemetryMetricsCalculator.extractDepartS)),
                avgTotalCycleS: mean(complete.compactMap(TelemetryMetricsCalculator.extractTotalCycleS)),
                excavatorCount: Set(recCycles.map(\.excavatorId)).count,
                truckCount: Set(recCycles.map(\.truckLabel)).count
            )
        }
        .sorted { $0.startDate > $1.startDate }
    }

    /// Layer 2: Builds cycle rows for an opened `RecordingDTO`, enforcing Business Rule 4.2 & Rule 4.3.
    public static func buildCycleRows(
        recording: RecordingDTO? = nil,
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO],
        todStartS: Double?,
        todEndS: Double?,
        todBaseMinuteUTC: Int? = nil,
        config: TelemetryCalculationConfig
    ) -> [CycleExplorerRow] {
        var boundsByRec: [String: (lo: Double, hi: Double)] = [:]
        if let recording, (todStartS != nil || todEndS != nil) {
            boundsByRec[recording.recordingId] = TelemetryMetricsCalculator.clipBounds(
                for: recording,
                todStartS: todStartS,
                todEndS: todEndS,
                todBaseMinuteUTC: todBaseMinuteUTC
            )
        }
        let filteredCycles = TelemetryMetricsCalculator.filterCycles(
            cycles,
            todStartS: todStartS,
            todEndS: todEndS,
            boundsByRecordingId: boundsByRec
        )
        let clippedSegments = TelemetryMetricsCalculator.clipSegments(
            segments,
            todStartS: todStartS,
            todEndS: todEndS,
            boundsByRecordingId: boundsByRec
        )

        var uncertainCounts: [String: Int] = [:]
        for seg in clippedSegments where seg.confidence < config.uncertaintyConfidenceCutoff {
            uncertainCounts[seg.cycleId, default: 0] += 1
        }

        return filteredCycles
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
                    payloadM3: isComplete ? config.meanPayloadM3 : 0.0,
                    scoopCount: cycle.scoops?.count ?? 0,
                    uncertainSegmentCount: uncertainCounts[cycle.cycleId] ?? 0
                )
            }
    }

    /// Layer 3: Builds specific machine `StateSegmentDTO` timing rows and embedded `ScoopTimingDTO` rows
    /// for an opened cycle (`cycle_id` match plus overlapping excavator `NONE` intervals near the cycle window, respecting `[todStartS, todEndS]`).
    public static func buildStateTimingRows(
        recording: RecordingDTO,
        cycle: HaulCycleDTO,
        allRecordingSegments: [StateSegmentDTO],
        todStartS: Double? = nil,
        todEndS: Double? = nil,
        todBaseMinuteUTC: Int? = nil,
        config: TelemetryCalculationConfig
    ) -> (segments: [StateTimingExplorerRow], scoops: [ScoopTimingExplorerRow]) {
        let baseDate = OviusFormat.parseISODate(recording.timestamp) ?? .now
        let cycleStart = [cycle.tArriveS, cycle.tSpotS, cycle.tLoadStartS].compactMap { $0 }.min() ?? 0
        let cycleEnd = [cycle.tDepartS, cycle.tLoadEndS].compactMap { $0 }.max() ?? cycleStart

        var boundsByRec: [String: (lo: Double, hi: Double)] = [:]
        if todStartS != nil || todEndS != nil {
            boundsByRec[recording.recordingId] = TelemetryMetricsCalculator.clipBounds(
                for: recording,
                baseDate: baseDate,
                todStartS: todStartS,
                todEndS: todEndS,
                todBaseMinuteUTC: todBaseMinuteUTC
            )
        }
        let scopedRecordingSegments = TelemetryMetricsCalculator.clipSegments(
            allRecordingSegments,
            todStartS: todStartS,
            todEndS: todEndS,
            boundsByRecordingId: boundsByRec
        )

        let truckSegIds = Set(cycle.truckSegments ?? [])
        let scoopSegIds = Set((cycle.scoops ?? []).map(\.excavatorSegmentId))
        let excavatorIds = TelemetryMetricsCalculator.resolveExcavatorMachineIds(
            cycles: [cycle],
            segments: scopedRecordingSegments
        )

        let matched = scopedRecordingSegments.filter { seg in
            if seg.cycleId == cycle.cycleId || truckSegIds.contains(seg.segmentId) || scoopSegIds.contains(seg.segmentId) {
                return true
            }
            // Include adjacent excavator face_prep/idle context intervals within -60s/+30s of this cycle inside active time window.
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
            let wallClock = baseDate.addingTimeInterval(seg.startS)
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
                utcClockStart: OviusFormat.utcClock(wallClock),
                confidence: seg.confidence,
                isUncertain: seg.confidence < config.uncertaintyConfidenceCutoff
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

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        return values.reduce(0.0, +) / Double(values.count)
    }
}
