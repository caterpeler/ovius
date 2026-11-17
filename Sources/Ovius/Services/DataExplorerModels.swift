import Foundation

/// Current navigation tier inside the 3-layer hierarchical Data Explorer.
public enum ExplorerDrilldownLevel: Equatable, Sendable {
    case recordings
    case cycles(recording: RecordingExplorerRow)
    case stateTimings(recording: RecordingExplorerRow, cycle: CycleExplorerRow)
}

/// Layer 1 row in Data Explorer: raw `RecordingDTO` enriched with client-side recording cycle statistics.
public struct RecordingExplorerRow: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { recordingId }

    public let recordingId: String
    public let filename: String
    public let timestamp: String
    public let startDate: Date
    public let formattedTimestamp: String
    public let sectionId: String
    public let sectionName: String
    public let cameraId: String
    public let locationTag: String
    public let resolution: String
    public let fps: Double
    public let durationS: Double

    public let totalCycleCount: Int
    public let completeCycleCount: Int
    public let incompleteCycleCount: Int
    public let avgPassesPerCycle: Double
    public let avgQueueTimeS: Double
    public let avgSpotTimeS: Double
    public let avgLoadDurationS: Double
    public let avgDepartureLagS: Double
    public let avgTotalCycleS: Double
    public let excavatorCount: Int
    public let truckCount: Int
}

/// Layer 2 row in Data Explorer: `HaulCycleDTO` with Business Rule 4.2 & 4.3 fields for a selected recording.
public struct CycleExplorerRow: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { cycleId }

    public let cycleId: String
    public let recordingId: String
    public let truckLabel: String
    public let excavatorId: String
    public let cycleStatus: String
    public let isComplete: Bool

    public let tArriveS: Double
    public let tSpotS: Double
    public let tLoadStartS: Double
    public let tLoadEndS: Double
    public let tDepartS: Double

    public let queueTimeS: Double
    public let spotDurationS: Double
    public let loadDurationS: Double
    public let departureLagS: Double
    /// Nullified (`nil`) whenever `cycleStatus != "complete"` per Business Rule 4.2.
    public let totalCycleDurationS: Double?
    public let scoopCount: Int
    public let uncertainSegmentCount: Int

    /// Non-optional sort helper keeping incomplete (`nil`) rows grouped cleanly during table column sorting.
    public var totalCycleDurationSortKey: Double {
        totalCycleDurationS ?? -1.0
    }
}

/// Layer 3 machine state timing row in Data Explorer (`StateSegmentDTO` with Rule 4.3 flag).
public struct StateTimingExplorerRow: Identifiable, Sendable, Equatable {
    public var id: String { segmentId }

    public let segmentId: String
    public let recordingId: String
    public let cycleId: String
    public let machineId: String
    public let machineRole: String
    public let state: String
    public let typedState: MachineState?
    public let startS: Double
    public let endS: Double
    public let durationS: Double
    public let confidence: Double
    public let isUncertain: Bool
}

/// Layer 3 bucket pass timing row (`ScoopTimingDTO`) inside an opened cycle.
public struct ScoopTimingExplorerRow: Identifiable, Sendable, Equatable {
    public var id: Int { scoopNumber }

    public let scoopNumber: Int
    public let excavatorSegmentId: String
    public let startS: Double
    public let dumpS: Double
    public let endS: Double
    public let durationS: Double
    public let interScoopGapS: Double?

    public var interScoopGapSortKey: Double {
        interScoopGapS ?? -1.0
    }
}

/// Explorer layer sort options & filters.
public enum RecordingSortField: String, CaseIterable, Identifiable, Sendable {
    case dateDesc = "Date"
    case cyclesDesc = "Cycles"
    case passesDesc = "Passes/Cycle"
    case queueDesc = "Queue (s)"
    case loadDesc = "Load (s)"
    case cameraAsc = "Camera"

    public var id: String { rawValue }
}

public enum CycleStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Statuses"
    case completeOnly = "Complete Only"
    case incompleteOnly = "Incomplete Only"

    public var id: String { rawValue }
}

public enum MachineRoleFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Machines"
    case excavatorOnly = "Excavator"
    case truckOnly = "Truck"

    public var id: String { rawValue }
}
