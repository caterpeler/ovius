import Foundation
import Observation

/// Manages the 3-layer Data Explorer (`Recordings -> Cycles -> State Timings`):
/// search text, layer-specific filter pickers, bidirectional sort synchronization, and row state.
@MainActor
@Observable
public final class DataExplorerViewModel {
    public var explorerLevel: ExplorerDrilldownLevel = .recordings
    public var explorerSearchText: String = ""

    // Layer 1 Controls
    public var recordingSortField: RecordingSortField = .dateDesc
    public var recordingSortAscending: Bool = false
    public var recordingSortOrder: [KeyPathComparator<RecordingExplorerRow>] = [
        .init(\.startDate, order: .reverse)
    ]
    public var explorerSectionFilterId: String? = nil
    public var explorerCameraFilterId: String? = nil
    public var explorerMinCycles: Int = 0
    public var recordingRows: [RecordingExplorerRow] = []

    // Layer 2 Controls
    public var cycleStatusFilter: CycleStatusFilter = .all
    public var cycleExcavatorFilter: String? = nil
    public var cycleTruckFilter: String? = nil
    public var cycleUncertainOnly: Bool = false
    public var cycleRows: [CycleExplorerRow] = []

    // Layer 3 Controls
    public var timingRoleFilter: MachineRoleFilter = .all
    public var timingStateFilter: MachineState? = nil
    public var timingUncertainOnly: Bool = false
    public var stateTimingRows: [StateTimingExplorerRow] = []
    public var scoopTimingRows: [ScoopTimingExplorerRow] = []

    private var isSyncingSortOrder: Bool = false

    public init() {}

    // MARK: - Filtered Layer Rows

