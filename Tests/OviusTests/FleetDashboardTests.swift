import Foundation
import Testing
@testable import Ovius

struct FleetDashboardTests {
    private let rec = RecordingDTO(
        recordingId: "rec-1",
        filename: "clip1.mp4",
        timestamp: "2026-11-16T08:00:00Z",
        cameraId: "CAM-ALPHA-01",
        locationTag: "Bench",
        durationS: 3600,
        fps: 30,
        resolution: "1920x1080"
    )

    private func cycle(_ id: String, arrive: Double, queue: Double, status: String = "complete") -> HaulCycleDTO {
        HaulCycleDTO(
            recordingId: "rec-1",
            cycleId: id,
            excavatorId: "E1",
            excavatorSortKey: nil,
            truckLabel: "T1",
            cycleStatus: status,
            tArriveS: arrive,
            tSpotS: arrive + queue,
            tLoadStartS: arrive + queue + 20,
            tLoadEndS: arrive + queue + 120,
            tDepartS: status == "complete" ? arrive + queue + 140 : nil,
            queueTimeS: queue,
            scoops: [
                ScoopTimingDTO(scoopNumber: 1, excavatorSegmentId: "\(id)-s1", startS: arrive + queue + 20, dumpS: arrive + queue + 50, endS: arrive + queue + 70),
                ScoopTimingDTO(scoopNumber: 2, excavatorSegmentId: "\(id)-s2", startS: arrive + queue + 70, dumpS: arrive + queue + 100, endS: arrive + queue + 120),
            ],
            truckSegments: nil
        )
    }

    @Test func adapterSplitsCyclesIntoPhasesInVideoOrder() {
        let segments = [
            StateSegmentDTO(segmentId: "c2-s1", recordingId: "rec-1", cycleId: "c2", cycleSortKey: nil, machineId: "E1", scoopNumber: 1, state: "loading_scoop", startS: 40, endS: 90, confidence: 0.62),
            StateSegmentDTO(segmentId: "c2-t", recordingId: "rec-1", cycleId: "c2", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "being_loaded", startS: 40, endS: 140, confidence: 0.9),
        ]
        let fleet = FleetTelemetryAdapter.recording(
            rec,
            sectionName: "Alpha",
            cycles: [cycle("c1", arrive: 600, queue: 30), cycle("c2", arrive: 0, queue: 20), cycle("c3", arrive: 900, queue: 10, status: "incomplete")],
            segments: segments
        )

        #expect(fleet.cycles.map(\.id) == ["c2", "c1", "c3"])
        #expect(fleet.cycles.map(\.seq) == [1, 2, 3])
        let first = fleet.cycles[0]
        #expect(first.queueS == 20 && first.spotS == 20 && first.loadS == 100 && first.departS == 20)
        #expect(first.totalS == 160)
        #expect(first.passes.map(\.durationS) == [50, 50])
        #expect(first.passes[0].confidence == 0.62)
        #expect(first.confidence == 0.62)
        #expect(first.isUncertain)
        #expect(fleet.cycles[2].isComplete == false)
        #expect(fleet.totalCycles == 3 && fleet.completeCycles == 2)
        #expect(fleet.meanQueueS == 25)
        #expect(fleet.section == "Alpha" && fleet.location == "Bench")
    }

    @Test func cyclesAreJudgedByTargetsOnlyWhenAQueueOrCycleTargetIsSet() {
        let fleet = FleetTelemetryAdapter.recording(
            rec,
            sectionName: "Alpha",
            cycles: [cycle("a", arrive: 0, queue: 10), cycle("b", arrive: 300, queue: 12), cycle("c", arrive: 600, queue: 50),
                     cycle("d", arrive: 900, queue: 200, status: "incomplete")],
            segments: []
        )

        let byEEUOnly = FleetAnalysis.judge(fleet.cycles, targets: FleetTargets(excEEU: 60))
        #expect(!FleetTargets(excEEU: 60).judgesCycles)
        #expect(byEEUOnly.first { $0.id == "d" }?.isFlagged == false)

        let byQueue = FleetAnalysis.judge(fleet.cycles, targets: FleetTargets(maxQueueS: 30))
        #expect(byQueue.filter(\.isFlagged).map(\.id) == ["c"])
        #expect(byQueue.filter(\.isHighQueue).map(\.id) == ["c"])

        let byCycle = FleetAnalysis.judge(fleet.cycles, targets: FleetTargets(maxCycleS: 175))
        #expect(byCycle.filter(\.isFlagged).map(\.id) == ["c"])
    }

