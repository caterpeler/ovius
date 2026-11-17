import Foundation
import Testing
@testable import Ovius

struct TelemetryMetricsCalculatorTests {
    @Test func idleAllowanceDiscountAppliesFiveMinuteRule() {
        let config = TelemetryCalculationConfig(idleThresholdS: 300)
        let recording = RecordingDTO(
            recordingId: "rec-1",
            filename: "clip.mp4",
            timestamp: "2026-11-16T08:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Bench",
            durationS: 3600,
            fps: 30,
            resolution: "1920x1080",
            tags: []
        )

        // Two contiguous idle segments totaling 420s -> 420 - 300 = 120s net excess.
        let seg1 = StateSegmentDTO(
            segmentId: "s1",
            recordingId: "rec-1",
            cycleId: "c1",
            cycleSortKey: nil,
            machineId: "TRK-01",
            scoopNumber: nil,
            state: "idle",
            startS: 100,
            endS: 300,
            confidence: 0.92
        )
        let seg2 = StateSegmentDTO(
            segmentId: "s2",
            recordingId: "rec-1",
            cycleId: "c1",
            cycleSortKey: nil,
            machineId: "TRK-01",
            scoopNumber: nil,
            state: "idle",
            startS: 300,
            endS: 520,
            confidence: 0.95
        )
        // Below threshold 250s -> 0s excess.
        let seg3 = StateSegmentDTO(
            segmentId: "s3",
            recordingId: "rec-1",
            cycleId: "c2",
            cycleSortKey: nil,
            machineId: "TRK-02",
            scoopNumber: nil,
            state: "idle",
            startS: 600,
            endS: 850,
            confidence: 0.61
        )

        let snapshot = TelemetryMetricsCalculator.computeSectionSnapshot(
            sectionId: "SEC_ALPHA",
            sectionName: "Section Alpha",
            recordings: [recording],
            cycles: [],
            segments: [seg1, seg2, seg3],
            config: config
        )

        #expect(abs(snapshot.value(for: .trueIdleExcessS) - 120.0) < 0.001)
        #expect(abs(snapshot.totalPostAllowanceIdleS - 120.0) < 0.001)
        // Business Rule 4.3: confidence < 0.70 tracked cleanly.
        #expect(snapshot.uncertainSegmentCount == 1)
    }

    @Test func incompleteCyclesAreExcludedFromPhaseAveragesAndNullifiedInAudit() {
        let config = TelemetryCalculationConfig(meanPayloadM3: 51.1)
        let recording = RecordingDTO(
            recordingId: "rec-1",
            filename: "clip.mp4",
            timestamp: "2026-11-16T08:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Bench",
            durationS: 3600,
            fps: 30,
            resolution: "1920x1080",
            tags: []
        )

        let completeCycle = HaulCycleDTO(
            recordingId: "rec-1",
            cycleId: "cyc-complete",
            excavatorId: "EXC-01",
            excavatorSortKey: nil,
            truckLabel: "DT-01",
            cycleStatus: "complete",
            tArriveS: 0,
            tSpotS: 20,
            tLoadStartS: 50,
            tLoadEndS: 170,
            tDepartS: 190,
            queueTimeS: 20,
            scoops: nil,
            truckSegments: nil
        )

        let incompleteCycle = HaulCycleDTO(
            recordingId: "rec-1",
            cycleId: "cyc-cut-off",
            excavatorId: "EXC-01",
            excavatorSortKey: nil,
            truckLabel: "DT-02",
            cycleStatus: "incomplete",
            tArriveS: 3400,
            tSpotS: 3500,
            tLoadStartS: 3540,
            tLoadEndS: 3600,
            tDepartS: nil,
            queueTimeS: 100,
            scoops: nil,
            truckSegments: nil
        )

        let snapshot = TelemetryMetricsCalculator.computeSectionSnapshot(
            sectionId: "SEC_ALPHA",
            sectionName: "Section Alpha",
            recordings: [recording],
            cycles: [completeCycle, incompleteCycle],
            segments: [],
            config: config
        )

        #expect(snapshot.completeCycleCount == 1)
        #expect(snapshot.incompleteCycleCount == 1)
        #expect(abs(snapshot.value(for: .avgQueueTimeS) - 20.0) < 0.001)
        #expect(abs(snapshot.value(for: .volumetricRateM3Hr) - 51.1) < 0.001)

        let cutOffRow = snapshot.cycleAuditRows.first { $0.cycleId == "cyc-cut-off" }
        #expect(cutOffRow != nil)
        #expect(cutOffRow?.isComplete == false)
        #expect(cutOffRow?.totalCycleDurationS == nil)
    }