    public var displayedRecordingRows: [RecordingExplorerRow] {
        var rows = recordingRows
        if let secId = explorerSectionFilterId {
            rows = rows.filter { $0.sectionId == secId }
        }
        if let camId = explorerCameraFilterId {
            rows = rows.filter { $0.cameraId == camId }
        }
        if explorerMinCycles > 0 {
            rows = rows.filter { $0.totalCycleCount >= explorerMinCycles }
        }
        let q = explorerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            rows = rows.filter { row in
                row.recordingId.localizedCaseInsensitiveContains(q)
                    || row.filename.localizedCaseInsensitiveContains(q)
                    || row.cameraId.localizedCaseInsensitiveContains(q)
                    || row.locationTag.localizedCaseInsensitiveContains(q)
                    || row.sectionName.localizedCaseInsensitiveContains(q)
            }
        }
        return rows.sorted(using: recordingSortOrder)
    }

    public var displayedCycleRows: [CycleExplorerRow] {
        var rows = cycleRows
        switch cycleStatusFilter {
        case .all: break
        case .completeOnly: rows = rows.filter(\.isComplete)
        case .incompleteOnly: rows = rows.filter { !$0.isComplete }
        }
        if let exc = cycleExcavatorFilter {
            rows = rows.filter { $0.excavatorId == exc }
        }
        if let trk = cycleTruckFilter {
            rows = rows.filter { $0.truckLabel == trk }
        }
        if cycleUncertainOnly {
            rows = rows.filter { $0.uncertainSegmentCount > 0 }
        }
        let q = explorerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            rows = rows.filter { row in
                row.cycleId.localizedCaseInsensitiveContains(q)
                    || row.truckLabel.localizedCaseInsensitiveContains(q)
                    || row.excavatorId.localizedCaseInsensitiveContains(q)
                    || row.cycleStatus.localizedCaseInsensitiveContains(q)
            }
        }
        return rows
    }

    public var displayedStateTimingRows: [StateTimingExplorerRow] {
        var rows = stateTimingRows
        switch timingRoleFilter {
        case .all: break
        case .excavatorOnly: rows = rows.filter { $0.machineRole == "Excavator" }
        case .truckOnly: rows = rows.filter { $0.machineRole == "Truck" }
        }
        if let st = timingStateFilter {
            rows = rows.filter { $0.typedState == st }
        }
        if timingUncertainOnly {
            rows = rows.filter(\.isUncertain)
        }
        let q = explorerSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            rows = rows.filter { row in
                row.segmentId.localizedCaseInsensitiveContains(q)
                    || row.machineId.localizedCaseInsensitiveContains(q)
                    || row.state.localizedCaseInsensitiveContains(q)
            }
        }
        return rows
    }

    public var availableCycleExcavators: [String] {
        Array(Set(cycleRows.map(\.excavatorId))).sorted()
    }

    public var availableCycleTrucks: [String] {
        Array(Set(cycleRows.map(\.truckLabel))).sorted()
    }

    // MARK: - Bidirectional Sort Sync

    public func applyToolbarRecordingSort() {
        guard !isSyncingSortOrder else { return }
        isSyncingSortOrder = true
        defer { isSyncingSortOrder = false }

        let order: SortOrder = recordingSortAscending ? .forward : .reverse
        let primary: KeyPathComparator<RecordingExplorerRow>
        switch recordingSortField {
        case .dateDesc: primary = KeyPathComparator(\.startDate, order: order)
        case .cyclesDesc: primary = KeyPathComparator(\.totalCycleCount, order: order)
        case .passesDesc: primary = KeyPathComparator(\.avgPassesPerCycle, order: order)
        case .queueDesc: primary = KeyPathComparator(\.avgQueueTimeS, order: order)
        case .loadDesc: primary = KeyPathComparator(\.avgLoadDurationS, order: order)
        case .cameraAsc: primary = KeyPathComparator(\.cameraId, order: order)
        }
        recordingSortOrder = [primary, KeyPathComparator(\.startDate, order: .reverse)]
    }

    public func syncToolbarSortFromTable(_ newOrder: [KeyPathComparator<RecordingExplorerRow>]) {
        guard !isSyncingSortOrder, let primary = newOrder.first else { return }
        isSyncingSortOrder = true
        defer { isSyncingSortOrder = false }

        recordingSortAscending = (primary.order == .forward)
        if primary.keyPath == \RecordingExplorerRow.startDate {
            recordingSortField = .dateDesc
        } else if primary.keyPath == \RecordingExplorerRow.totalCycleCount {
            recordingSortField = .cyclesDesc
        } else if primary.keyPath == \RecordingExplorerRow.avgPassesPerCycle {
            recordingSortField = .passesDesc
        } else if primary.keyPath == \RecordingExplorerRow.avgQueueTimeS {
            recordingSortField = .queueDesc
        } else if primary.keyPath == \RecordingExplorerRow.avgLoadDurationS {
            recordingSortField = .loadDesc
        } else if primary.keyPath == \RecordingExplorerRow.cameraId {
            recordingSortField = .cameraAsc
        }
    }

    // MARK: - Drilldown State Transitions

    public func resetForClusterChange() {
        recordingRows = []
        explorerLevel = .recordings
    }

    public func beginOpenRecording(
        _ row: RecordingExplorerRow,
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO]
    ) {
        explorerLevel = .cycles(recording: row)
        explorerSearchText = ""
        cycleStatusFilter = .all
        cycleExcavatorFilter = nil
        cycleTruckFilter = nil
        cycleUncertainOnly = false
        rebuildLayer2Cycles(cycles: cycles, segments: segments)
    }

    public func beginOpenCycle(
        _ row: CycleExplorerRow,
        in recordingRow: RecordingExplorerRow,
        cycles: [HaulCycleDTO],
        segments: [StateSegmentDTO]
    ) {
        explorerLevel = .stateTimings(recording: recordingRow, cycle: row)
        explorerSearchText = ""
        timingRoleFilter = .all
        timingStateFilter = nil
        timingUncertainOnly = false
        rebuildLayer3Timings(cycleId: row.cycleId, cycles: cycles, segments: segments)
    }

    public func popToRecordings() {
        explorerLevel = .recordings
        explorerSearchText = ""
    }

    public func popToCycles(cyclesProvider: (String) -> [HaulCycleDTO], segmentsProvider: (String) -> [StateSegmentDTO]) {
        guard case .stateTimings(let recRow, _) = explorerLevel else { return }
        explorerLevel = .cycles(recording: recRow)
        explorerSearchText = ""
        rebuildLayer2Cycles(
            cycles: cyclesProvider(recRow.recordingId),
            segments: segmentsProvider(recRow.recordingId)
        )
    }

    public func rebuildLayer2Cycles(cycles: [HaulCycleDTO], segments: [StateSegmentDTO]) {
        cycleRows = DataExplorerBuilder.buildCycleRows(cycles: cycles, segments: segments)
    }

    public func rebuildLayer3Timings(cycleId: String, cycles: [HaulCycleDTO], segments: [StateSegmentDTO]) {
        guard let cycle = cycles.first(where: { $0.cycleId == cycleId }) else {
            stateTimingRows = []
            scoopTimingRows = []
            return
        }
        let built = DataExplorerBuilder.buildStateTimingRows(cycle: cycle, allRecordingSegments: segments)
        stateTimingRows = built.segments
        scoopTimingRows = built.scoops
    }

    public func reconcileAfterRecordingSnapshotUpdate(
        cyclesProvider: (String) -> [HaulCycleDTO],
        segmentsProvider: (String) -> [StateSegmentDTO]
    ) {
        switch explorerLevel {
        case .recordings:
            break
        case .cycles(let oldRecRow):
            if let updated = recordingRows.first(where: { $0.recordingId == oldRecRow.recordingId }) {
                explorerLevel = .cycles(recording: updated)
                rebuildLayer2Cycles(
                    cycles: cyclesProvider(updated.recordingId),
                    segments: segmentsProvider(updated.recordingId)
                )
            } else {
                explorerLevel = .recordings
            }
        case .stateTimings(let oldRecRow, let oldCycRow):
            if let updatedRec = recordingRows.first(where: { $0.recordingId == oldRecRow.recordingId }) {
                let recCycles = cyclesProvider(updatedRec.recordingId)
                let recSegments = segmentsProvider(updatedRec.recordingId)
                rebuildLayer2Cycles(cycles: recCycles, segments: recSegments)
                if let updatedCyc = cycleRows.first(where: { $0.cycleId == oldCycRow.cycleId }) {
                    explorerLevel = .stateTimings(recording: updatedRec, cycle: updatedCyc)
                    rebuildLayer3Timings(cycleId: updatedCyc.cycleId, cycles: recCycles, segments: recSegments)
                } else {
                    explorerLevel = .cycles(recording: updatedRec)
                }
            } else {
                explorerLevel = .recordings
            }
        }
    }
}
