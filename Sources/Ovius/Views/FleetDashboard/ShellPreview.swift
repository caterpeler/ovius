import Foundation
import SwiftUI

/// `Ovius --shell-preview [--tab clusters|uploads|settings] [--section] [--storage] [--cycle] [--upload N] [--multi] [--targets]`: the whole window on an in-memory library
/// with generated telemetry, for reviewing the layout without touching the real library, cache or cloud.
enum ShellPreview {
    static let isOn = CommandLine.arguments.contains("--shell-preview")

    static var tab: AppSidebarTab {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--tab"), i + 1 < args.count else { return .dashboard }
        return AppSidebarTab(rawValue: args[i + 1]) ?? .dashboard
    }

    /// The window, made once: on an in-memory library, an off cache, and generated telemetry.
    @MainActor static let content = makeContent()

    @MainActor
    private static func makeContent() -> ContentView {
        let db = DatabaseManager(inMemory: true)
        let cache = TelemetryDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ovius-shell-preview"),
                                       isEnabled: false)
        let dashboard = DashboardViewModel(databaseManager: db, diskCache: cache)
        if CommandLine.arguments.contains("--targets"), let main = try? db.fetchCluster(clusterId: DatabaseManager.defaultMainClusterId) {
            _ = try? db.upsertCluster(clusterId: main.clusterId, name: main.name, tags: main.tags,
                                      targets: FleetTargets(excEEU: 60, maxQueueS: 45))
        }
        let (recordings, cycles, segments) = generate()
        let picked = CommandLine.arguments.contains("--multi") ? Set(recordings.prefix(3).map(\.recordingId)) : [recordings[0].recordingId]
        Task { @MainActor in
            await dashboard.seedCacheAndProjectForTesting(recordings: recordings, cyclesByRec: cycles, segmentsByRec: segments,
                                                          selectedRecordingIds: picked)
            if CommandLine.arguments.contains("--cycle"), let rec = dashboard.fleet.recordings.first {
                dashboard.fleet.inspected = FleetAnalysis.judge(rec.cycles, targets: dashboard.fleet.targets).first(where: \.isFlagged)?.cycle
            }
        }
        let clusters = ClustersViewModel(databaseManager: db)
        clusters.reload()
        if CommandLine.arguments.contains("--section"), let section = clusters.selectedCluster?.sections.min(by: { $0.sectionId < $1.sectionId }) {
            clusters.openSection(section)
        }
        let uploads = UploadsState.sample()
        if let i = CommandLine.arguments.firstIndex(of: "--upload"), i + 1 < CommandLine.arguments.count,
           let n = Int(CommandLine.arguments[i + 1]), uploads.videos.indices.contains(n) {
            uploads.selectedId = uploads.videos[n].id
        }
        return ContentView(
            tab: tab,
            settingsCategory: CommandLine.arguments.contains("--storage") ? .storage : .endpoint,
            dashboardViewModel: dashboard,
            clustersViewModel: clusters,
            settingsViewModel: SettingsViewModel(diskCache: cache),
            uploadsState: uploads
        )
    }

    // MARK: Generated telemetry

    private struct Rand {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + next() * (r.upperBound - r.lowerBound) }
    }

    private static func generate() -> ([RecordingDTO], [String: [HaulCycleDTO]], [String: [StateSegmentDTO]]) {
        let clips: [(camera: String, location: String, hours: Double, day: Int)] = [
            ("CAM-BETA-05", "Section Beta - Panoramic 4-Pocket Bench", 6, 16),
            ("CAM-ALPHA-03", "Section Alpha - Pit Floor Loading Pocket", 5, 16),
            ("CAM-ALPHA-01", "Section Alpha - Wide Overview Bench", 3.5, 15),
            ("CAM-BETA-01", "Section Beta - Highwall Haul Ramp Pocket", 2.5, 14),
            ("CAM-GAMMA-01", "Section Gamma - Dual-Truck Loading Pocket", 4, 12),
            ("CAM-GAMMA-02", "Section Gamma - Upper Spoil Berm Pocket", 2, 10),
        ]
        var rand = Rand(state: 42)
        var recordings: [RecordingDTO] = []
        var cyclesByRec: [String: [HaulCycleDTO]] = [:]
        var segmentsByRec: [String: [StateSegmentDTO]] = [:]
        for (k, clip) in clips.enumerated() {
            let recId = "preview-\(k)"
            let duration = clip.hours * 3600
            recordings.append(RecordingDTO(recordingId: recId, filename: "2026-11-\(clip.day)_preview_\(k + 1).mp4",
                                           timestamp: "2026-11-\(clip.day)T06:00:00Z", cameraId: clip.camera,
                                           locationTag: clip.location, durationS: duration, fps: 30, resolution: "1920x1080",
                                           tags: ["section:" + clip.camera.split(separator: "-")[1].capitalized]))
            var cycles: [HaulCycleDTO] = []
            var segments: [StateSegmentDTO] = []
            var t = rand.range(20...90)
            var n = 0
            let wave = k % 2 == 0
            while t < duration - 400 {
                n += 1
                let cid = "\(recId)-c\(n)"
                let exc = n % 2 == 0 ? "E1" : "E2"
                let truck = "T\(1 + Int(rand.next() * 6))"
                let queue = wave && n % 9 < 3 ? rand.range(60...200) : rand.range(8...45)
                let spot = rand.range(14...32)
                let passes = 3 + Int(rand.next() * 3)
                let complete = rand.next() > 0.06
                var scoops: [ScoopTimingDTO] = []
                var p = t + queue + spot
                let loadStart = p
                for s in 1...passes {
                    let d = rand.range(18...30)
                    let segId = "\(cid)-s\(s)"
                    scoops.append(ScoopTimingDTO(scoopNumber: s, excavatorSegmentId: segId, startS: p, dumpS: p + d * 0.6, endS: p + d))
                    segments.append(StateSegmentDTO(segmentId: segId, recordingId: recId, cycleId: cid, cycleSortKey: nil, machineId: exc,
                                                    scoopNumber: s, state: "loading_scoop", startS: p, endS: p + d,
                                                    confidence: rand.range(0.62...0.99)))
                    p += d
                }
                let loadEnd = p
                let depart = loadEnd + rand.range(12...24)
                func seg(_ state: String, _ a: Double, _ b: Double) {
                    segments.append(StateSegmentDTO(segmentId: "\(cid)-\(state)", recordingId: recId, cycleId: cid, cycleSortKey: nil,
                                                    machineId: truck, scoopNumber: nil, state: state, startS: a, endS: b,
                                                    confidence: rand.range(0.66...0.99)))
                }
                seg("queuing_idle", t, t + queue)
                seg("spotting", t + queue, loadStart)
                seg("being_loaded", loadStart, loadEnd)
                if complete { seg("departing", loadEnd, depart) }
                cycles.append(HaulCycleDTO(recordingId: recId, cycleId: cid, excavatorId: exc, excavatorSortKey: nil, truckLabel: truck,
                                           cycleStatus: complete ? "complete" : "incomplete", tArriveS: t, tSpotS: t + queue,
                                           tLoadStartS: loadStart, tLoadEndS: loadEnd, tDepartS: complete ? depart : nil,
                                           queueTimeS: queue, scoops: scoops, truckSegments: nil))
                let gap = wave && n % 9 == 8 ? rand.range(200...420) : rand.range(20...70)
                segments.append(StateSegmentDTO(segmentId: "\(cid)-idle", recordingId: recId, cycleId: "NONE", cycleSortKey: nil,
                                                machineId: exc, scoopNumber: nil, state: "idle", startS: loadEnd, endS: loadEnd + gap,
                                                confidence: 0.9))
                t += rand.range(70...150) + (wave && n % 9 == 8 ? 260 : 0)
            }
            cyclesByRec[recId] = cycles
            segmentsByRec[recId] = segments
        }
        return (recordings, cyclesByRec, segmentsByRec)
    }
}
