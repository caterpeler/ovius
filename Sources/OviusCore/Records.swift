import Foundation

public struct Site: Identifiable, Hashable {
    public var id: Int64
    public var name: String
}

/// A section of a site (Section Alpha) whose cameras each watch a different part of it, none overlapping.
public struct Cluster: Identifiable, Hashable {
    public var id: Int64
    public var siteID: Int64
    public var name: String
}

public struct Camera: Identifiable, Hashable {
    public var id: Int64
    public var clusterID: Int64
    public var name: String
}

/// A pipeline bundle from the labeler, unpacked into the library.
public struct Pipeline: Identifiable, Hashable {
    public var id: Int64
    public var name: String
    /// Its nodes' labels, in the order they run.
    public var nodes: [String]
    public var reportFile: String
    public var eventsFile: String
    public var importedAt: Date
}

public enum Status: String {
    /// The video is being copied into the library.
    case copying
    case queued
    case running
    case done
    case failed
    case cancelled

    /// Finished one way or another: nothing more happens to it unless it is run again.
    public var isOver: Bool { self == .done || self == .failed || self == .cancelled }
}

/// A cluster analysis: one video per camera of a cluster, covering the same period, run through one pipeline. Its
/// figures are worked out once every camera's analysis is over.
public struct Batch: Identifiable, Equatable {
    public var id: Int64
    public var clusterID: Int64
    public var pipelineID: Int64
    public var metrics: ClusterMetrics?
    /// Why the cluster's figures could not be worked out.
    public var error: String?
    public var createdAt: Date
    public var finishedAt: Date?

    /// Where a batch is, from its cameras' analyses.
    public enum State: Equatable {
        case copying
        /// Cameras still to run or running; `over` of `of` finished.
        case running(over: Int, of: Int)
        /// Every camera is over; the cluster's figures are being (or are yet to be) worked out.
        case figuring
        case done
        /// Done without some cameras (they failed or were stopped): the figures are of the others.
        case partial(missing: Int)
        case failed
        case stopped
    }

    public func state(of analyses: [Analysis]) -> State {
        if analyses.contains(where: { $0.status == .copying }) { return .copying }
        let over = analyses.filter { $0.status.isOver }
        if over.count < analyses.count { return .running(over: over.count, of: analyses.count) }
        let done = analyses.filter { $0.status == .done }.count
        if done == 0 { return analyses.contains { $0.status == .failed } ? .failed : .stopped }
        if metrics == nil { return error == nil ? .figuring : .failed }
        return done < analyses.count ? .partial(missing: analyses.count - done) : .done
    }

    /// Whether the cluster step can run: every camera over, at least one done.
    public static func ready(_ analyses: [Analysis]) -> Bool {
        !analyses.isEmpty && analyses.allSatisfy { $0.status.isOver } && analyses.contains { $0.status == .done }
    }
}

/// One camera's video in a batch, run through the batch's pipeline.
public struct Analysis: Identifiable, Equatable {
    public var id: Int64
    public var batchID: Int64
    public var cameraID: Int64
    public var pipelineID: Int64
    /// The copied video's file name, in the analysis's folder.
    public var videoName: String
    /// The camera's clock at the video's first frame (2024-02-02 16:00:56); nil when unknown.
    public var start: String?
    public var status: Status
    public var error: String?
    /// What the camera saw, before the cluster step completes the cycles cut short; nil until done, or when worked
    /// out by an older version (the app works those out again).
    public var metrics: CameraMetrics?
    public var createdAt: Date
    public var finishedAt: Date?
}

