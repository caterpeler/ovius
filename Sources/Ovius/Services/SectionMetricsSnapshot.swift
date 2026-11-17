import Foundation

/// Histogram bucket computed client-side from queue waits or inter-arrival gaps.
public struct HistogramBin: Identifiable, Sendable, Equatable {
    public var id: String { label }
    public let label: String
    public let lowerBoundS: Double
    public let upperBoundS: Double
    public let count: Int
}

/// Queue depth concurrency summary for `CARD_QUEUE_WAIT_HISTOGRAM`.
public struct QueueDepthSummary: Sendable, Equatable {
    public let zero: Int
    public let one: Int
    public let twoPlus: Int
    public let maxConcurrentDepth: Int
    public let shovelMaxRateHr: Double

    public init(
        zero: Int = 0,
        one: Int = 0,
        twoPlus: Int = 0,
        maxConcurrentDepth: Int = 0,
        shovelMaxRateHr: Double = 0
    ) {
        self.zero = zero
        self.one = one
        self.twoPlus = twoPlus
        self.maxConcurrentDepth = maxConcurrentDepth
        self.shovelMaxRateHr = shovelMaxRateHr
    }

    public var totalCycles: Int { zero + one + twoPlus }
}

/// Conditional excavator state split when pocket is empty vs. occupied (`CARD_EXCAVATOR_STATE_BAR`).
public struct ExcavatorPocketSplit: Sendable, Equatable {
    public let emptyPocketActiveS: Double
    public let emptyPocketIdleS: Double
    public let spottedActiveS: Double
    public let spottedIdleS: Double

    public init(
        emptyPocketActiveS: Double = 0,
        emptyPocketIdleS: Double = 0,
        spottedActiveS: Double = 0,
        spottedIdleS: Double = 0
    ) {
        self.emptyPocketActiveS = emptyPocketActiveS
        self.emptyPocketIdleS = emptyPocketIdleS
        self.spottedActiveS = spottedActiveS
        self.spottedIdleS = spottedIdleS
    }
}

/// Synchronized concurrency metrics for `CARD_STATE_GANTT_TIMELINE`.
public struct GanttConcurrencyAudit: Sendable, Equatable {
    public let queueOverlapPct: Double
    public let starvedPct: Double
    public let syncedHaltCount: Int
    public let boundaryCutoffCount: Int

    public init(
        queueOverlapPct: Double = 0,
        starvedPct: Double = 0,
        syncedHaltCount: Int = 0,
        boundaryCutoffCount: Int = 0
    ) {
        self.queueOverlapPct = queueOverlapPct
        self.starvedPct = starvedPct
        self.syncedHaltCount = syncedHaltCount
        self.boundaryCutoffCount = boundaryCutoffCount
    }
}

/// Highlighted conflict track interval on the machine Gantt timeline.
public struct GanttConflictInterval: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let startS: Double
    public let endS: Double
}

/// Paired sequential headway vs. excavator idle hang preceding arrival (`CARD_ARRIVAL_GAP_CHART`).
public struct ArrivalHeadwaySample: Identifiable, Sendable, Equatable {
    public let id: String
    public let sequenceIndex: Int
    public let gapMin: Double
    public let precedentHangS: Double
}

/// Individual continuous stationary spell evaluated under Rule 4.1 (`CARD_IDLE_ALLOWANCE_KPI`).
public struct IdleSpellSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let recordingId: String
    public let machineId: String
    public let startS: Double
    public let endS: Double
    public let rawDurationS: Double
    public let allowanceS: Double
    public let excessS: Double
    public let isMultiMachineSynced: Bool
    public let syncedMachineCount: Int
}

/// Hourly aggregated KPIs and baseline comparison values for shift trends.
public struct HourlyMetricPoint: Identifiable, Sendable, Equatable {
    public var id: Int { hourUTC }
    public let hourUTC: Int
    public let volumetricRateM3Hr: Double
    public let truckArrivalRateHr: Double
    public let avgLoadDurationS: Double
    public let avgQueueTimeS: Double
    public let avgSpotDurationS: Double
    public let avgDepartureLagS: Double
    public let excavatorHangRatio: Double
    public let delayDurationS: Double
    public let delayPerCamHr: Double
    public let avgLoadStdDevS: Double
    public let avgQueueStdDevS: Double
    public let excavatorHangStdDev: Double
    public let isShiftEdge: Bool
    public let isBreakWindow: Bool