    @Test func diagnosticEvaluatorTriggersOversupplyLeadFromRelativeDeltas() {
        let queueHighPattern = PatternRuleSpec(
            patternId: "PAT_HIGH_QUEUE_TIME",
            name: "High Queue",
            details: "Queue exceeds +35%",
            metricKey: .avgQueueTimeS,
            comparisonMode: .relativeDeltaPct,
            direction: .aboveBaseline,
            thresholdValue: 0.35
        )
        let normalLoadPattern = PatternRuleSpec(
            patternId: "PAT_NORMAL_LOAD_DURATION",
            name: "Nominal Load",
            details: "Within band",
            metricKey: .avgLoadDurationS,
            comparisonMode: .zScore,
            direction: .withinBand,
            thresholdValue: 1.5
        )

        let leadSpec = LeadRuleSpec(
            leadId: "LEAD_DUMPTRUCK_OVERSUPPLY",
            name: "Dumptruck Oversupply",
            category: "Fleet Balance",
            details: "Too many trucks",
            requiredPatternIds: ["PAT_HIGH_QUEUE_TIME"],
            supportingPatternIds: ["PAT_NORMAL_LOAD_DURATION"]
        )

        let alpha = SectionMetricsSnapshot(
            sectionId: "ALPHA",
            sectionName: "Alpha",
            recordingCount: 1,
            totalCameraHours: 10,
            totalCycleCount: 10,
            completeCycleCount: 10,
            incompleteCycleCount: 0,
            totalSegmentCount: 10,
            uncertainSegmentCount: 0,
            totalVolumeM3: 511,
            struckVolumeM3: 421,
            heapedVolumeM3: 601,
            avgCycleDurationS: 200,
            totalPostAllowanceIdleS: 0,
            metricValues: [.avgQueueTimeS: 100, .avgLoadDurationS: 120],
            queueTimeHistogram: [],
            interArrivalGapHistogram: [],
            hourlySeries: [],
            ganttSegments: [],
            cycleAuditRows: []
        )
        let beta = SectionMetricsSnapshot(
            sectionId: "BETA",
            sectionName: "Beta",
            recordingCount: 1,
            totalCameraHours: 10,
            totalCycleCount: 10,
            completeCycleCount: 10,
            incompleteCycleCount: 0,
            totalSegmentCount: 10,
            uncertainSegmentCount: 0,
            totalVolumeM3: 511,
            struckVolumeM3: 421,
            heapedVolumeM3: 601,
            avgCycleDurationS: 140,
            totalPostAllowanceIdleS: 0,
            metricValues: [.avgQueueTimeS: 20, .avgLoadDurationS: 118],
            queueTimeHistogram: [],
            interArrivalGapHistogram: [],
            hourlySeries: [],
            ganttSegments: [],
            cycleAuditRows: []
        )

        let baseline = TelemetryMetricsCalculator.computeClusterBaseline(
            clusterId: "C1",
            sectionSnapshots: [alpha, beta]
        )
        let patResults = DiagnosticEvaluator.evaluatePatterns(
            [queueHighPattern, normalLoadPattern],
            snapshot: alpha,
            baseline: baseline
        )
        let leadResults = DiagnosticEvaluator.evaluateLeads([leadSpec], patternResults: patResults)

        #expect(leadResults.count == 1)
        #expect(leadResults[0].isFlagged == true)
        #expect(leadResults[0].confidenceScore == 1.0)
    }