/// What the site manager tunes. Changing a figure here recalculates every analysis; the device and Python apply to
/// the next run.
public struct Settings: Codable, Equatable {
    /// Loose volume of one truck load (51.1 m³: a CAT 777D's heaped body), and the range it may be: struck (level
    /// with the body's sides) to heaped.
    public var m3PerLoad = 51.1
    public var m3Struck = 42.1
    public var m3Heaped = 60.1
    /// Loading points seen for less than this, with no loads, are left out: not an excavator, or barely seen.
    public var minPointMinutes = 5.0
    /// Where the models run: mps (Apple's GPU) or cpu.
    public var device = "mps"
    /// A Python 3.9 or newer to use instead of the one the app sets up; empty for the app's own.
    public var customPython = ""
    /// The state model's states in which an excavator is idle (comma-separated); it works in the others.
    public var idleStates = "idle"
    /// How long a clip the state model judges, as its state version cut them (a clips model's file does not say).
    public var stateClipS = 3.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        m3PerLoad = try c.decodeIfPresent(Double.self, forKey: .m3PerLoad) ?? d.m3PerLoad
        m3Struck = try c.decodeIfPresent(Double.self, forKey: .m3Struck) ?? d.m3Struck
        m3Heaped = try c.decodeIfPresent(Double.self, forKey: .m3Heaped) ?? d.m3Heaped
        minPointMinutes = try c.decodeIfPresent(Double.self, forKey: .minPointMinutes) ?? d.minPointMinutes
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? d.device
        customPython = try c.decodeIfPresent(String.self, forKey: .customPython) ?? d.customPython
        idleStates = try c.decodeIfPresent(String.self, forKey: .idleStates) ?? d.idleStates
        stateClipS = try c.decodeIfPresent(Double.self, forKey: .stateClipS) ?? d.stateClipS
    }

    /// Whether `other` gives different figures.
    public func refigures(_ other: Settings) -> Bool {
        m3PerLoad != other.m3PerLoad || m3Struck != other.m3Struck || m3Heaped != other.m3Heaped || minPointMinutes != other.minPointMinutes
    }

    /// metrics.py's settings for one camera's analysis, its tables by their usual names (metrics.py finds others by
    /// their columns).
    public func forMetrics(start: String?) -> [String: Any] {
        var s = forCluster()
        s["min_point_minutes"] = minPointMinutes
        if let start { s["start"] = start }
        return s
    }

    /// metrics.py's settings for one camera's analysis.
    public func forMetrics(start: String?, pipeline: Pipeline) -> [String: Any] {
        var s = forCluster()
        s["min_point_minutes"] = minPointMinutes
        s["report_file"] = pipeline.reportFile
        s["events_file"] = pipeline.eventsFile
        if let start { s["start"] = start }
        return s
    }

    /// metrics.py's settings for a cluster's batch.
    public func forCluster() -> [String: Any] {
        ["m3_per_load": m3PerLoad, "m3_struck": m3Struck, "m3_heaped": m3Heaped]
    }
}

/// What one camera's video showed, as metrics.py writes it: its excavators and cycles, as seen.
public struct CameraMetrics: Decodable, Equatable {
    /// The version metrics.py writes now; older figures are worked out again.
    public static let current = 2

    public var version: Int
    public var video: Video
    /// Hours a loading point was in view.
    public var observedH: Double
    public var excavators: [Excavator]
    public var cycles: [Cycle]

    public struct Video: Decodable, Equatable {
        public var fps: Double
        public var every: Int
        public var durationS: Double
        public var start: String?
    }

    public static func decode(_ data: Data) throws -> CameraMetrics {
        let m = try JSONDecoder.snakeCase.decode(CameraMetrics.self, from: data)
        guard m.version == current else { throw OviusError(message: "Figures of version \(m.version), not \(current).") }
        return m
    }
}

/// An excavator: a labeler loading point, the tracks it found to be one machine.
public struct Excavator: Decodable, Equatable {
    public var point: String
    public var ids: String?
    /// Seconds in view, working, and idle; with an estimated load's unseen part added, in a cluster's figures.
    public var seenS: Double
    public var workingS: Double
    public var idleS: Double
    public var loads: Int?
    /// Time in each of the state model's states, the longest first, as seen; nil without a state model.
    public var states: [StateTime]?

