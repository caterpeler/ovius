import Foundation

/// Turns a recording's cloud telemetry (its haul cycles and machine state segments) into the dashboard's
/// `FleetRecording`, using the same phase, idle and utilisation rules as `TelemetryMetricsCalculator`.
public enum FleetTelemetryAdapter {
    public static func recording(
        _ rec: RecordingDTO,
        sectionName: String,
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO]
    ) -> FleetRecording {
        let calc = TelemetryMetricsCalculator.self
        let excavatorIds = calc.resolveExcavatorMachineIds(cycles: cycles, segments: segments)
        let contribution = calc.computeRecordingContribution(recordingId: rec.recordingId, cycles: cycles, segments: segments)

        // The least sure segment of each cycle, and each segment's confidence for the passes.
        var confidenceById: [String: Double] = [:]
        var leastSureByCycle: [String: Double] = [:]
        confidenceById.reserveCapacity(segments.count)
        for seg in segments {
            confidenceById[seg.segmentId] = seg.confidence
            leastSureByCycle[seg.cycleId] = min(leastSureByCycle[seg.cycleId] ?? 1, seg.confidence)
        }

        let ordered = cycles.sorted { start(of: $0) < start(of: $1) }
        let fleetCycles = ordered.enumerated().map { index, c -> FleetCycle in
            let scoops = (c.scoops ?? []).sorted { $0.scoopNumber < $1.scoopNumber }
            let first = scoops.first?.startS ?? 0
            let passes = scoops.enumerated().map { k, p in
                FleetPass(
                    number: k + 1,
                    durationS: max(0, p.endS - p.startS),
                    cumulativeS: max(0, p.endS - first),
                    fillPct: Int((Double(k + 1) / Double(scoops.count) * 100).rounded()),
                    confidence: confidenceById[p.excavatorSegmentId]
                )
            }
            return FleetCycle(
                id: c.cycleId,
                recordingId: rec.recordingId,
                seq: index + 1,
                offsetS: start(of: c),
                truck: c.truckLabel,
                excavator: c.excavatorId,
                queueS: calc.extractQueueS(c) ?? 0,
                spotS: calc.extractSpotS(c) ?? 0,
                loadS: calc.extractLoadS(c) ?? 0,
                departS: calc.extractDepartS(c) ?? 0,
                passes: passes,
                confidence: leastSureByCycle[c.cycleId],
                isComplete: c.cycleStatus == CycleStatus.complete.rawValue
            )
        }

        let complete = ordered.filter { $0.cycleStatus == CycleStatus.complete.rawValue }
        func mean(_ f: (HaulCycleDTO) -> Double?) -> Double { calc.mean(complete.compactMap(f)) }
        let totals = complete.compactMap(calc.extractTotalCycleS)

        return FleetRecording(
            id: rec.recordingId,
            camera: rec.cameraId,
            section: sectionName,
            location: rec.locationTag,
            fileName: rec.filename,
            date: rec.startDate,
            durationS: rec.durationS,
            totalCycles: cycles.count,
            completeCycles: complete.count,
            meanPasses: calc.mean(contribution.passCounts),
            meanCycleS: calc.mean(totals),
            cycleSdS: calc.sampleStdDev(totals),
            meanQueueS: mean(calc.extractQueueS),
            meanLoadS: mean(calc.extractLoadS),
            meanSpotS: mean(calc.extractSpotS),
            excIdleMeanS: calc.mean(contribution.excavatorIdleDurations),
            excIdleSdS: calc.sampleStdDev(contribution.excavatorIdleDurations),
            truckIdleMeanS: calc.mean(contribution.truckIdleDurations),
            truckIdleSdS: calc.sampleStdDev(contribution.truckIdleDurations),
            excEEU: share(contribution.excavatorWorkS, of: contribution.excavatorInViewS),
            truckEEU: share(contribution.truckWorkS, of: contribution.truckInViewS),
            machines: machines(cycles: cycles, segments: segments, excavatorIds: excavatorIds),
            cycles: fleetCycles,
            meanDepartS: mean(calc.extractDepartS)
        )
    }

    /// When a visit starts in the video: arrival, or the first moment seen.
    private static func start(of c: HaulCycleDTO) -> Double {
        c.tArriveS ?? c.tSpotS ?? c.tLoadStartS ?? c.tLoadEndS ?? c.tDepartS ?? 0
    }

    private static func share(_ part: Double, of whole: Double) -> Double {
        whole > 0 ? min(100, max(0, part / whole * 100)) : 0
    }

    /// Each machine seen, with its own utilisation (working time over time in view) and mean idle stretch.
    private static func machines(cycles: [HaulCycleDTO], segments: [StateSegmentDTO], excavatorIds: Set<String>) -> [FleetMachine] {
        struct Tally { var work = 0.0, inView = 0.0, idle = 0.0, idleCount = 0 }
        var tallies: [String: Tally] = [:]
        for seg in segments {
            let dur = seg.durationS
            guard dur > 0, let state = seg.typedState, state != .outOfFrame else { continue }
            let isExcavator = TelemetryMetricsCalculator.isExcavatorMachine(seg.machineId, knownExcavators: excavatorIds)
            var t = tallies[seg.machineId] ?? Tally()
            t.inView += dur
            if isExcavator {
                switch state {
                case .loadingScoop, .facePrep: t.work += dur
                case .idle: t.idle += dur; t.idleCount += 1
                default: break
                }
            } else {
                switch state {
                case .spotting, .beingLoaded, .departing: t.work += dur
                case .idle, .queuingIdle: t.idle += dur; t.idleCount += 1
                default: break
                }
            }
            tallies[seg.machineId] = t
        }
        // Machines named by a cycle but without segments still appear, with no utilisation.
        for c in cycles {
            if tallies[c.excavatorId] == nil { tallies[c.excavatorId] = Tally() }
            if tallies[c.truckLabel] == nil { tallies[c.truckLabel] = Tally() }
        }
        return tallies.map { id, t in
            FleetMachine(
                id: id,
                isExcavator: TelemetryMetricsCalculator.isExcavatorMachine(id, knownExcavators: excavatorIds),
                eeu: share(t.work, of: t.inView),
                meanIdleS: t.idleCount > 0 ? t.idle / Double(t.idleCount) : 0
            )
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
