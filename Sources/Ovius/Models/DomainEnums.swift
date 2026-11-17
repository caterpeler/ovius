import Foundation

/// Raw machine state intervals emitted by upstream telemetry into `ovius-state-segment`.
public enum MachineState: String, Codable, Sendable, CaseIterable, Hashable {
    case loadingScoop = "loading_scoop"
    case facePrep = "face_prep"
    case queuingIdle = "queuing_idle"
    case spotting
    case beingLoaded = "being_loaded"
    case departing
    case idle
    case outOfFrame = "out_of_frame"
}

/// Observation status of a `haul_cycle` record (Business Rule 4.2).
public enum CycleStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case complete
    case incomplete
    case inProgress = "in_progress"
    case queuedOnly = "queued_only"
}