    public struct StateTime: Decodable, Equatable {
        public var state: String
        public var s: Double

        public init(state: String, s: Double) {
            self.state = state
            self.s = s
        }
    }
}

/// One truck loaded: from coming into the loading area, through spotting, to its loading's end. Times are seconds
/// from the video's start.
public struct Cycle: Decodable, Equatable {
    public var point: String
    public var truck: String
    /// When it came into the loading area; nil when it was not seen to (no wait before its load).
    public var arriveS: Double?
    /// When it began moving into place.
    public var spotAtS: Double?
    public var loadStartS: Double
    public var loadEndS: Double
    /// Standing in the area before spotting (the queue), and the spotting.
    public var waitS: Double
    public var spotS: Double
    /// The load time: as seen, or, for an estimated cycle, as imputed.
    public var loadS: Double?
    /// Seen to start and to end.
    public var complete: Bool
    /// Cut short and completed by imputation (in a cluster's figures).
    public var estimated: Bool?
    /// The part of the load the camera saw (in a cluster's figures).
    public var seenLoadS: Double?

    public var isEstimated: Bool { estimated ?? !complete }
}

/// A batch's figures, the team's (the spreadsheet's Recording Overview and Executive Summary), as metrics.py
/// --cluster writes them.
public struct ClusterMetrics: Decodable, Equatable {
    public static let current = 2

    public var version: Int
    public var settings: Used
    /// Imputed load times are drawn within this many standard deviations of the mean.
    public var spread: Double
    public var cameras: [CameraRow]
    /// The TOTAL row, by the sheet's formulas.
    public var total: TeamFigures
    public var summary: Summary

    public struct Used: Decodable, Equatable {
        public var m3PerLoad: Double?
        public var m3Struck: Double?
        public var m3Heaped: Double?
    }

    public struct CameraRow: Decodable, Equatable, Identifiable {
        public var name: String
        public var analysis: Int64
        public var figures: TeamFigures
        public var prior: Prior?
        public var cycles: [Cycle]
        public var excavators: [Excavator]
        public var id: Int64 { analysis }
    }

    /// What a camera's estimated load times were drawn from.
    public struct Prior: Decodable, Equatable {
        /// camera (its own complete loads), cluster (the cluster's complete loads), seen (every load the cluster's
        /// cameras saw, complete or not), or none.
        public var basis: String
        public var n: Int
        public var mean: Double?
        public var stdev: Double?
        public var low: Double?
        public var high: Double?
    }

    /// The Executive Summary, over every cycle of the cluster together.
    public struct Summary: Decodable, Equatable {
        public var cycles: Int
        public var observed: Int
        public var estimated: Int
        public var volumeM3: Double
        public var volumeObservedM3: Double
        public var volumeStruckM3: Double
        public var volumeHeapedM3: Double
        public var m3PerLoad: Double
        public var loadSMean: Double?
        public var loadSStdev: Double?
        public var loadSMedian: Double?
        public var queueTotalS: Double
        public var queuedTrucks: Int
        public var excavatorUtilPct: Double?
        /// Hours of footage, every camera's added up.
        public var cameraH: Double
    }

    public static func decode(_ data: Data) throws -> ClusterMetrics {
        let m = try JSONDecoder.snakeCase.decode(ClusterMetrics.self, from: data)
        guard m.version == current else { throw OviusError(message: "Figures of version \(m.version), not \(current).") }
        return m
    }
}

/// One row of the Recording Overview: a camera's, or the cluster's total.
public struct TeamFigures: Decodable, Equatable {
    /// Hours of video; a cluster's are its longest camera's, as its cameras cover the same period.
    public var durationH: Double
    public var cycles: Int
    public var observed: Int
    public var estimated: Int
    public var loadSMean: Double?
    public var loadSStdev: Double?
    /// Of the trucks that queued.
    public var queueSMean: Double?
    public var queueSStdev: Double?
    /// Each excavator's idle time.
    public var excavatorIdleSMean: Double?
    public var excavatorIdleSStdev: Double?
    /// Every cycle's queue, none counting as 0.
    public var truckIdleSMean: Double?
    public var truckIdleSStdev: Double?
    public var volumeM3: Double
    public var volumeStruckM3: Double
    public var volumeHeapedM3: Double
    public var excavatorUtilPct: Double?
    public var truckUtilPct: Double?
    public var excavators: Int
    public var trucks: Int