    @Test func subSecondMergedBreakOverrunAndIntervalSlicingComputeExactMetrics() {
        let config = TelemetryCalculationConfig(
            meanPayloadM3: 51.1,
            idleThresholdS: 300,
            shiftEdgeWindowMin: 60,
            shiftStartHours: ["06:00"],
            breakWindows: ["12:00-13:00"]
        )
        // Staggered clip starting at 06:30:00Z (halfway through 06:00-07:00 shift edge).
        let recording = RecordingDTO(
            recordingId: "rec-subsec",
            filename: "staggered.mp4",
            timestamp: "2026-11-16T06:30:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Pocket",
            durationS: 7 * 3600,
            fps: 25,
            resolution: "1920x1080",
            tags: []
        )

        // Two contiguous idle intervals on E4 (no cycles!) crossing from 12:55Z to 13:10:28.3Z (628.3s overrun).
        let idlePart1 = StateSegmentDTO(
            segmentId: "s-p1",
            recordingId: "rec-subsec",
            cycleId: "NONE",
            cycleSortKey: nil,
            machineId: "E4",
            scoopNumber: nil,
            state: "idle",
            startS: (6 * 3600) + 1500.0, // 12:55:00Z
            endS: (6 * 3600) + 1800.0,   // 13:00:00Z
            confidence: 0.92
        )
        let idlePart2 = StateSegmentDTO(
            segmentId: "s-p2",
            recordingId: "rec-subsec",
            cycleId: "NONE",
            cycleSortKey: nil,
            machineId: "E4",
            scoopNumber: nil,
            state: "idle",
            startS: (6 * 3600) + 1800.0,   // 13:00:00Z
            endS: (6 * 3600) + 2428.3,     // 13:10:28.3Z
            confidence: 0.93
        )
        // Edge segment spanning across 07:00:00Z boundary (06:45Z -> 07:15Z): 15m inside edge, 15m outside.
        let spanEdgeLoading = StateSegmentDTO(
            segmentId: "s-span",
            recordingId: "rec-subsec",
            cycleId: "c1",
            cycleSortKey: nil,
            machineId: "E4",
            scoopNumber: nil,
            state: "loading_scoop",
            startS: 900.0,  // 06:45Z
            endS: 2700.0,   // 07:15Z
            confidence: 0.95
        )

        let snapshot = TelemetryMetricsCalculator.computeSectionSnapshot(
            sectionId: "ALPHA",
            sectionName: "Alpha",
            recordings: [recording],
            cycles: [],
            segments: [spanEdgeLoading, idlePart1, idlePart2],
            config: config
        )

        // Exact sub-second merged break overrun past 13:00:00Z = 628.3s.
        #expect(abs(snapshot.value(for: .breakWindowIdleExcessS) - 628.3) < 0.05)
        // Hourly delay bucket 12:00Z receives 300s (12:55..13:00) and 13:00Z receives 628.3s (not 100% into midpoint).
        let hr12 = snapshot.hourlySeries.first { $0.hourUTC == 12 }
        let hr13 = snapshot.hourlySeries.first { $0.hourUTC == 13 }
        #expect(abs((hr12?.delayDurationS ?? 0) - 300.0) < 0.05)
        #expect(abs((hr13?.delayDurationS ?? 0) - 628.3) < 0.05)
        // E4 recognized as excavator without cycles: hang ratio = 928.3 / (1800 + 928.3).
        #expect(abs(snapshot.value(for: .excavatorHangRatio) - (928.3 / 2728.3)) < 0.001)

        // Single-section baseline (< 2 peers) must mark relative/Z patterns as insufficient data rather than normal.
        let singleBaseline = TelemetryMetricsCalculator.computeClusterBaseline(
            clusterId: "C_SINGLE",
            sectionSnapshots: [snapshot]
        )
        let normalPattern = PatternRuleSpec(
            patternId: "PAT_NORMAL_DEPARTURE",
            name: "Nominal Departure",
            details: "Within band",
            metricKey: .avgDepartureLagS,
            comparisonMode: .zScore,
            direction: .withinBand,
            thresholdValue: 0.6
        )
        let eval = DiagnosticEvaluator.evaluatePattern(normalPattern, snapshot: snapshot, baseline: singleBaseline)
        #expect(eval.hasInsufficientData == true)
        #expect(eval.isTriggered == false)
    }