    public init(
        hourUTC: Int,
        volumetricRateM3Hr: Double,
        truckArrivalRateHr: Double,
        avgLoadDurationS: Double,
        avgQueueTimeS: Double,
        avgSpotDurationS: Double = 0,
        avgDepartureLagS: Double = 0,
        excavatorHangRatio: Double,
        delayDurationS: Double,
        delayPerCamHr: Double = 0,
        avgLoadStdDevS: Double = 0,
        avgQueueStdDevS: Double = 0,
        excavatorHangStdDev: Double = 0,
        isShiftEdge: Bool,
        isBreakWindow: Bool
    ) {
        self.hourUTC = hourUTC
        self.volumetricRateM3Hr = volumetricRateM3Hr
        self.truckArrivalRateHr = truckArrivalRateHr
        self.avgLoadDurationS = avgLoadDurationS
        self.avgQueueTimeS = avgQueueTimeS
        self.avgSpotDurationS = avgSpotDurationS
        self.avgDepartureLagS = avgDepartureLagS
        self.excavatorHangRatio = excavatorHangRatio
        self.delayDurationS = delayDurationS
        self.delayPerCamHr = delayPerCamHr
        self.avgLoadStdDevS = avgLoadStdDevS
        self.avgQueueStdDevS = avgQueueStdDevS
        self.excavatorHangStdDev = excavatorHangStdDev
        self.isShiftEdge = isShiftEdge
        self.isBreakWindow = isBreakWindow
    }
}

/// Single continuous machine state interval formatted for SwiftUI `Charts` Gantt display.
public struct GanttSegmentItem: Identifiable, Sendable, Equatable {
    public var id: String { segmentId }
    public let segmentId: String
    public let recordingId: String
    public let machineId: String
    public let state: MachineState
    public let startS: Double
    public let endS: Double
    public let confidence: Double
    public let isUncertain: Bool

    public var durationS: Double { max(0, endS - startS) }
}

/// Row rendered by the static Data Quality & Rule 4.2/4.3 Sample Audit card.
public struct CycleAuditRow: Identifiable, Sendable, Equatable {
    public var id: String { cycleId }
    public let cycleId: String
    public let recordingId: String
    public let excavatorId: String
    public let truckLabel: String
    public let cycleStatus: String
    public let isComplete: Bool
    public let queueTimeS: Double?
    public let spotTimeS: Double?
    public let loadDurationS: Double?
    public let departureLagS: Double?
    /// Nullified (`nil`) whenever `cycleStatus != "complete"` per Business Rule 4.2.
    public let totalCycleDurationS: Double?
    public let uncertainSegmentCount: Int
}

/// Full client-side KPI snapshot computed for a single `Section` over raw cloud DTOs.
public struct SectionMetricsSnapshot: Sendable, Equatable {
    public let sectionId: String
    public let sectionName: String
    public let recordingCount: Int
    public let totalCameraHours: Double
    public let totalCycleCount: Int
    public let completeCycleCount: Int
    public let incompleteCycleCount: Int
    public let totalSegmentCount: Int
    public let uncertainSegmentCount: Int

    public let totalVolumeM3: Double
    public let struckVolumeM3: Double
    public let heapedVolumeM3: Double
    public let avgCycleDurationS: Double
    public let totalPostAllowanceIdleS: Double

    public let metricValues: [MetricKey: Double]
    public let queueTimeHistogram: [HistogramBin]
    public let interArrivalGapHistogram: [HistogramBin]
    public let hourlySeries: [HourlyMetricPoint]
    public let ganttSegments: [GanttSegmentItem]
    public let cycleAuditRows: [CycleAuditRow]

    // §5.1 Comparative Widget Breakdown Fields
    public let pocketServiceTimeS: Double
    public let queueDepthSummary: QueueDepthSummary
    public let excavatorPocketSplit: ExcavatorPocketSplit
    public let arrivalHeadwaySamples: [ArrivalHeadwaySample]
    public let gapCoeffOfVariation: Double
    public let topIdleSpells: [IdleSpellSummary]
    public let syncedStoppageWindowCount: Int

