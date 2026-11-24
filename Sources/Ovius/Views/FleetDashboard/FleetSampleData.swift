import Foundation

/// The prototype's seven recordings, and their cycles drawn the way it draws them (seeded, so always the same): for
/// previewing the fleet dashboard without telemetry. Nothing here is measured.
public enum FleetSampleData {
    private struct Meta {
        let id, camera, section, location, fileName, date: String
        let minutes: Double
        let cycles: Int
        let passes, cycleS, cycleSd, queueS, loadS, spotS, excIdle, excIdleSd, truckIdle, truckIdleSd, excEEU, truckEEU: Double
        let excavators, trucks: [String]
        let seed: Int64
    }

    private static let metas: [Meta] = [
        Meta(id: "rec-beta-05", camera: "CAM-BETA-05", section: "Section Beta", location: "Panoramic 4-Pocket Bench",
             fileName: "2026-11-16_mock_sample_10.mp4", date: "2026-11-16", minutes: 720, cycles: 401, passes: 4.8, cycleS: 143,
             cycleSd: 26.5, queueS: 28.2, loadS: 85, spotS: 29.8, excIdle: 110, excIdleSd: 154, truckIdle: 31.1, truckIdleSd: 4.7,
             excEEU: 39.8, truckEEU: 78.2, excavators: ["E8", "E10", "E3", "E19"], trucks: ["T1", "T2", "T3", "T4", "T5", "T6", "T7", "T8"], seed: 105),
        Meta(id: "rec-alpha-03", camera: "CAM-ALPHA-03", section: "Section Alpha", location: "Pit Floor Loading Pocket",
             fileName: "2026-11-16_mock_sample_11.mp4", date: "2026-11-16", minutes: 720, cycles: 419, passes: 4.0, cycleS: 185,
             cycleSd: 52, queueS: 54.2, loadS: 80, spotS: 50.8, excIdle: 62, excIdleSd: 148, truckIdle: 54.2, truckIdleSd: 38,
             excEEU: 44.5, truckEEU: 64, excavators: ["E2", "E5", "E7"], trucks: ["T11", "T12", "T14", "T15", "T16", "T18"], seed: 203),
        Meta(id: "rec-alpha-01", camera: "CAM-ALPHA-01", section: "Section Alpha", location: "Wide Overview Bench",
             fileName: "2026-11-16_mock_sample_1.mp4", date: "2026-11-16", minutes: 510, cycles: 386, passes: 4.0, cycleS: 212,
             cycleSd: 64, queueS: 84, loadS: 82, spotS: 46, excIdle: 48, excIdleSd: 112, truckIdle: 84, truckIdleSd: 45,
             excEEU: 52.1, truckEEU: 61.5, excavators: ["E1", "E4", "E6"], trucks: ["T21", "T22", "T23", "T24", "T25", "T26", "T27"], seed: 201),
        Meta(id: "rec-beta-01", camera: "CAM-BETA-01", section: "Section Beta", location: "Highwall Haul Ramp Pocket",
             fileName: "2026-11-16_mock_sample_2.mp4", date: "2026-11-16", minutes: 255, cycles: 188, passes: 7.0, cycleS: 440,
             cycleSd: 195, queueS: 205, loadS: 185, spotS: 50, excIdle: 145, excIdleSd: 365, truckIdle: 205, truckIdleSd: 118,
             excEEU: 24.8, truckEEU: 48.5, excavators: ["E9", "E12"], trucks: ["T31", "T32", "T33", "T34", "T35"], seed: 301),
        Meta(id: "rec-gamma-01", camera: "CAM-GAMMA-01", section: "Section Gamma", location: "Dual-Truck Loading Pocket",
             fileName: "2026-11-15_mock_sample_3.mp4", date: "2026-11-15", minutes: 360, cycles: 214, passes: 5.0, cycleS: 128,
             cycleSd: 18.4, queueS: 19.5, loadS: 84, spotS: 24.5, excIdle: 34, excIdleSd: 24, truckIdle: 22.4, truckIdleSd: 8.2,
             excEEU: 68.4, truckEEU: 76, excavators: ["E14", "E15"], trucks: ["T41", "T42", "T43", "T44", "T45"], seed: 401),
        Meta(id: "rec-gamma-02", camera: "CAM-GAMMA-02", section: "Section Gamma", location: "Upper Spoil Berm Pocket",
             fileName: "2026-11-14_mock_sample_4.mp4", date: "2026-11-14", minutes: 160, cycles: 96, passes: 4.9, cycleS: 134,
             cycleSd: 21, queueS: 24.2, loadS: 86, spotS: 23.8, excIdle: 41, excIdleSd: 29, truckIdle: 26.8, truckIdleSd: 10.5,
             excEEU: 61.2, truckEEU: 72.4, excavators: ["E16", "E17"], trucks: ["T51", "T52", "T53", "T54"], seed: 402),
        Meta(id: "rec-beta-02", camera: "CAM-BETA-02", section: "Section Beta", location: "Lower West Loading Bench",
             fileName: "2026-11-12_mock_sample_5.mp4", date: "2026-11-12", minutes: 720, cycles: 362, passes: 4.7, cycleS: 156,
             cycleSd: 34.2, queueS: 35.8, loadS: 88, spotS: 32.2, excIdle: 128, excIdleSd: 176, truckIdle: 36.4, truckIdleSd: 12.1,
             excEEU: 35.4, truckEEU: 74.1, excavators: ["E11", "E13", "E18"], trucks: ["T61", "T62", "T63", "T64", "T65", "T66", "T67"], seed: 502),
    ]