    @Test func intraDaySliceAndThreeLayerExplorerBuildersEnforceRulesAndRates() {
        let config = TelemetryCalculationConfig(meanPayloadM3: 51.1)
        let recording = RecordingDTO(
            recordingId: "rec-slice",
            filename: "shift12h.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Bench 1",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Alpha"]
        )

        let earlyCycle = HaulCycleDTO(
            recordingId: "rec-slice",
            cycleId: "cyc-1",
            excavatorId: "E5",
            excavatorSortKey: nil,
            truckLabel: "T1",
            cycleStatus: "complete",
            tArriveS: 100,
            tSpotS: 120,
            tLoadStartS: 140,
            tLoadEndS: 240,
            tDepartS: 260,
            queueTimeS: 20,
            scoops: [
                ScoopTimingDTO(scoopNumber: 1, excavatorSegmentId: "s-sc1", startS: 140, dumpS: 155, endS: 170),
                ScoopTimingDTO(scoopNumber: 2, excavatorSegmentId: "s-sc2", startS: 185, dumpS: 210, endS: 240),
            ],
            truckSegments: ["s-trk1"]
        )
        let laterIncompleteCycle = HaulCycleDTO(
            recordingId: "rec-slice",
            cycleId: "cyc-2",
            excavatorId: "E5",
            excavatorSortKey: nil,
            truckLabel: "T2",
            cycleStatus: "incomplete",
            tArriveS: 5000,
            tSpotS: 5050,
            tLoadStartS: 5080,
            tLoadEndS: nil,
            tDepartS: nil,
            queueTimeS: 50,
            scoops: nil,
            truckSegments: nil
        )
        let segs = [
            StateSegmentDTO(segmentId: "s-sc1", recordingId: "rec-slice", cycleId: "cyc-1", cycleSortKey: nil, machineId: "E5", scoopNumber: 1, state: "loading_scoop", startS: 140, endS: 170, confidence: 0.91),
            StateSegmentDTO(segmentId: "s-trk1", recordingId: "rec-slice", cycleId: "cyc-1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "being_loaded", startS: 140, endS: 240, confidence: 0.62),
        ]

        // Slice strictly to Startup Edge [0..3600s] (1 camera-hour).
        let edgeSnap = TelemetryMetricsCalculator.computeSectionSnapshot(
            sectionId: "ALPHA",
            sectionName: "Alpha",
            recordings: [recording],
            cycles: [earlyCycle, laterIncompleteCycle],
            segments: segs,
            config: config,
            todStartS: 0,
            todEndS: 3600
        )
        #expect(edgeSnap.totalCycleCount == 1)
        #expect(abs(edgeSnap.totalCameraHours - 1.0) < 0.001)
        #expect(abs(edgeSnap.value(for: .volumetricRateM3Hr) - 51.1) < 0.001)

        // Layer 1 Explorer Row
        let l1 = DataExplorerBuilder.buildRecordingRows(
            recordings: [recording],
            sectionNamesByRecordingId: ["rec-slice": ("SEC_ALPHA", "Section Alpha")],
            cycles: [earlyCycle, laterIncompleteCycle],
            todStartS: 0,
            todEndS: 43_200,
            config: config
        )
        #expect(l1.count == 1)
        #expect(l1[0].totalCycleCount == 2)
        #expect(l1[0].completeCycleCount == 1)
        #expect(abs(l1[0].totalVolumeM3 - 51.1) < 0.001)

        // Layer 2 Explorer Rows (Rule 4.2 + Rule 4.3)
        let l2 = DataExplorerBuilder.buildCycleRows(
            cycles: [earlyCycle, laterIncompleteCycle],
            segments: segs,
            todStartS: nil,
            todEndS: nil,
            config: config
        )
        #expect(l2.count == 2)
        #expect(l2[0].uncertainSegmentCount == 1)
        #expect(l2[1].isComplete == false)
        #expect(l2[1].totalCycleDurationS == nil)

        // Layer 3 State Timing & Scoop Pass Rows
        let l3 = DataExplorerBuilder.buildStateTimingRows(
            recording: recording,
            cycle: earlyCycle,
            allRecordingSegments: segs,
            todStartS: 0,
            todEndS: 3600,
            config: config
        )
        #expect(l3.segments.count == 2)
        #expect(l3.segments[0].machineRole == "Excavator")
        #expect(l3.segments[1].machineRole == "Truck")
        #expect(l3.segments[1].isUncertain == true)
        #expect(l3.scoops.count == 2)
        #expect(abs((l3.scoops[1].interScoopGapS ?? 0) - 15.0) < 0.001)
    }

    @Test func breakFilterPreservesPostBreakOverrunWhileNonBreakSliceClearsIt() throws {
        let config = TelemetryCalculationConfig(
            meanPayloadM3: 51.1,
            idleThresholdS: 300,
            shiftEdgeWindowMin: 60,
            shiftStartHours: ["06:00"],
            breakWindows: ["12:00-13:00"]
        )
        let recording = RecordingDTO(
            recordingId: "rec-break-slice",
            filename: "shift_alpha.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Bench Alpha",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: []
        )
        // Idle spell starts at 12:00Z (21600s) and runs until 13:10:28.3Z (25828.3s) -> 628.3s break overrun.
        let breakIdle = StateSegmentDTO(
            segmentId: "s-brk",
            recordingId: "rec-break-slice",
            cycleId: "NONE",
            cycleSortKey: nil,
            machineId: "EXC-01",
            scoopNumber: nil,
            state: "idle",
            startS: 21_600.0,
            endS: 25_828.3,
            confidence: 0.94
        )
        let earlyLoad = StateSegmentDTO(
            segmentId: "s-early",
            recordingId: "rec-break-slice",
            cycleId: "c1",
            cycleSortKey: nil,
            machineId: "EXC-01",
            scoopNumber: nil,
            state: "loading_scoop",
            startS: 100.0,
            endS: 200.0,
            confidence: 0.95
        )

        // Filtering strictly on Break (12:00-13:00 UTC) must retain the post-13:00 recovery overrun.
        let breakSliceSnap = TelemetryMetricsCalculator.computeSectionSnapshot(
            sectionId: "ALPHA",
            sectionName: "Alpha",
            recordings: [recording],
            cycles: [],
            segments: [earlyLoad, breakIdle],
            config: config,
            todStartS: 21_600,
            todEndS: 25_200,
            todBaseMinuteUTC: 360
        )
        #expect(abs(breakSliceSnap.value(for: .breakWindowIdleExcessS) - 628.3) < 0.05)

        // Filtering strictly on Startup Edge (06:00-07:00 UTC) does not intersect 12:00-13:00 break -> 0s overrun.
        let edgeSliceSnap = TelemetryMetricsCalculator.computeSectionSnapshot(
            sectionId: "ALPHA",
            sectionName: "Alpha",
            recordings: [recording],
            cycles: [],
            segments: [earlyLoad, breakIdle],
            config: config,
            todStartS: 0,
            todEndS: 3_600,
            todBaseMinuteUTC: 360
        )
        #expect(edgeSliceSnap.value(for: .breakWindowIdleExcessS) == 0.0)
    }

    @Test func wallClockSlicingAndSection51ComparativeBreakdownsStayAccurate() {
        let config = TelemetryCalculationConfig(shiftStartHours: ["06:00"], breakWindows: ["12:00-13:00"])
        // Clip starts 06:30:00Z -> only 0.5h overlaps 06:00-07:00 UTC wall clock window.
        let staggeredRec = RecordingDTO(
            recordingId: "rec-stag",
            filename: "stag.mp4",
            timestamp: "2026-11-16T06:30:00Z",
            cameraId: "CAM-BETA-01",
            locationTag: "Pit Beta",
            durationS: 7200,
            fps: 25,
            resolution: "1920x1080",
            tags: []
        )
        let cycInWindow = HaulCycleDTO(
            recordingId: "rec-stag",
            cycleId: "c-in",
            excavatorId: "EXC-01",
            excavatorSortKey: nil,
            truckLabel: "DT-01",
            cycleStatus: "complete",
            tArriveS: 100,  // 06:31:40Z
            tSpotS: 200,
            tLoadStartS: 230,
            tLoadEndS: 330,
            tDepartS: 350,
            queueTimeS: 100,
            scoops: nil,
            truckSegments: nil
        )
        // Second truck arrives while DT-01 is still queuing -> queue depth 1.
        let cycOverlap = HaulCycleDTO(
            recordingId: "rec-stag",
            cycleId: "c-overlap",
            excavatorId: "EXC-01",
            excavatorSortKey: nil,
            truckLabel: "DT-02",
            cycleStatus: "complete",
            tArriveS: 150,  // 06:32:30Z
            tSpotS: 220,
            tLoadStartS: 340,
            tLoadEndS: 440,
            tDepartS: 460,
            queueTimeS: 70,
            scoops: nil,
            truckSegments: nil
        )
        let cycOutOfWindow = HaulCycleDTO(
            recordingId: "rec-stag",
            cycleId: "c-out",
            excavatorId: "EXC-01",
            excavatorSortKey: nil,
            truckLabel: "DT-03",
            cycleStatus: "complete",
            tArriveS: 2400, // 07:10:00Z (outside 06:00-07:00 UTC)
            tSpotS: 2420,
            tLoadStartS: 2450,
            tLoadEndS: 2550,
            tDepartS: 2570,
            queueTimeS: 20,
            scoops: nil,
            truckSegments: nil
        )
        let segs = [
            StateSegmentDTO(segmentId: "s1", recordingId: "rec-stag", cycleId: "c-in", cycleSortKey: nil, machineId: "EXC-01", scoopNumber: nil, state: "loading_scoop", startS: 230, endS: 330, confidence: 0.95),
            StateSegmentDTO(segmentId: "s2", recordingId: "rec-stag", cycleId: "NONE", cycleSortKey: nil, machineId: "EXC-01", scoopNumber: nil, state: "idle", startS: 0, endS: 200, confidence: 0.95),
            StateSegmentDTO(segmentId: "s3", recordingId: "rec-stag", cycleId: "c-in", cycleSortKey: nil, machineId: "DT-01", scoopNumber: nil, state: "queuing_idle", startS: 100, endS: 200, confidence: 0.95),
            StateSegmentDTO(segmentId: "s4", recordingId: "rec-stag", cycleId: "c-overlap", cycleSortKey: nil, machineId: "DT-02", scoopNumber: nil, state: "queuing_idle", startS: 150, endS: 220, confidence: 0.95),
        ]

        let snap = TelemetryMetricsCalculator.computeSectionSnapshot(
            sectionId: "BETA",
            sectionName: "Beta",
            recordings: [staggeredRec],
            cycles: [cycInWindow, cycOverlap, cycOutOfWindow],
            segments: segs,
            config: config,
            todStartS: 0,
            todEndS: 3_600,
            todBaseMinuteUTC: 360
        )

        #expect(abs(snap.totalCameraHours - 0.5) < 0.001)
        #expect(snap.totalCycleCount == 2)
        #expect(snap.queueDepthSummary.zero == 1)
        #expect(snap.queueDepthSummary.one == 1)
        #expect(snap.excavatorPocketSplit.emptyPocketIdleS >= 199.0)
        #expect(snap.excavatorPocketSplit.spottedActiveS >= 99.0)

        let drill = TelemetryMetricsCalculator.extractDrilldown(
            cycles: [cycInWindow, cycOverlap],
            segments: segs,
            config: config
        )
        #expect(drill.audit.queueOverlapPct > 0)
        #expect(drill.conflicts.isEmpty == false)
    }
}