    public init(
        sectionId: String,
        sectionName: String,
        recordingCount: Int,
        totalCameraHours: Double,
        totalCycleCount: Int,
        completeCycleCount: Int,
        incompleteCycleCount: Int,
        totalSegmentCount: Int,
        uncertainSegmentCount: Int,
        totalVolumeM3: Double,
        struckVolumeM3: Double,
        heapedVolumeM3: Double,
        avgCycleDurationS: Double,
        totalPostAllowanceIdleS: Double,
        metricValues: [MetricKey: Double],
        queueTimeHistogram: [HistogramBin],
        interArrivalGapHistogram: [HistogramBin],
        hourlySeries: [HourlyMetricPoint],
        ganttSegments: [GanttSegmentItem],
        cycleAuditRows: [CycleAuditRow],
        pocketServiceTimeS: Double = 0,
        queueDepthSummary: QueueDepthSummary = QueueDepthSummary(),
        excavatorPocketSplit: ExcavatorPocketSplit = ExcavatorPocketSplit(),
        arrivalHeadwaySamples: [ArrivalHeadwaySample] = [],
        gapCoeffOfVariation: Double = 0,
        topIdleSpells: [IdleSpellSummary] = [],
        syncedStoppageWindowCount: Int = 0
    ) {
        self.sectionId = sectionId
        self.sectionName = sectionName
        self.recordingCount = recordingCount
        self.totalCameraHours = totalCameraHours
        self.totalCycleCount = totalCycleCount
        self.completeCycleCount = completeCycleCount
        self.incompleteCycleCount = incompleteCycleCount
        self.totalSegmentCount = totalSegmentCount
        self.uncertainSegmentCount = uncertainSegmentCount
        self.totalVolumeM3 = totalVolumeM3
        self.struckVolumeM3 = struckVolumeM3
        self.heapedVolumeM3 = heapedVolumeM3
        self.avgCycleDurationS = avgCycleDurationS
        self.totalPostAllowanceIdleS = totalPostAllowanceIdleS
        self.metricValues = metricValues
        self.queueTimeHistogram = queueTimeHistogram
        self.interArrivalGapHistogram = interArrivalGapHistogram
        self.hourlySeries = hourlySeries
        self.ganttSegments = ganttSegments
        self.cycleAuditRows = cycleAuditRows
        self.pocketServiceTimeS = pocketServiceTimeS
        self.queueDepthSummary = queueDepthSummary
        self.excavatorPocketSplit = excavatorPocketSplit
        self.arrivalHeadwaySamples = arrivalHeadwaySamples
        self.gapCoeffOfVariation = gapCoeffOfVariation
        self.topIdleSpells = topIdleSpells
        self.syncedStoppageWindowCount = syncedStoppageWindowCount
    }

    /// Convenience accessor for any tracked `MetricKey`.
    public func value(for key: MetricKey) -> Double {
        metricValues[key] ?? 0.0
    }

    /// Fraction `[0, 1]` of observed segments with confidence `< 0.70` (Business Rule 4.3).
    public var uncertainSegmentRatio: Double {
        guard totalSegmentCount > 0 else { return 0 }
        return Double(uncertainSegmentCount) / Double(totalSegmentCount)
    }

    public var assignedFleetCountHint: Int {
        Set(cycleAuditRows.map(\.truckLabel)).count
    }
}

/// Aggregated mean (`μ`) and standard deviation (`σ`) across all sibling sections in a `Cluster`.
public struct ClusterBaselineStats: Sendable, Equatable {
    public let clusterId: String
    public let sectionSnapshots: [String: SectionMetricsSnapshot]
    public let means: [MetricKey: Double]
    public let stdDevs: [MetricKey: Double]
    public let hourlyBaselines: [HourlyMetricPoint]

    public func mean(for key: MetricKey) -> Double {
        means[key] ?? 0.0
    }

    public func stdDev(for key: MetricKey) -> Double {
        stdDevs[key] ?? 0.0
    }

    public func zScore(for key: MetricKey, value: Double) -> Double {
        let mu = mean(for: key)
        let sigma = stdDev(for: key)
        guard sigma > 1e-6 else { return 0.0 }
        return (value - mu) / sigma
    }

    public func relativeDelta(for key: MetricKey, value: Double) -> Double? {
        let mu = mean(for: key)
        guard abs(mu) > 1e-6 else { return nil }
        return (value - mu) / mu
    }
}
