import Foundation

/// Operational KPI keys shared by adaptive diagnostic patterns and cards.
public enum MetricKey: String, Codable, Sendable, CaseIterable, Hashable {
    case avgQueueTimeS = "avg_queue_time_s"
    case avgSpotTimeS = "avg_spot_time_s"
    case avgLoadDurationS = "avg_load_duration_s"
    case avgDepartureLagS = "avg_departure_lag_s"
    case excavatorHangRatio = "excavator_hang_ratio"
    case trueIdleExcessS = "true_idle_excess_s"
    case volumetricRateM3Hr = "volumetric_rate_m3_hr"
    case truckArrivalRateHr = "truck_arrival_rate_hr"
    case shiftEdgeIdleRatio = "shift_edge_idle_ratio"
    case breakWindowIdleExcessS = "break_window_idle_excess_s"
    case hourlySlumpConcentration = "hourly_slump_concentration"
    case incompleteCycleRatio = "incomplete_cycle_ratio"
    case outOfFrameRatio = "out_of_frame_ratio"
}

/// How an anomaly pattern evaluates a section metric against the Cluster Horizon baseline.
public enum ComparisonMode: String, Codable, Sendable, CaseIterable, Hashable {
    case zScore = "z_score"
    case relativeDeltaPct = "relative_delta_pct"
    case absoluteValue = "absolute_value"
}

/// Direction of deviation required for an anomaly pattern to trigger.
public enum AnomalyDirection: String, Codable, Sendable, CaseIterable, Hashable {
    case aboveBaseline = "above_baseline"
    case belowBaseline = "below_baseline"
    case withinBand = "within_band"
}

/// SwiftUI view component bound 1-to-1 by a `DiagnosticCard`.
public enum WidgetType: String, Codable, Sendable, CaseIterable, Hashable {
    case histogram
    case kpiComparison = "kpi_comparison"
    case phaseBreakdownBar = "phase_breakdown_bar"
    case stateGanttTimeline = "state_gantt_timeline"
    case hourlyMetricTrend = "hourly_metric_trend"
    case cycleTable = "cycle_table"
}

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