    /// The first rows of CAM-BETA-05, as the prototype has them: offset (min), truck, excavator, queue, load, spot (s),
    /// passes, confidence.
    private static let betaRows: [(Double, String, String, Double, Double, Double, Int, Double)] = [
        (70, "T3", "E8", 24.1, 111, 19.9, 5, 0.96), (72, "T1", "E10", 26.3, 42.6, 20.1, 5, 0.95), (74, "T2", "E3", 26.9, 121, 29.1, 6, 0.93),
        (75, "T4", "E19", 26.7, 103, 28.3, 5, 0.97), (80, "T6", "E8", 27.9, 42.4, 20.7, 5, 0.94), (81, "T5", "E3", 28.5, 85, 27.5, 5, 0.92),
        (82, "T7", "E19", 29.8, 88, 24.2, 6, 0.95), (82, "T8", "E10", 31.3, 42.4, 32.3, 6, 0.91), (86, "T3", "E19", 29.6, 109, 21.4, 4, 0.96),
        (87, "T1", "E3", 23.8, 100, 27.2, 4, 0.94), (89, "T2", "E8", 28.6, 90, 36.4, 5, 0.95), (89, "T4", "E10", 28.9, 82, 24.1, 5, 0.93),
        (94, "T6", "E10", 26.8, 100, 29.2, 5, 0.67), (95, "T5", "E8", 35.3, 102, 34.7, 4, 0.92), (96, "T8", "E3", 33.8, 56.9, 24.3, 4, 0.95),
    ]

    public static let recordings: [FleetRecording] = metas.map(recording)

    /// The prototype's generator: a Park–Miller sequence from the recording's seed.
    private struct Seeded {
        var s: Int64
        init(_ seed: Int64) {
            s = seed % 2_147_483_647
            if s <= 0 { s += 2_147_483_646 }
        }
        mutating func next() -> Double {
            s = (s * 16807) % 2_147_483_647
            return Double(s - 1) / 2_147_483_646
        }
    }

