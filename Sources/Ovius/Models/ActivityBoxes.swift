import CoreGraphics
import Foundation

/// A machine's box in one sampled frame, in the video's pixels.
public struct TrackedBox: Sendable, Equatable, Identifiable {
    public let trackId: Int
    public let cls: String
    public let confidence: Double?
    public let rect: CGRect
    /// Lost by the detector and carried along by the tracker.
    public let hidden: Bool

    public var id: String { "\(cls)#\(trackId)" }

    /// The name the cycle and segment tables give this machine (`T3`, `E5`, `B2`): the class's letter and the track.
    /// Track numbers repeat across classes, so both are needed.
    public var machineLabel: String? {
        switch cls.lowercased() {
        case "dumptruck", "dump_truck", "truck": "T\(trackId)"
        case "excavator": "E\(trackId)"
        case "bulldozer": "B\(trackId)"
        default: nil
        }
    }
}

/// An activity's boxes, grouped by sampled frame, for drawing over the video as it plays.
public struct ActivityBoxes: Sendable, Equatable {
    public let window: ClosedRange<Double>
    /// Sampled frames in time order.
    public let frames: [(t: Double, boxes: [TrackedBox])]
    public let isAvailable: Bool

    /// The columns read from a box-track file.
    public static let columns: Set<String> = ["t", "id", "cls", "conf", "x1", "y1", "x2", "y2", "hidden"]

    public static func == (a: ActivityBoxes, b: ActivityBoxes) -> Bool {
        a.window == b.window && a.isAvailable == b.isAvailable
            && a.frames.map(\.t) == b.frames.map(\.t) && a.frames.map(\.boxes) == b.frames.map(\.boxes)
    }

    /// For a recording without box tracks (seeded recordings have none): the video plays without boxes.
    public static func unavailable(window: ClosedRange<Double>) -> ActivityBoxes {
        ActivityBoxes(window: window, frames: [], isAvailable: false)
    }

    private init(window: ClosedRange<Double>, frames: [(t: Double, boxes: [TrackedBox])], isAvailable: Bool) {
        self.window = window
        self.frames = frames
        self.isAvailable = isAvailable
    }

    /// The boxes of a recording's box-track file (`t`, `id`, `cls`, `conf`, `x1`…`y2`, `hidden`) seen within `window`.
    /// Rows missing a time, track, class or corner are skipped.
    public init(table: ParquetTable, window: ClosedRange<Double>) throws {
        guard let t = table.doubles("t"), let id = table.ints("id"), let cls = table.strings("cls"),
              let x1 = table.doubles("x1"), let y1 = table.doubles("y1"),
              let x2 = table.doubles("x2"), let y2 = table.doubles("y2") else {
            throw ParquetError.unsupported("a box-track file without t, id, cls and x1…y2 columns")
        }
        let conf = table.doubles("conf")
        let hidden = table.bools("hidden")
        var byTime: [Double: [TrackedBox]] = [:]
        for i in t.indices {
            guard let time = t[i], window.contains(time), let track = id[i], let kind = cls[i],
                  let left = x1[i], let top = y1[i], let right = x2[i], let bottom = y2[i] else { continue }
            byTime[time, default: []].append(TrackedBox(
                trackId: track, cls: kind, confidence: conf?[i] ?? nil,
                rect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                hidden: (hidden?[i] ?? nil) ?? false
            ))
        }
        self.init(window: window,
                  frames: byTime.keys.sorted().map { t in (t, byTime[t]!.sorted { ($0.trackId, $0.cls) < ($1.trackId, $1.cls) }) },
                  isAvailable: true)
    }

    /// The boxes of the sampled frame at or just before `time`; none when the nearest one is further back than
    /// `tolerance` (the pipeline samples about 3 frames a second).
    public func boxes(at time: Double, tolerance: Double = 0.75) -> [TrackedBox] {
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].t <= time { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, time - frames[lo - 1].t <= tolerance else { return [] }
        return frames[lo - 1].boxes
    }
}
