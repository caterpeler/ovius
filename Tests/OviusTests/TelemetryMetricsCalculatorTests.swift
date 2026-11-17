import Foundation
import Testing
@testable import Ovius

struct TelemetryMetricsCalculatorTests {
    @Test func dashboardMetricsComputeCompleteCycleStatsAndMeanPassesPerCycle() {
        let rec1 = RecordingDTO(
            recordingId: "rec-1",
            filename: "clip1.mp4",
            timestamp: "2026-11-16T08:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Bench",
            durationS: 3600,
            fps: 30,
            resolution: "1920x1080",
            tags: []
        )
        let rec2 = RecordingDTO(
            recordingId: "rec-2",
            filename: "clip2.mp4",
            timestamp: "2026-11-16T10:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Bench",
            durationS: 3600,
            fps: 30,
            resolution: "1920x1080",
            tags: []
        )

        // Complete cycles: durations 180s (3 passes), 200s (4 passes), 220s (5 passes).
        // Incomplete cycle should be excluded from mean/stdev cycle time & passes.
        let c1 = HaulCycleDTO(
            recordingId: "rec-1",
            cycleId: "c1",
            excavatorId: "E1",
            excavatorSortKey: nil,
            truckLabel: "T1",
            cycleStatus: "complete",
            tArriveS: 0,
            tSpotS: 20,
            tLoadStartS: 40,
            tLoadEndS: 160,
            tDepartS: 180,
            queueTimeS: 20,
            scoops: [
                ScoopTimingDTO(scoopNumber: 1, excavatorSegmentId: "s1", startS: 40, dumpS: 60, endS: 75),
                ScoopTimingDTO(scoopNumber: 2, excavatorSegmentId: "s2", startS: 80, dumpS: 100, endS: 115),
                ScoopTimingDTO(scoopNumber: 3, excavatorSegmentId: "s3", startS: 120, dumpS: 140, endS: 160),
            ],
            truckSegments: nil
        )
        let c2 = HaulCycleDTO(
            recordingId: "rec-1",
            cycleId: "c2",
            excavatorId: "E1",
            excavatorSortKey: nil,
            truckLabel: "T2",
            cycleStatus: "complete",
            tArriveS: 300,
            tSpotS: 320,
            tLoadStartS: 340,
            tLoadEndS: 480,
            tDepartS: 500,
            queueTimeS: 20,
            scoops: [
                ScoopTimingDTO(scoopNumber: 1, excavatorSegmentId: "s4", startS: 340, dumpS: 360, endS: 375),
                ScoopTimingDTO(scoopNumber: 2, excavatorSegmentId: "s5", startS: 380, dumpS: 400, endS: 410),
                ScoopTimingDTO(scoopNumber: 3, excavatorSegmentId: "s6", startS: 415, dumpS: 435, endS: 445),
                ScoopTimingDTO(scoopNumber: 4, excavatorSegmentId: "s7", startS: 450, dumpS: 470, endS: 480),
            ],
            truckSegments: nil
        )
        let c3 = HaulCycleDTO(
            recordingId: "rec-2",
            cycleId: "c3",
            excavatorId: "E1",
            excavatorSortKey: nil,
            truckLabel: "T1",
            cycleStatus: "complete",
            tArriveS: 100,
            tSpotS: 120,
            tLoadStartS: 140,
            tLoadEndS: 300,
            tDepartS: 320,
            queueTimeS: 20,
            scoops: (1...5).map { idx in
                ScoopTimingDTO(scoopNumber: idx, excavatorSegmentId: "s3-\(idx)", startS: 140, dumpS: 150, endS: 160)
            },
            truckSegments: nil
        )
        let cIncomplete = HaulCycleDTO(
            recordingId: "rec-2",
            cycleId: "c-inc",
            excavatorId: "E1",
            excavatorSortKey: nil,
            truckLabel: "T3",
            cycleStatus: "incomplete",
            tArriveS: 3400,
            tSpotS: 3420,
            tLoadStartS: 3450,
            tLoadEndS: 3580,
            tDepartS: nil,
            queueTimeS: 20,
            scoops: [
                ScoopTimingDTO(scoopNumber: 1, excavatorSegmentId: "s-inc", startS: 3450, dumpS: 3465, endS: 3480),
            ],
            truckSegments: nil
        )

        let summary = TelemetryMetricsCalculator.computeDashboardMetrics(
            recordings: [rec1, rec2],
            cycles: [c1, c2, c3, cIncomplete],
            segments: []
        )

        #expect(summary.recordingCount == 2)
        #expect(summary.completeCycleCount == 3)
        #expect(summary.totalCycleCount == 4)
        #expect(abs(summary.meanCyclesPerRecording - 1.5) < 0.001)
        #expect(abs(summary.meanPassesPerCycle - 4.0) < 0.001)
        #expect(abs(summary.meanCycleTimeS - 200.0) < 0.001)
        // Sample stdev of [180, 200, 220] = sqrt((400 + 0 + 400) / 2) = 20.0
        #expect(abs(summary.cycleTimeStdDevS - 20.0) < 0.001)
    }