    private static func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    private static func recording(_ m: Meta) -> FleetRecording {
        var rand = Seeded(m.seed)
        var cycles: [FleetCycle] = []
        let waves = max(2, Int((m.minutes / 135).rounded()))
        let centers = (0..<waves).map { (Double($0) + 0.55) / Double(waves) * m.minutes }
        for i in 0..<m.cycles {
            if m.id == "rec-beta-05", i < betaRows.count {
                let r = betaRows[i]
                cycles.append(FleetCycle(id: "\(m.id)-c\(i + 1)", recordingId: m.id, seq: i + 1, offsetS: r.0 * 60, truck: r.1, excavator: r.2,
                                         queueS: r.3, spotS: r.5, loadS: r.4, passes: passes(r.6, r.4, &rand), confidence: r.7))
                continue
            }
            let base = (Double(i) + 0.5) / Double(m.cycles)
            let jitter = (rand.next() - 0.5) * (m.minutes / Double(m.cycles)) * 1.4
            let offset = max(1, min(m.minutes - 2, (base * m.minutes + jitter).rounded()))
            var wave = 0.0
            for c in centers where abs(offset - c) < 24 { wave = max(wave, 1 - abs(offset - c) / 24) }
            let spike = rand.next() < 0.085 || wave > 0.72
            let exc = m.excavators[Int(rand.next() * Double(m.excavators.count))]
            let truck = m.trucks[Int(rand.next() * Double(m.trucks.count))]
            let queue = max(6.5, r1(m.queueS * (spike ? 1.55 + rand.next() * 0.95 : 0.65 + rand.next() * 0.7)))
            let delta = rand.next() < 0.25 ? (rand.next() < 0.5 ? -1 : 1) : 0
            let scoops = max(3, min(8, Int(m.passes.rounded()) + delta))
            let loadFactor = spike && rand.next() < 0.5 ? 1.25 + rand.next() * 0.35 : 0.8 + rand.next() * 0.4
            let load = max(36, r1(m.loadS * (Double(scoops) / max(1, m.passes)) * loadFactor))
            let spot = max(12, r1(m.spotS * (0.75 + rand.next() * 0.55)))
            let confidence = rand.next() < 0.035 ? ((0.54 + rand.next() * 0.14) * 100).rounded() / 100 : ((0.86 + rand.next() * 0.13) * 100).rounded() / 100
            cycles.append(FleetCycle(id: "\(m.id)-c\(i + 1)", recordingId: m.id, seq: i + 1, offsetS: offset * 60, truck: truck, excavator: exc,
                                     queueS: queue, spotS: spot, loadS: load, passes: passes(scoops, load, &rand), confidence: confidence))
        }
        cycles.sort { ($0.offsetS, $0.seq) < ($1.offsetS, $1.seq) }

        // Each machine a little off its recording's mean, as the prototype spreads them.
        let excavators = m.excavators.enumerated().map { k, id in
            let shift = (Double(k % 4) - 1.5) * 4.2
            return FleetMachine(id: id, isExcavator: true, eeu: min(94, max(15, m.excEEU + shift)), meanIdleS: max(12, m.excIdle - shift * 3.5))
        }
        let trucks = m.trucks.enumerated().map { k, id in
            let shift = (Double(k % 5) - 2) * 3.1
            return FleetMachine(id: id, isExcavator: false, eeu: min(96, max(32, m.truckEEU + shift)), meanIdleS: m.truckIdle)
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return FleetRecording(id: m.id, camera: m.camera, section: m.section, location: m.location, fileName: m.fileName,
                              date: f.date(from: m.date), durationS: m.minutes * 60, totalCycles: m.cycles, completeCycles: m.cycles,
                              meanPasses: m.passes, meanCycleS: m.cycleS, cycleSdS: m.cycleSd, meanQueueS: m.queueS, meanLoadS: m.loadS,
                              meanSpotS: m.spotS, excIdleMeanS: m.excIdle, excIdleSdS: m.excIdleSd, truckIdleMeanS: m.truckIdle,
                              truckIdleSdS: m.truckIdleSd, excEEU: m.excEEU, truckEEU: m.truckEEU, machines: excavators + trucks, cycles: cycles)
    }

    private static func passes(_ count: Int, _ loadS: Double, _ rand: inout Seeded) -> [FleetPass] {
        let weights = (0..<count).map { _ in 0.85 + rand.next() * 0.35 }
        let sum = weights.reduce(0, +)
        var cumulative = 0.0
        return weights.enumerated().map { k, w in
            let d = r1(w / sum * loadS)
            cumulative = r1(cumulative + d)
            return FleetPass(number: k + 1, durationS: d, cumulativeS: cumulative, fillPct: min(100, Int((Double(k + 1) / Double(count) * 100).rounded())),
                             confidence: ((0.88 + rand.next() * 0.11) * 100).rounded() / 100)
        }
    }
}