    public init(durationH: Double, cycles: Int, observed: Int, estimated: Int, loadSMean: Double? = nil, loadSStdev: Double? = nil,
                queueSMean: Double? = nil, queueSStdev: Double? = nil, excavatorIdleSMean: Double? = nil, excavatorIdleSStdev: Double? = nil,
                truckIdleSMean: Double? = nil, truckIdleSStdev: Double? = nil, volumeM3: Double, volumeStruckM3: Double = 0,
                volumeHeapedM3: Double = 0, excavatorUtilPct: Double? = nil, truckUtilPct: Double? = nil, excavators: Int = 0, trucks: Int = 0) {
        self.durationH = durationH
        self.cycles = cycles
        self.observed = observed
        self.estimated = estimated
        self.loadSMean = loadSMean
        self.loadSStdev = loadSStdev
        self.queueSMean = queueSMean
        self.queueSStdev = queueSStdev
        self.excavatorIdleSMean = excavatorIdleSMean
        self.excavatorIdleSStdev = excavatorIdleSStdev
        self.truckIdleSMean = truckIdleSMean
        self.truckIdleSStdev = truckIdleSStdev
        self.volumeM3 = volumeM3
        self.volumeStruckM3 = volumeStruckM3
        self.volumeHeapedM3 = volumeHeapedM3
        self.excavatorUtilPct = excavatorUtilPct
        self.truckUtilPct = truckUtilPct
        self.excavators = excavators
        self.trucks = trucks
    }
}

extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

// MARK: Rows of the library's database

public extension Site {
    init(row: Row) {
        self.init(id: row.int("id")!, name: row.string("name")!)
    }
}

public extension Cluster {
    init(row: Row) {
        self.init(id: row.int("id")!, siteID: row.int("site_id")!, name: row.string("name")!)
    }
}

public extension Camera {
    init(row: Row) {
        self.init(id: row.int("id")!, clusterID: row.int("cluster_id")!, name: row.string("name")!)
    }
}

public extension Pipeline {
    init(row: Row) {
        self.init(
            id: row.int("id")!,
            name: row.string("name")!,
            nodes: (try? JSONDecoder().decode([String].self, from: Data((row.string("nodes") ?? "[]").utf8))) ?? [],
            reportFile: row.string("report_file")!,
            eventsFile: row.string("events_file")!,
            importedAt: row.date("imported_at")!
        )
    }
}

public extension Batch {
    init(row: Row) {
        self.init(
            id: row.int("id")!,
            clusterID: row.int("cluster_id")!,
            pipelineID: row.int("pipeline_id")!,
            metrics: row.string("metrics").flatMap { try? ClusterMetrics.decode(Data($0.utf8)) },
            error: row.string("error"),
            createdAt: row.date("created_at")!,
            finishedAt: row.date("finished_at")
        )
    }
}

public extension Analysis {
    init(row: Row) {
        self.init(
            id: row.int("id")!,
            batchID: row.int("batch_id")!,
            cameraID: row.int("camera_id")!,
            pipelineID: row.int("pipeline_id")!,
            videoName: row.string("video_name")!,
            start: row.string("start"),
            status: Status(rawValue: row.string("status")!) ?? .failed,
            error: row.string("error"),
            metrics: row.string("metrics").flatMap { try? CameraMetrics.decode(Data($0.utf8)) },
            createdAt: row.date("created_at")!,
            finishedAt: row.date("finished_at")
        )
    }
}