    @Test func dashboardMetricsComputePerEquipmentIdleAndEEUExcludingOutOfFrame() {
        let rec = RecordingDTO(
            recordingId: "rec-util",
            filename: "util.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Pocket",
            durationS: 1000,
            fps: 25,
            resolution: "1920x1080",
            tags: []
        )

        // Excavator E1:
        // Active: 100s loading_scoop + 40s face_prep = 140s
        // Idle: contiguous [10..30] + [30..60] -> merged 50s spell, plus separate [100..110] -> 10s spell
        // Out of frame: 500s (ignored in EEU denominator)
        // Expected Excavator Mean Idle = 30.0s, Sample Stdev = sqrt(800) = 28.28427s, EEU = 140 / 200 = 0.70
        let segments: [StateSegmentDTO] = [
            StateSegmentDTO(segmentId: "e-load", recordingId: "rec-util", cycleId: "c1", cycleSortKey: nil, machineId: "E1", scoopNumber: 1, state: "loading_scoop", startS: 200, endS: 300, confidence: 0.95),
            StateSegmentDTO(segmentId: "e-prep", recordingId: "rec-util", cycleId: "NONE", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "face_prep", startS: 300, endS: 340, confidence: 0.90),
            StateSegmentDTO(segmentId: "e-idle-1a", recordingId: "rec-util", cycleId: "NONE", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "idle", startS: 10, endS: 30, confidence: 0.92),
            StateSegmentDTO(segmentId: "e-idle-1b", recordingId: "rec-util", cycleId: "NONE", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "idle", startS: 30, endS: 60, confidence: 0.92),
            StateSegmentDTO(segmentId: "e-idle-2", recordingId: "rec-util", cycleId: "NONE", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "idle", startS: 100, endS: 110, confidence: 0.91),
            StateSegmentDTO(segmentId: "e-oof", recordingId: "rec-util", cycleId: "NONE", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "out_of_frame", startS: 400, endS: 900, confidence: 0.99),

            // Truck T1:
            // Active: spotting (20s) + being_loaded (80s) + departing (20s) = 120s
            // Idle: queuing_idle (30s) + separate idle (50s) = 80s total across 2 spells -> Mean = 40.0s, Sample Stdev = sqrt(200)
            // Out of frame: 300s (ignored in EEU denominator) -> Truck EEU = 120 / 200 = 0.60
            StateSegmentDTO(segmentId: "t-queue", recordingId: "rec-util", cycleId: "c1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "queuing_idle", startS: 150, endS: 180, confidence: 0.93),
            StateSegmentDTO(segmentId: "t-spot", recordingId: "rec-util", cycleId: "c1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "spotting", startS: 180, endS: 200, confidence: 0.94),
            StateSegmentDTO(segmentId: "t-load", recordingId: "rec-util", cycleId: "c1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "being_loaded", startS: 200, endS: 280, confidence: 0.96),
            StateSegmentDTO(segmentId: "t-dep", recordingId: "rec-util", cycleId: "c1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "departing", startS: 280, endS: 300, confidence: 0.95),
            StateSegmentDTO(segmentId: "t-idle", recordingId: "rec-util", cycleId: "NONE", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "idle", startS: 350, endS: 400, confidence: 0.90),
            StateSegmentDTO(segmentId: "t-oof", recordingId: "rec-util", cycleId: "NONE", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "out_of_frame", startS: 600, endS: 900, confidence: 0.99),
        ]

        let summary = TelemetryMetricsCalculator.computeDashboardMetrics(
            recordings: [rec],
            cycles: [],
            segments: segments
        )

        #expect(summary.excavatorIdleSpellCount == 2)
        #expect(abs(summary.excavatorMeanIdleS - 30.0) < 0.001)
        #expect(abs(summary.excavatorIdleStdDevS - sqrt(800.0)) < 0.001)
        #expect(summary.truckIdleSpellCount == 2)
        #expect(abs(summary.truckMeanIdleS - 40.0) < 0.001)
        #expect(abs(summary.truckIdleStdDevS - sqrt(200.0)) < 0.001)
        #expect(abs((summary.excavatorEEU ?? 0) - 0.70) < 0.001)
        #expect(abs((summary.truckEEU ?? 0) - 0.60) < 0.001)
    }

    @Test func dataExplorerBuildersEnforceRuleFourPointTwoAndThree() {
        let recording = RecordingDTO(
            recordingId: "rec-exp",
            filename: "shift12h.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Bench 1",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Alpha"]
        )

        let completeCycle = HaulCycleDTO(
            recordingId: "rec-exp",
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
        let incompleteCycle = HaulCycleDTO(
            recordingId: "rec-exp",
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
            StateSegmentDTO(segmentId: "s-sc1", recordingId: "rec-exp", cycleId: "cyc-1", cycleSortKey: nil, machineId: "E5", scoopNumber: 1, state: "loading_scoop", startS: 140, endS: 170, confidence: 0.91),
            StateSegmentDTO(segmentId: "s-trk1", recordingId: "rec-exp", cycleId: "cyc-1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "being_loaded", startS: 140, endS: 240, confidence: 0.62),
        ]

        // Layer 1 Explorer Row
        let l1 = DataExplorerBuilder.buildRecordingRows(
            recordings: [recording],
            sectionNamesByRecordingId: ["rec-exp": ("SEC_ALPHA", "Section Alpha")],
            cycles: [completeCycle, incompleteCycle]
        )
        #expect(l1.count == 1)
        #expect(l1[0].totalCycleCount == 2)
        #expect(l1[0].completeCycleCount == 1)
        #expect(l1[0].incompleteCycleCount == 1)
        #expect(abs(l1[0].avgPassesPerCycle - 2.0) < 0.001)
        #expect(abs(l1[0].avgTotalCycleS - 160.0) < 0.001)

        // Layer 2 Explorer Rows (Rule 4.2 + Rule 4.3)
        let l2 = DataExplorerBuilder.buildCycleRows(
            cycles: [completeCycle, incompleteCycle],
            segments: segs
        )
        #expect(l2.count == 2)
        #expect(l2[0].uncertainSegmentCount == 1)
        #expect(l2[0].scoopCount == 2)
        #expect(l2[1].isComplete == false)
        #expect(l2[1].totalCycleDurationS == nil)

        // Layer 3 State Timing & Scoop Pass Rows
        let l3 = DataExplorerBuilder.buildStateTimingRows(
            cycle: completeCycle,
            allRecordingSegments: segs
        )
        #expect(l3.segments.count == 2)
        #expect(l3.segments[0].machineRole == "Excavator")
        #expect(l3.segments[1].machineRole == "Truck")
        #expect(l3.segments[1].isUncertain == true)
        #expect(l3.scoops.count == 2)
        #expect(abs((l3.scoops[1].interScoopGapS ?? 0) - 15.0) < 0.001)
    }

    @Test func recordingDTOPreparsesStartDateAndFormattedLabel() throws {
        let recZ = RecordingDTO(
            recordingId: "rec-z",
            filename: "z.mp4",
            timestamp: "2026-11-16T08:05:30Z",
            cameraId: "CAM-01",
            locationTag: "Bench",
            durationS: 600,
            fps: 25,
            resolution: "1920x1080",
            tags: []
        )
        let recFracOffset = RecordingDTO(
            recordingId: "rec-off",
            filename: "off.mp4",
            timestamp: "2026-11-16T15:05:30.125+07:00",
            cameraId: "CAM-01",
            locationTag: "Bench",
            durationS: 600,
            fps: 25,
            resolution: "1920x1080",
            tags: []
        )

        let dateZ = try #require(recZ.startDate)
        let dateOff = try #require(recFracOffset.startDate)
        #expect(abs(dateZ.timeIntervalSince1970 - dateOff.timeIntervalSince1970) < 1.0)
        #expect(recZ.formattedTimestampLabel.isEmpty == false)
        #expect(recZ.formattedTimestampLabel == OviusFormat.utcDateTime(dateZ))
    }

    @Test func precomputedRecordingContributionsMatchFullDashboardCalculation() {
        let rec1 = RecordingDTO(
            recordingId: "rec-1",
            filename: "clip1.mp4",
            timestamp: "2026-11-16T08:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Bench",
            durationS: 3600,
            fps: 30,
            resolution: "1920x1080",
            tags: []
        )
        let rec2 = RecordingDTO(
            recordingId: "rec-2",
            filename: "clip2.mp4",
            timestamp: "2026-11-16T10:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Bench",
            durationS: 3600,
            fps: 30,
            resolution: "1920x1080",
            tags: []
        )

        let c1 = HaulCycleDTO(
            recordingId: "rec-1",
            cycleId: "c1",
            excavatorId: "E1",
            excavatorSortKey: nil,
            truckLabel: "T1",
            cycleStatus: "complete",
            tArriveS: 0,
            tSpotS: 20,
            tLoadStartS: 40,
            tLoadEndS: 160,
            tDepartS: 180,
            queueTimeS: 20,
            scoops: [
                ScoopTimingDTO(scoopNumber: 1, excavatorSegmentId: "s1", startS: 40, dumpS: 60, endS: 75),
                ScoopTimingDTO(scoopNumber: 2, excavatorSegmentId: "s2", startS: 80, dumpS: 100, endS: 115),
            ],
            truckSegments: nil
        )
        let c2 = HaulCycleDTO(
            recordingId: "rec-2",
            cycleId: "c2",
            excavatorId: "E1",
            excavatorSortKey: nil,
            truckLabel: "T2",
            cycleStatus: "complete",
            tArriveS: 100,
            tSpotS: 120,
            tLoadStartS: 140,
            tLoadEndS: 300,
            tDepartS: 340,
            queueTimeS: 20,
            scoops: (1...4).map { idx in
                ScoopTimingDTO(scoopNumber: idx, excavatorSegmentId: "s2-\(idx)", startS: 140, dumpS: 150, endS: 160)
            },
            truckSegments: nil
        )

        let segs1 = [
            StateSegmentDTO(segmentId: "e1-w", recordingId: "rec-1", cycleId: "c1", cycleSortKey: nil, machineId: "E1", scoopNumber: 1, state: "loading_scoop", startS: 40, endS: 160, confidence: 0.95),
            StateSegmentDTO(segmentId: "e1-i", recordingId: "rec-1", cycleId: "NONE", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "idle", startS: 200, endS: 240, confidence: 0.90),
            StateSegmentDTO(segmentId: "t1-w", recordingId: "rec-1", cycleId: "c1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "being_loaded", startS: 40, endS: 160, confidence: 0.96),
            StateSegmentDTO(segmentId: "t1-i", recordingId: "rec-1", cycleId: "c1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "queuing_idle", startS: 0, endS: 20, confidence: 0.92),
        ]
        let segs2 = [
            StateSegmentDTO(segmentId: "e2-w", recordingId: "rec-2", cycleId: "c2", cycleSortKey: nil, machineId: "E1", scoopNumber: 1, state: "loading_scoop", startS: 140, endS: 300, confidence: 0.94),
            StateSegmentDTO(segmentId: "e2-i", recordingId: "rec-2", cycleId: "NONE", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "idle", startS: 350, endS: 410, confidence: 0.91),
            StateSegmentDTO(segmentId: "t2-w", recordingId: "rec-2", cycleId: "c2", cycleSortKey: nil, machineId: "T2", scoopNumber: nil, state: "being_loaded", startS: 140, endS: 300, confidence: 0.95),
            StateSegmentDTO(segmentId: "t2-i", recordingId: "rec-2", cycleId: "c2", cycleSortKey: nil, machineId: "T2", scoopNumber: nil, state: "queuing_idle", startS: 100, endS: 140, confidence: 0.93),
        ]

        let full = TelemetryMetricsCalculator.computeDashboardMetrics(
            recordings: [rec1, rec2],
            cycles: [c1, c2],
            segments: segs1 + segs2
        )
        let contrib1 = TelemetryMetricsCalculator.computeRecordingContribution(recordingId: "rec-1", cycles: [c1], segments: segs1)
        let contrib2 = TelemetryMetricsCalculator.computeRecordingContribution(recordingId: "rec-2", cycles: [c2], segments: segs2)
        let combined = TelemetryMetricsCalculator.combineContributions([contrib1, contrib2], recordingCount: 2)

        #expect(combined.recordingCount == full.recordingCount)
        #expect(combined.completeCycleCount == full.completeCycleCount)
        #expect(abs(combined.meanCyclesPerRecording - full.meanCyclesPerRecording) < 0.0001)
        #expect(abs(combined.meanPassesPerCycle - full.meanPassesPerCycle) < 0.0001)
        #expect(abs(combined.meanCycleTimeS - full.meanCycleTimeS) < 0.0001)
        #expect(abs(combined.cycleTimeStdDevS - full.cycleTimeStdDevS) < 0.0001)
        #expect(abs(combined.excavatorMeanIdleS - full.excavatorMeanIdleS) < 0.0001)
        #expect(abs(combined.excavatorIdleStdDevS - full.excavatorIdleStdDevS) < 0.0001)
        #expect(abs(combined.truckMeanIdleS - full.truckMeanIdleS) < 0.0001)
        #expect(abs(combined.truckIdleStdDevS - full.truckIdleStdDevS) < 0.0001)
        #expect(abs((combined.excavatorEEU ?? 0) - (full.excavatorEEU ?? 0)) < 0.0001)
        #expect(abs((combined.truckEEU ?? 0) - (full.truckEEU ?? 0)) < 0.0001)
    }

    @Test func telemetryDiskCacheRoundtripsCompressedPayloadsAndClearsOnDemand() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ovius-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cache = TelemetryDiskCache(directory: tempDir, isEnabled: true)
        let nsA = "https://env-a.example.com/api/v1"
        let nsB = "https://env-b.example.com/api/v1"

        let cycles = [
            HaulCycleDTO(
                recordingId: "rec-cache-1",
                cycleId: "c-cache-1",
                excavatorId: "E1",
                excavatorSortKey: nil,
                truckLabel: "T1",
                cycleStatus: "complete",
                tArriveS: 10,
                tSpotS: 25,
                tLoadStartS: 40,
                tLoadEndS: 140,
                tDepartS: 160,
                queueTimeS: 15,
                scoops: [ScoopTimingDTO(scoopNumber: 1, excavatorSegmentId: "s-1", startS: 40, dumpS: 60, endS: 80)],
                truckSegments: ["seg-1"]
            )
        ]
        let segments = [
            StateSegmentDTO(
                segmentId: "seg-1",
                recordingId: "rec-cache-1",
                cycleId: "c-cache-1",
                cycleSortKey: nil,
                machineId: "T1",
                scoopNumber: nil,
                state: "being_loaded",
                startS: 40,
                endS: 140,
                confidence: 0.94
            )
        ]

        cache.save(recordingId: "rec-cache-1", cycles: cycles, segments: segments, namespace: nsA)

        let loadedA = try #require(cache.load(recordingId: "rec-cache-1", namespace: nsA))
        #expect(loadedA.cycles.count == 1)
        #expect(loadedA.cycles[0].cycleId == "c-cache-1")
        #expect(loadedA.segments.count == 1)
        #expect(loadedA.segments[0].segmentId == "seg-1")

        // Separate endpoint namespaces never collide.
        #expect(cache.load(recordingId: "rec-cache-1", namespace: nsB) == nil)

        cache.clearAll()
        #expect(cache.load(recordingId: "rec-cache-1", namespace: nsA) == nil)
    }
}