    @Test func diagnosisComparesOnlyTheTargetsThatAreSet() {
        var s = FleetAnalysis.Aggregate()
        s.clipCount = 1
        s.excEEU = 50
        s.truckEEU = 80
        s.meanQueueS = 20

        #expect(FleetAnalysis.diagnosis(s, recordings: [], targets: FleetTargets(truckEEU: 75)).title == "On target")
        let miss = FleetAnalysis.diagnosis(s, recordings: [], targets: FleetTargets(excEEU: 70))
        #expect(miss.severity == .critical)
        #expect(miss.detail.contains("20.0 pts under 70%") || miss.detail.contains("20,0 pts under 70%"))
    }

    private func fleetRecording(_ camera: String, excEEU: Double, queue: Double, cycles: Int = 10) -> FleetRecording {
        FleetRecording(id: camera, camera: camera, section: "Alpha", location: "Bench", fileName: "\(camera).mp4", date: nil,
                       durationS: 3600, totalCycles: cycles, completeCycles: cycles, meanPasses: 4, meanCycleS: 150, cycleSdS: 20,
                       meanQueueS: queue, meanLoadS: 90, meanSpotS: 20, excIdleMeanS: 60, excIdleSdS: 30, truckIdleMeanS: 30,
                       truckIdleSdS: 10, excEEU: excEEU, truckEEU: 70, machines: [], cycles: [])
    }

    @Test func severalRecordingsAreEachJudgedAgainstTheTargets() {
        // Pooled, these average 62.5% EEU and pass 60%; one of them is far below it.
        let recs = [fleetRecording("CAM-A", excEEU: 75, queue: 30), fleetRecording("CAM-B", excEEU: 75, queue: 30),
                    fleetRecording("CAM-C", excEEU: 75, queue: 30), fleetRecording("CAM-D", excEEU: 25, queue: 90),
                    fleetRecording("CAM-E", excEEU: 70, queue: 200, cycles: 0)]
        let targets = FleetTargets(excEEU: 60, maxQueueS: 45)
        let checks = FleetAnalysis.targetChecks(recs, targets: targets)
        #expect(checks.map(\.phrase) == ["Excavator EEU ≥ 60%", "Queue ≤ 45s"])
        #expect(checks[0].met == 4 && checks[0].judged == 5)
        #expect(checks[0].misses.map(\.camera) == ["CAM-D"])
        // A recording without cycles isn't judged on queue.
        #expect(checks[1].met == 3 && checks[1].judged == 4)

        let d = FleetAnalysis.diagnosis(FleetAnalysis.aggregate(recs), recordings: recs, targets: targets)
        #expect(d.title == "1 of 5 recordings below target")
        #expect(d.severity == .critical)
        #expect(d.detail.hasPrefix("CAM-D: "))

        let met = FleetAnalysis.diagnosis(FleetAnalysis.aggregate(Array(recs.prefix(2))), recordings: Array(recs.prefix(2)), targets: targets)
        #expect(met.title == "Every recording on target")
    }

    @MainActor @Test func clusterTargetsAreSavedAndCleared() throws {
        let db = DatabaseManager(inMemory: true)
        let saved = try db.upsertCluster(clusterId: "C-T", name: "Targets", targets: FleetTargets(excEEU: 65, maxQueueS: 35))
        #expect(saved.fleetTargets == FleetTargets(excEEU: 65, maxQueueS: 35))

        // Saving without targets (a rename elsewhere) keeps them; saving empty targets clears them.
        _ = try db.upsertCluster(clusterId: "C-T", name: "Renamed")
        #expect(try db.fetchCluster(clusterId: "C-T")?.fleetTargets == FleetTargets(excEEU: 65, maxQueueS: 35))
        _ = try db.upsertCluster(clusterId: "C-T", name: "Renamed", targets: FleetTargets())
        #expect(try db.fetchCluster(clusterId: "C-T")?.fleetTargets.isEmpty == true)
    }
}
