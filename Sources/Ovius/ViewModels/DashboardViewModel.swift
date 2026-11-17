import Foundation
import Observation

/// Coordinates the 1-month default first-cluster load, PowerBI-style cross-filtering across
/// the 4 sticky widgets, diagnostic card highlighting, loading placeholders, and 3-layer Data Explorer.
@MainActor
@Observable
public final class DashboardViewModel {
    private let databaseManager: DatabaseManager
    private let networkManager: NetworkManager

    // Grouping & Settings
    public var clusters: [Cluster] = []
    public var calcConfig = TelemetryCalculationConfig()

    // Reactive Filter State (Widgets 1-4)
    public var filterState = DashboardFilterState()

    // Computed Presentation Outputs
    public var activeSnapshot: SectionMetricsSnapshot?
    public var clusterBaseline: ClusterBaselineStats?
    public var topLeads: [SectionEvaluatedLead] = []
    public var activeDiagnostics: [ActiveDiagnosticViewItem] = []

    // Deferred Lead / Diagnostic Refresh State (Widget 4 manual reload trigger)
    public var hasPendingLeadsUpdate: Bool = false
    private var hasCommittedPresentation: Bool = false
    private var pendingPresentation: PendingPresentation?

    // Active Recording Counts / Options for Selector & Calendar Widgets
    public var clusterRecordings: [RecordingDTO] = []
    public var filteredRecordings: [RecordingDTO] = []
    public var pinCandidates: [RecordingDTO] = []
    public var recordingCountByDate: [Date: Int] = [:]
    public var activeRecordingForGantt: RecordingDTO?
    public var ganttSegments: [GanttSegmentItem] = []
    public var ganttConcurrencyAudit = GanttConcurrencyAudit()
    public var ganttConflictIntervals: [GanttConflictInterval] = []
    public var userSelectedGanttRecId: String?

    // Loading & Status States
    public var referenceDate: Date = .now
    public var isInitialLoading: Bool = false
    public var isFilteringData: Bool = false
    public var isExplorerDrilldownLoading: Bool = false
    public var isDataTruncated: Bool = false
    public var errorMessage: String?
    public var lastRefreshedAt: Date?

    // Data Explorer State (Layer 1 -> Layer 2 -> Layer 3)
    public var explorerLevel: ExplorerDrilldownLevel = .recordings
    public var explorerSearchText: String = ""

    // Layer 1 Explorer Controls (Single synchronized source of truth with Table header sorting)
    public var recordingSortField: RecordingSortField = .dateDesc
    public var recordingSortAscending: Bool = false
    public var recordingSortOrder: [KeyPathComparator<RecordingExplorerRow>] = [
        .init(\.startDate, order: .reverse)
    ]
    public var explorerSectionFilterId: String? = nil
    public var explorerCameraFilterId: String? = nil
    public var explorerMinCycles: Int = 0
    public var recordingRows: [RecordingExplorerRow] = []

    // Layer 2 Explorer Controls
    public var cycleStatusFilter: CycleStatusFilter = .all
    public var cycleExcavatorFilter: String? = nil
    public var cycleTruckFilter: String? = nil
    public var cycleUncertainOnly: Bool = false
    public var cycleRows: [CycleExplorerRow] = []

    // Layer 3 Explorer Controls
    public var timingRoleFilter: MachineRoleFilter = .all
    public var timingStateFilter: MachineState? = nil
    public var timingUncertainOnly: Bool = false
    public var stateTimingRows: [StateTimingExplorerRow] = []
    public var scoopTimingRows: [ScoopTimingExplorerRow] = []

    // In-memory AWS Telemetry Caches (Zero redundant refetches during cross-filtering)
    private var cachedClusterId: String?
    private var cachedStartDate: Date?
    private var cachedEndDate: Date?
    private var cachedDiscoveryTruncated: Bool = false
    private var cachedCycleTruncated: Bool = false
    private var cachedSegmentTruncated: Bool = false
    private var cachedCyclesByRec: [String: [HaulCycleDTO]] = [:]
    private var cachedSegmentsByRec: [String: [StateSegmentDTO]] = [:]
    private var fullDrilldownFetchedRecIds: Set<String> = []
    private var isSyncingSortOrder: Bool = false
    private var filterTask: Task<Void, Never>?
    private var drilldownTask: Task<Void, Never>?

    public init(
        databaseManager: DatabaseManager? = nil,
        networkManager: NetworkManager? = nil
    ) {
        self.databaseManager = databaseManager ?? .shared
        self.networkManager = networkManager ?? .shared
    }

    // MARK: - Derived Properties

    public var activeCluster: Cluster? {
        if let cid = filterState.clusterId,
           let match = clusters.first(where: { $0.clusterId == cid }) {
            return match
        }
        return clusters.first
    }

    public var sectionsInActiveCluster: [Section] {
        guard let cluster = activeCluster else { return [] }
        return cluster.sections.sorted { $0.sectionId < $1.sectionId }
    }

    public var camerasInScope: [String] {
        let sections = activeSectionsScope
        return Array(Set(sections.flatMap(\.cameraIds))).sorted()
    }

    public var activeSectionsScope: [Section] {
        let all = sectionsInActiveCluster
        if filterState.selectedSectionIds.isEmpty {
            return all
        }
        return all.filter { filterState.selectedSectionIds.contains($0.sectionId) }
    }

    /// Diagnostic IDs associated with the currently highlighted Lead in Widget 4.
    public var highlightedDiagnosticIds: Set<String> {
        guard let highlightedId = filterState.highlightedLeadEntryId,
              let lead = topLeads.first(where: { $0.id == highlightedId }) else {
            return []
        }
        return Set(lead.associatedDiagnosticIds)
    }

    public var highlightedLeadName: String? {
        guard let highlightedId = filterState.highlightedLeadEntryId,
              let lead = topLeads.first(where: { $0.id == highlightedId }) else {
            return nil
        }
        return "\(lead.evaluatedLead.lead.name) (\(lead.sectionName))"
    }

    // MARK: - Initial Load & Refresh (First Cluster, Last 1 Month)

    public func loadInitialAndRefresh() async {
        loadCatalogAndConfig()
        guard let firstCluster = clusters.first else { return }
        filterState.clusterId = firstCluster.clusterId
        await loadClusterData(for: firstCluster, forceRefresh: true, resetDateToLastMonth: true)
    }

    public func loadCatalogAndConfig() {
        do {
            clusters = try databaseManager.fetchClusters()
            if filterState.clusterId == nil {
                filterState.clusterId = clusters.first?.clusterId
            }
            let settings = try databaseManager.fetchSettings()
            let updatedConfig = TelemetryCalculationConfig(settings: settings)
            calcConfig = updatedConfig
            let newBaseMin = updatedConfig.parsedShiftStartMinutes.first ?? 360
            filterState.shiftBaseMinuteUTC = newBaseMin
            if filterState.timePreset != .custom,
               let presetRange = filterState.timePreset.offsetRange(using: updatedConfig) {
                filterState.todStartS = presetRange.startS
                filterState.todEndS = presetRange.endS
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshAll() async {
        guard let cluster = activeCluster else { return }
        await loadClusterData(for: cluster, forceRefresh: true, resetDateToLastMonth: false)
    }

    // MARK: - Cross-Filter Mutators (Widgets 1-4)

    public func selectCluster(_ clusterId: String) {
        guard cachedClusterId != clusterId else { return }
        filterState.clusterId = clusterId
        filterState.selectedSectionIds = []
        filterState.selectedCameraIds = []
        filterState.selectedRecordingIds = []
        filterState.highlightedLeadEntryId = nil
        userSelectedGanttRecId = nil
        hasCommittedPresentation = false
        pendingPresentation = nil
        hasPendingLeadsUpdate = false
        explorerLevel = .recordings

        guard let cluster = activeCluster else { return }
        scheduleAsyncUpdate { [weak self] in
            await self?.loadClusterData(for: cluster, forceRefresh: false, resetDateToLastMonth: true)
        }
    }

    public func toggleSectionFilter(_ sectionId: String) {
        if filterState.selectedSectionIds.contains(sectionId) {
            filterState.selectedSectionIds.remove(sectionId)
        } else {
            filterState.selectedSectionIds.insert(sectionId)
        }
        // Prune cameras & pinned recordings outside remaining sections cleanly.
        let validCams = Set(activeSectionsScope.flatMap(\.cameraIds))
        filterState.selectedCameraIds = filterState.selectedCameraIds.intersection(validCams)
        if !validCams.isEmpty {
            let validRecs = Set(clusterRecordings.filter { validCams.contains($0.cameraId) }.map(\.recordingId))
            filterState.selectedRecordingIds = filterState.selectedRecordingIds.intersection(validRecs)
        }
        scheduleFilterRecompute()
    }

    public func clearScopeSelection() {
        filterState.selectedSectionIds = []
        filterState.selectedCameraIds = []
        filterState.selectedRecordingIds = []
        scheduleFilterRecompute()
    }

    public func clearRecordingPins() {
        guard !filterState.selectedRecordingIds.isEmpty else { return }
        filterState.selectedRecordingIds = []
        scheduleFilterRecompute()
    }

    public func toggleCameraFilter(_ cameraId: String) {
        if filterState.selectedCameraIds.contains(cameraId) {
            filterState.selectedCameraIds.remove(cameraId)
        } else {
            filterState.selectedCameraIds.insert(cameraId)
        }
        scheduleFilterRecompute()
    }

    public func toggleRecordingFilter(_ recordingId: String) {
        if filterState.selectedRecordingIds.contains(recordingId) {
            filterState.selectedRecordingIds.remove(recordingId)
        } else {
            filterState.selectedRecordingIds.insert(recordingId)
        }
        scheduleFilterRecompute()
    }

    public func selectGanttRecording(_ recordingId: String) {
        userSelectedGanttRecId = recordingId
        scheduleFilterRecompute()
    }

    public func applyToolbarRecordingSort() {
        guard !isSyncingSortOrder else { return }
        isSyncingSortOrder = true
        defer { isSyncingSortOrder = false }

        let order: SortOrder = recordingSortAscending ? .forward : .reverse
        let primary: KeyPathComparator<RecordingExplorerRow>
        switch recordingSortField {
        case .dateDesc: primary = KeyPathComparator(\.startDate, order: order)
        case .cyclesDesc: primary = KeyPathComparator(\.totalCycleCount, order: order)
        case .volumeDesc: primary = KeyPathComparator(\.totalVolumeM3, order: order)
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
        } else if primary.keyPath == \RecordingExplorerRow.totalVolumeM3 {
            recordingSortField = .volumeDesc
        } else if primary.keyPath == \RecordingExplorerRow.avgQueueTimeS {
            recordingSortField = .queueDesc
        } else if primary.keyPath == \RecordingExplorerRow.avgLoadDurationS {
            recordingSortField = .loadDesc
        } else if primary.keyPath == \RecordingExplorerRow.cameraId {
            recordingSortField = .cameraAsc
        }
    }

    public func applyDatePreset(_ preset: DateRangePreset) {
        filterState.datePreset = preset
        let bounds = preset.bounds(endingAt: referenceDate)
        filterState.startDate = bounds.start
        filterState.endDate = bounds.end
        scheduleDateAwareUpdate()
    }

    public func applyCustomDateRange(start: Date, end: Date) {
        let lo = OviusFormat.utcStartOfDay(for: min(start, end))
        let hi = OviusFormat.utcStartOfDay(for: max(start, end)).addingTimeInterval(86_399.0)
        filterState.datePreset = .custom
        filterState.startDate = lo
        filterState.endDate = hi
        scheduleDateAwareUpdate()
    }

    public func selectSingleCalendarDate(_ day: Date) {
        let lo = OviusFormat.utcStartOfDay(for: day)
        let hi = lo.addingTimeInterval(86_399.0)
        filterState.datePreset = .custom
        filterState.startDate = lo
        filterState.endDate = hi
        scheduleDateAwareUpdate()
    }

    public func applyTimePreset(_ preset: ShiftTimePreset) {
        filterState.timePreset = preset
        if let range = preset.offsetRange(using: calcConfig) {
            filterState.todStartS = range.startS
            filterState.todEndS = range.endS
        }
        scheduleFilterRecompute()
    }

    public func applyCustomTimeRange(startS: Double, endS: Double) {
        let clampedLo = max(0, min(startS, endS))
        let clampedHi = min(43_200, max(startS, endS))
        filterState.timePreset = .custom
        filterState.todStartS = clampedLo
        filterState.todEndS = max(clampedLo + 60, clampedHi)
        scheduleFilterRecompute()
    }

    /// Widget 4 click: highlights associated Diagnostic Cards ONLY — never filters underlying data.
    public func toggleHighlightedLead(_ leadEntryId: String) {
        if filterState.highlightedLeadEntryId == leadEntryId {
            filterState.highlightedLeadEntryId = nil
        } else {
            filterState.highlightedLeadEntryId = leadEntryId
        }
    }

    /// Commits staged leads and diagnostic widget updates after record changes altered identified leads.
    public func applyPendingLeadsAndDiagnostics() {
        guard let staged = pendingPresentation else {
            hasPendingLeadsUpdate = false
            return
        }
        commitPresentation(staged.payload, diagnostics: staged.activeDiagnostics)
        pendingPresentation = nil
        hasPendingLeadsUpdate = false
    }

    public func resetAllFilters() {
        filterState.selectedSectionIds = []
        filterState.selectedCameraIds = []
        filterState.selectedRecordingIds = []
        filterState.datePreset = .last1Month
        let bounds = DateRangePreset.last1Month.bounds(endingAt: referenceDate)
        filterState.startDate = bounds.start
        filterState.endDate = bounds.end
        filterState.timePreset = .fullShift
        filterState.shiftBaseMinuteUTC = calcConfig.parsedShiftStartMinutes.first ?? 360
        let fullRange = ShiftTimePreset.fullShift.offsetRange(using: calcConfig) ?? (0, 43_200)
        filterState.todStartS = fullRange.startS
        filterState.todEndS = fullRange.endS
        filterState.highlightedLeadEntryId = nil
        userSelectedGanttRecId = nil
        explorerLevel = .recordings
        scheduleDateAwareUpdate()
    }

    // MARK: - 3-Layer Data Explorer Navigation & Filtering

    public func openRecording(_ row: RecordingExplorerRow) {
        drilldownTask?.cancel()
        explorerLevel = .cycles(recording: row)
        explorerSearchText = ""
        cycleStatusFilter = .all
        cycleExcavatorFilter = nil
        cycleTruckFilter = nil
        cycleUncertainOnly = false
        rebuildLayer2Cycles(for: row.recordingId)

        drilldownTask = Task {
            await ensureRecordingDrilldownLoaded(recordingId: row.recordingId)
            guard !Task.isCancelled else { return }
            rebuildLayer2Cycles(for: row.recordingId)
        }
    }

    public func openRecordingAndAwait(_ row: RecordingExplorerRow) async {
        openRecording(row)
        await drilldownTask?.value
    }

    public func openCycle(_ row: CycleExplorerRow) {
        guard case .cycles(let recordingRow) = explorerLevel else { return }
        drilldownTask?.cancel()
        explorerLevel = .stateTimings(recording: recordingRow, cycle: row)
        explorerSearchText = ""
        timingRoleFilter = .all
        timingStateFilter = nil
        timingUncertainOnly = false
        rebuildLayer3Timings(recordingId: recordingRow.recordingId, cycleId: row.cycleId)

        drilldownTask = Task {
            await ensureRecordingDrilldownLoaded(recordingId: recordingRow.recordingId)
            guard !Task.isCancelled else { return }
            rebuildLayer3Timings(recordingId: recordingRow.recordingId, cycleId: row.cycleId)
        }
    }

    public func openCycleAndAwait(_ row: CycleExplorerRow) async {
        openCycle(row)
        await drilldownTask?.value
    }

    public func popToRecordings() {
        drilldownTask?.cancel()
        explorerLevel = .recordings
        explorerSearchText = ""
    }

    public func popToCycles() {
        guard case .stateTimings(let recRow, _) = explorerLevel else { return }
        drilldownTask?.cancel()
        explorerLevel = .cycles(recording: recRow)
        explorerSearchText = ""
        rebuildLayer2Cycles(for: recRow.recordingId)
    }

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

    // MARK: - Private Network & Recompute Engine

    private func scheduleAsyncUpdate(_ operation: @escaping @MainActor () async -> Void) {
        filterTask?.cancel()
        filterTask = Task {
            await operation()
        }
    }

    private func scheduleDateAwareUpdate() {
        scheduleAsyncUpdate { [weak self] in
            guard let self, let cluster = self.activeCluster else { return }
            let needsRemoteFetch = self.cachedClusterId != cluster.clusterId
                || self.cachedStartDate == nil
                || self.cachedEndDate == nil
                || self.filterState.startDate < (self.cachedStartDate ?? .distantFuture)
                || self.filterState.endDate > (self.cachedEndDate ?? .distantPast)

            if needsRemoteFetch {
                await self.loadClusterData(for: cluster, forceRefresh: false, resetDateToLastMonth: false)
            } else {
                await self.recomputeFromCacheWithPlaceholder()
            }
        }
    }

    private func scheduleFilterRecompute() {
        scheduleAsyncUpdate { [weak self] in
            await self?.recomputeFromCacheWithPlaceholder()
        }
    }

    private func loadClusterData(
        for cluster: Cluster,
        forceRefresh: Bool,
        resetDateToLastMonth: Bool
    ) async {
        loadCatalogAndConfig()
        if let dbErr = databaseManager.lastError, errorMessage == nil {
            errorMessage = dbErr
        }

        let sections = cluster.sections.sorted { $0.sectionId < $1.sectionId }
        guard !sections.isEmpty else {
            activeSnapshot = nil
            clusterBaseline = nil
            topLeads = []
            activeDiagnostics = []
            recordingRows = []
            return
        }

        if forceRefresh {
            isInitialLoading = clusterRecordings.isEmpty
        }
        isFilteringData = true
        isDataTruncated = false
        errorMessage = nil
        defer {
            isInitialLoading = false
            isFilteringData = false
        }

        do {
            // 1. Discover all recordings for this cluster with explicit historical bounds.
            let discoveryFilters = databaseManager.makeFilters(
                for: cluster,
                startTime: "2020-01-01T00:00:00Z",
                endTime: OviusFormat.isoString(from: Date.now.addingTimeInterval(86_400)),
                limit: 2_000
            )
            let discoveryRes = try await networkManager.fetchAllRecordingsWithStatus(filters: discoveryFilters, maxPages: 5)
            guard !Task.isCancelled else { return }

            let discovered = discoveryRes.items
            clusterRecordings = discovered
            let latestRecDate = discovered.compactMap { OviusFormat.parseISODate($0.timestamp) }.max() ?? .now
            referenceDate = latestRecDate
            rebuildCalendarCounts(from: discovered)

            if resetDateToLastMonth {
                let defaultBounds = DateRangePreset.last1Month.bounds(endingAt: latestRecDate)
                filterState.datePreset = .last1Month
                filterState.startDate = defaultBounds.start
                filterState.endDate = defaultBounds.end
            }

            let fetchStart = filterState.startDate
            let fetchEnd = filterState.endDate
            let fetchRange = (startTime: OviusFormat.isoString(from: fetchStart), endTime: OviusFormat.isoString(from: fetchEnd))
            let segDayBounds = DateRangePreset.latestDay.bounds(endingAt: fetchEnd)

            struct SectionFetchSpec: Sendable {
                let sectionId: String
                let cycleFilters: TelemetryQueryFilters?
                let segmentFilters: TelemetryQueryFilters?
                let requestedSegRecIds: [String]
                let hasRecordings: Bool
            }

            let specs: [SectionFetchSpec] = sections.map { section in
                let secRecs = databaseManager.filterRecordings(discovered, matching: section).filter { rec in
                    guard let d = OviusFormat.parseISODate(rec.timestamp) else { return false }
                    return d >= fetchStart && d <= fetchEnd
                }
                let maxDurS = max(43_200.0, secRecs.map(\.durationS).max() ?? 43_200.0)
                let segRecIds = secRecs.filter { rec in
                    guard let d = OviusFormat.parseISODate(rec.timestamp) else { return false }
                    return d >= segDayBounds.start && d <= segDayBounds.end
                }.map(\.recordingId)

                let cycleFilters: TelemetryQueryFilters?
                if secRecs.isEmpty {
                    cycleFilters = nil
                } else if secRecs.count <= 60 {
                    cycleFilters = TelemetryQueryFilters(
                        recordingIds: secRecs.map(\.recordingId),
                        todEndS: maxDurS,
                        includeScoops: false,
                        limit: 15_000
                    )
                } else {
                    cycleFilters = databaseManager.makeFilters(
                        for: section,
                        startTime: fetchRange.startTime,
                        endTime: fetchRange.endTime,
                        todEndS: maxDurS,
                        includeScoops: false,
                        limit: 15_000
                    )
                }

                let segFilters: TelemetryQueryFilters? = segRecIds.isEmpty ? nil : TelemetryQueryFilters(
                    recordingIds: segRecIds,
                    todEndS: maxDurS,
                    limit: 15_000
                )
                return SectionFetchSpec(
                    sectionId: section.sectionId,
                    cycleFilters: cycleFilters,
                    segmentFilters: segFilters,
                    requestedSegRecIds: segRecIds,
                    hasRecordings: !secRecs.isEmpty
                )
            }

            let nm = networkManager
            let maxPagesPerSection = filterState.datePreset == .last3Months ? 12 : 8

            struct FetchedSectionPayload: Sendable {
                let cycles: [HaulCycleDTO]
                let segments: [StateSegmentDTO]
                let requestedSegRecIds: [String]
                let cycleHitCap: Bool
                let segmentHitCap: Bool
            }

            let payloads = try await withThrowingTaskGroup(of: FetchedSectionPayload.self) { group in
                for spec in specs {
                    group.addTask {
                        guard spec.hasRecordings else {
                            return FetchedSectionPayload(
                                cycles: [],
                                segments: [],
                                requestedSegRecIds: [],
                                cycleHitCap: false,
                                segmentHitCap: false
                            )
                        }
                        async let cyclesTask: (items: [HaulCycleDTO], hitPageCap: Bool) = {
                            guard let cf = spec.cycleFilters else { return ([], false) }
                            return try await nm.fetchAllCyclesWithStatus(filters: cf, maxPages: maxPagesPerSection)
                        }()
                        async let segsTask: (items: [StateSegmentDTO], hitPageCap: Bool) = {
                            guard let sf = spec.segmentFilters else { return ([], false) }
                            return try await nm.fetchAllSegmentsWithStatus(filters: sf, maxPages: 4)
                        }()
                        let cycRes = try await cyclesTask
                        let segRes = try await segsTask
                        return FetchedSectionPayload(
                            cycles: cycRes.items,
                            segments: segRes.items,
                            requestedSegRecIds: spec.requestedSegRecIds,
                            cycleHitCap: cycRes.hitPageCap,
                            segmentHitCap: segRes.hitPageCap
                        )
                    }
                }
                var out: [FetchedSectionPayload] = []
                for try await item in group {
                    out.append(item)
                }
                return out
            }
            guard !Task.isCancelled else { return }

            if forceRefresh {
                cachedCyclesByRec = [:]
                cachedSegmentsByRec = [:]
                fullDrilldownFetchedRecIds = []
            }

            for item in payloads {
                let byRecC = Dictionary(grouping: item.cycles, by: \.recordingId)
                for (recId, cycs) in byRecC where !fullDrilldownFetchedRecIds.contains(recId) {
                    cachedCyclesByRec[recId] = cycs
                }
                let byRecS = Dictionary(grouping: item.segments, by: \.recordingId)
                for recId in item.requestedSegRecIds where !fullDrilldownFetchedRecIds.contains(recId) {
                    cachedSegmentsByRec[recId] = byRecS[recId] ?? []
                }
            }

            cachedClusterId = cluster.clusterId
            cachedStartDate = fetchStart
            cachedEndDate = fetchEnd
            cachedDiscoveryTruncated = discoveryRes.hitPageCap
            cachedCycleTruncated = payloads.contains(where: \.cycleHitCap)
            cachedSegmentTruncated = payloads.contains(where: \.segmentHitCap)
            isDataTruncated = cachedDiscoveryTruncated || cachedCycleTruncated || cachedSegmentTruncated

            await ensureSegmentsLoadedForActiveSlice()
            guard !Task.isCancelled else { return }
            lastRefreshedAt = .now

            let commitImmediately = !hasCommittedPresentation || forceRefresh || resetDateToLastMonth
            await evaluateAndProjectFromCache(commitDiagnosticChangesImmediately: commitImmediately)
        } catch {
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recomputeFromCacheWithPlaceholder() async {
        isFilteringData = true
        defer { isFilteringData = false }
        // Yield cleanly so SwiftUI paints the loading placeholder before async evaluation runs.
        await Task.yield()
        await ensureSegmentsLoadedForActiveSlice()
        guard !Task.isCancelled else { return }
        await evaluateAndProjectFromCache(commitDiagnosticChangesImmediately: !hasCommittedPresentation)
    }

    /// Ensures active slices (compact `<= 15` scopes, selected Gantt preview, and every baseline section inside
    /// the selected date window) have aligned segments cached so cross-filtering never compares empty segments vs peers.
    private func ensureSegmentsLoadedForActiveSlice() async {
        let allSections = sectionsInActiveCluster
        let dateRecs = clusterRecordings.filter { rec in
            guard let d = OviusFormat.parseISODate(rec.timestamp) else { return false }
            return d >= filterState.startDate && d <= filterState.endDate
        }
        let scopedRecs = computeFilteredRecordings()
        var candidateIds: [String] = []

        // 1. If user narrowed to <= 15 clips (e.g. 1D or pinned cameras/clips), fetch all missing scoped clip segments.
        if scopedRecs.count > 0 && scopedRecs.count <= 15 {
            for rec in scopedRecs where cachedSegmentsByRec[rec.recordingId] == nil {
                candidateIds.append(rec.recordingId)
            }
        }

        // 2. Ensure user-selected Gantt recording has segments fetched if not yet cached.
        if let userGanttId = userSelectedGanttRecId,
           scopedRecs.contains(where: { $0.recordingId == userGanttId }),
           cachedSegmentsByRec[userGanttId] == nil {
            candidateIds.append(userGanttId)
        }

        // 3. Baseline fairness: ensure every cluster section in dateRecs has at least its latest day inside [startDate, endDate] loaded.
        for section in allSections {
            let secDateRecs = databaseManager.filterRecordings(dateRecs, matching: section)
            guard !secDateRecs.isEmpty else { continue }
            let hasAnyCachedInRange = secDateRecs.contains { cachedSegmentsByRec[$0.recordingId] != nil }
            if !hasAnyCachedInRange {
                if let latestDayInWindow = secDateRecs.compactMap({ OviusFormat.parseISODate($0.timestamp) }).max() {
                    let latestDayStart = OviusFormat.utcStartOfDay(for: latestDayInWindow)
                    for rec in secDateRecs {
                        if let recDate = OviusFormat.parseISODate(rec.timestamp),
                           OviusFormat.utcStartOfDay(for: recDate) == latestDayStart,
                           cachedSegmentsByRec[rec.recordingId] == nil {
                            candidateIds.append(rec.recordingId)
                        }
                    }
                }
            }
        }

        let uniqueMissing = Array(Set(candidateIds))
        guard !uniqueMissing.isEmpty else { return }

        let batchSize = 15
        for startIdx in stride(from: 0, to: uniqueMissing.count, by: batchSize) {
            let batch = Array(uniqueMissing[startIdx..<min(startIdx + batchSize, uniqueMissing.count)])
            let maxDurS = batch.compactMap { id in
                clusterRecordings.first(where: { $0.recordingId == id })?.durationS
            }.max() ?? 43_200.0

            do {
                let filters = TelemetryQueryFilters(
                    recordingIds: batch,
                    todEndS: max(43_200.0, maxDurS),
                    limit: 15_000
                )
                let res = try await networkManager.fetchAllSegmentsWithStatus(filters: filters, maxPages: 4)
                let grouped = Dictionary(grouping: res.items, by: \.recordingId)
                for recId in batch where !fullDrilldownFetchedRecIds.contains(recId) {
                    cachedSegmentsByRec[recId] = grouped[recId] ?? []
                }
                if res.hitPageCap {
                    cachedSegmentTruncated = true
                    isDataTruncated = true
                }
            } catch {
                // Preserve partial cache gracefully without disrupting cross-filtering.
            }
        }
    }

    private func ensureRecordingDrilldownLoaded(recordingId: String) async {
        guard !fullDrilldownFetchedRecIds.contains(recordingId) else { return }
        isExplorerDrilldownLoading = true
        defer { isExplorerDrilldownLoading = false }

        do {
            let recDur = clusterRecordings.first { $0.recordingId == recordingId }?.durationS ?? 43_200.0
            let filters = TelemetryQueryFilters(
                recordingIds: [recordingId],
                todEndS: max(43_200.0, recDur),
                includeSegments: true,
                includeScoops: true,
                limit: 15_000
            )
            let bundle = try await networkManager.fetchAllMetrics(filters: filters, maxPages: 4)
            cachedCyclesByRec[recordingId] = bundle.haulCycles
            cachedSegmentsByRec[recordingId] = bundle.stateSegments
            fullDrilldownFetchedRecIds.insert(recordingId)
        } catch {
            errorMessage = "Drilldown load failed: \(error.localizedDescription)"
        }
    }

    private struct SectionCalcInput: Sendable {
        let sectionId: String
        let sectionName: String
        let recordings: [RecordingDTO]
    }

    private struct ComputedPresentationPayload: Sendable {
        let baseline: ClusterBaselineStats
        let activeSnapshot: SectionMetricsSnapshot
        let activeRecordingForGantt: RecordingDTO?
        let ganttSegments: [GanttSegmentItem]
        let ganttConcurrencyAudit: GanttConcurrencyAudit
        let ganttConflictIntervals: [GanttConflictInterval]
        let topLeads: [SectionEvaluatedLead]
        let recordingRows: [RecordingExplorerRow]
    }

    private struct PendingPresentation {
        let payload: ComputedPresentationPayload
        let activeDiagnostics: [ActiveDiagnosticViewItem]
    }

    private nonisolated static func computePresentationPayload(
        clusterId: String,
        targetName: String,
        sectionInputs: [SectionCalcInput],
        scopedSectionIds: Set<String>,
        isPinningSubslice: Bool,
        scopedRecs: [RecordingDTO],
        preferredGanttRec: RecordingDTO?,
        secMapByRecId: [String: (sectionId: String, sectionName: String)],
        cyclesByRec: [String: [HaulCycleDTO]],
        segsByRec: [String: [StateSegmentDTO]],
        config: TelemetryCalculationConfig,
        patternSpecs: [PatternRuleSpec],
        leadSpecs: [LeadRuleSpec],
        diagIdsByLeadId: [String: [String]],
        todStartS: Double,
        todEndS: Double,
        todBaseMinuteUTC: Int
    ) throws -> ComputedPresentationPayload {
        try Task.checkCancellation()

        let sectionSnapshots: [SectionMetricsSnapshot] = try sectionInputs.map { sec in
            try Task.checkCancellation()
            let secRecs = sec.recordings
            let secCycles = secRecs.flatMap { cyclesByRec[$0.recordingId] ?? [] }
            let secSegRecs = secRecs.filter { segsByRec[$0.recordingId] != nil }
            let secSegCycles = secSegRecs.flatMap { cyclesByRec[$0.recordingId] ?? [] }
            let secSegs = secSegRecs.flatMap { segsByRec[$0.recordingId] ?? [] }

            return TelemetryMetricsCalculator.computeSectionSnapshot(
                sectionId: sec.sectionId,
                sectionName: sec.sectionName,
                recordings: secRecs,
                cycles: secCycles,
                segments: secSegs,
                config: config,
                segmentScopeRecordings: secSegRecs.isEmpty ? nil : secSegRecs,
                segmentScopeCycles: secSegRecs.isEmpty ? nil : secSegCycles,
                todStartS: todStartS,
                todEndS: todEndS,
                todBaseMinuteUTC: todBaseMinuteUTC
            )
        }

        let baseline = TelemetryMetricsCalculator.computeClusterBaseline(
            clusterId: clusterId,
            sectionSnapshots: sectionSnapshots
        )

        let scopedCycles = scopedRecs.flatMap { cyclesByRec[$0.recordingId] ?? [] }
        let scopedSegRecs = scopedRecs.filter { segsByRec[$0.recordingId] != nil }
        let scopedSegCycles = scopedSegRecs.flatMap { cyclesByRec[$0.recordingId] ?? [] }
        let scopedSegs = scopedSegRecs.flatMap { segsByRec[$0.recordingId] ?? [] }

        let activeSnap = TelemetryMetricsCalculator.computeSectionSnapshot(
            sectionId: "ACTIVE_SLICE",
            sectionName: targetName,
            recordings: scopedRecs,
            cycles: scopedCycles,
            segments: scopedSegs,
            config: config,
            segmentScopeRecordings: scopedSegRecs.isEmpty ? nil : scopedSegRecs,
            segmentScopeCycles: scopedSegRecs.isEmpty ? nil : scopedSegCycles,
            todStartS: todStartS,
            todEndS: todEndS,
            todBaseMinuteUTC: todBaseMinuteUTC
        )

        try Task.checkCancellation()

        let ganttSegs: [GanttSegmentItem]
        let ganttAudit: GanttConcurrencyAudit
        let ganttConflicts: [GanttConflictInterval]
        if let rec = preferredGanttRec {
            var boundsMap: [String: (lo: Double, hi: Double)] = [:]
            boundsMap[rec.recordingId] = TelemetryMetricsCalculator.clipBounds(
                for: rec,
                todStartS: todStartS,
                todEndS: todEndS,
                todBaseMinuteUTC: todBaseMinuteUTC
            )
            let recSegs = TelemetryMetricsCalculator.clipSegments(
                segsByRec[rec.recordingId] ?? [],
                todStartS: todStartS,
                todEndS: todEndS,
                boundsByRecordingId: boundsMap
            )
            let recCycles = TelemetryMetricsCalculator.filterCycles(
                cyclesByRec[rec.recordingId] ?? [],
                todStartS: todStartS,
                todEndS: todEndS,
                boundsByRecordingId: boundsMap
            )
            let drill = TelemetryMetricsCalculator.extractDrilldown(
                cycles: recCycles,
                segments: recSegs,
                config: config
            )
            ganttSegs = drill.ganttSegments
            ganttAudit = drill.audit
            ganttConflicts = drill.conflicts
        } else {
            ganttSegs = []
            ganttAudit = GanttConcurrencyAudit()
            ganttConflicts = []
        }

        let snapshotsToEvaluate: [SectionMetricsSnapshot] = isPinningSubslice
            ? [activeSnap]
            : sectionSnapshots.filter { scopedSectionIds.contains($0.sectionId) }

        var evaluatedList: [SectionEvaluatedLead] = []
        for secSnap in snapshotsToEvaluate where secSnap.totalCycleCount > 0 {
            let patResults = DiagnosticEvaluator.evaluatePatterns(
                patternSpecs,
                snapshot: secSnap,
                baseline: baseline
            )
            let leadResults = DiagnosticEvaluator.evaluateLeads(leadSpecs, patternResults: patResults)
            for result in leadResults where result.isFlagged {
                evaluatedList.append(
                    SectionEvaluatedLead(
                        sectionId: secSnap.sectionId,
                        sectionName: secSnap.sectionName,
                        evaluatedLead: result,
                        associatedDiagnosticIds: diagIdsByLeadId[result.lead.leadId] ?? []
                    )
                )
            }
        }

        evaluatedList.sort { lhs, rhs in
            if lhs.evaluatedLead.confidenceScore != rhs.evaluatedLead.confidenceScore {
                return lhs.evaluatedLead.confidenceScore > rhs.evaluatedLead.confidenceScore
            }
            if lhs.evaluatedLead.triggeredRequiredCount != rhs.evaluatedLead.triggeredRequiredCount {
                return lhs.evaluatedLead.triggeredRequiredCount > rhs.evaluatedLead.triggeredRequiredCount
            }
            return lhs.id < rhs.id
        }

        let top5 = Array(evaluatedList.prefix(5))
        let rows = DataExplorerBuilder.buildRecordingRows(
            recordings: scopedRecs,
            sectionNamesByRecordingId: secMapByRecId,
            cycles: scopedCycles,
            todStartS: todStartS,
            todEndS: todEndS,
            todBaseMinuteUTC: todBaseMinuteUTC,
            config: config
        )

        return ComputedPresentationPayload(
            baseline: baseline,
            activeSnapshot: activeSnap,
            activeRecordingForGantt: preferredGanttRec,
            ganttSegments: ganttSegs,
            ganttConcurrencyAudit: ganttAudit,
            ganttConflictIntervals: ganttConflicts,
            topLeads: top5,
            recordingRows: rows
        )
    }

    private func evaluateAndProjectFromCache(commitDiagnosticChangesImmediately: Bool = true) async {
        guard let cluster = activeCluster else { return }
        let allSections = sectionsInActiveCluster
        let configSnapshot = calcConfig

        var secMapByRecId: [String: (sectionId: String, sectionName: String)] = [:]
        var sectionInputs: [SectionCalcInput] = []

        let dateRecs = clusterRecordings.filter { rec in
            guard let d = OviusFormat.parseISODate(rec.timestamp) else { return false }
            return d >= filterState.startDate && d <= filterState.endDate
        }

        for section in allSections {
            let matched = databaseManager.filterRecordings(dateRecs, matching: section)
            sectionInputs.append(
                SectionCalcInput(
                    sectionId: section.sectionId,
                    sectionName: section.name,
                    recordings: matched
                )
            )
            for rec in matched {
                secMapByRecId[rec.recordingId] = (section.sectionId, section.name)
            }
        }

        let candidates = computePrePinFilteredRecordings()
            .sorted { $0.timestamp > $1.timestamp }
        pinCandidates = candidates

        let calendarScoped = computeCalendarScopeRecordings()
        rebuildCalendarCounts(from: calendarScoped)

        let scopedRecs = computeFilteredRecordings()
        filteredRecordings = scopedRecs

        let todStart = filterState.todStartS
        let todEnd = filterState.todEndS
        let todBaseMin = filterState.shiftBaseMinuteUTC
        let cyclesByRec = cachedCyclesByRec
        let segsByRec = cachedSegmentsByRec

        let preferredGanttRec: RecordingDTO?
        if let userId = userSelectedGanttRecId,
           let match = scopedRecs.first(where: { $0.recordingId == userId }) {
            preferredGanttRec = match
        } else {
            userSelectedGanttRecId = nil
            let withSegs = scopedRecs.filter { !(segsByRec[$0.recordingId]?.isEmpty ?? true) }
            preferredGanttRec = withSegs.sorted(by: { $0.timestamp > $1.timestamp }).first
                ?? scopedRecs.sorted(by: { $0.timestamp > $1.timestamp }).first
        }

        let targetName: String
        if let singlePinId = filterState.selectedRecordingIds.first, filterState.selectedRecordingIds.count == 1,
           let rec = scopedRecs.first(where: { $0.recordingId == singlePinId }) {
            targetName = rec.cameraId
        } else if filterState.selectedSectionIds.count == 1, let sec = activeSectionsScope.first {
            targetName = sec.name
        } else {
            targetName = cluster.name
        }

        let scopedSectionIds = Set(activeSectionsScope.map(\.sectionId))
        let isPinningSubslice = !filterState.selectedRecordingIds.isEmpty || !filterState.selectedCameraIds.isEmpty

        do {
            let patternModels = try databaseManager.fetchPatterns(activeOnly: true)
            let leadModels = try databaseManager.fetchLeads(activeOnly: true)
            let patternSpecs = patternModels.map(PatternRuleSpec.init)
            let leadSpecs = leadModels.map(LeadRuleSpec.init)
            let leadsModelById = Dictionary(uniqueKeysWithValues: leadModels.map { ($0.leadId, $0) })
            let diagIdsByLeadId = Dictionary(
                uniqueKeysWithValues: leadModels.map { lead in
                    (lead.leadId, lead.orderedDiagnostics.map(\.diagnosticId))
                }
            )

            let payload = try await Task.detached(priority: .userInitiated) {
                try Self.computePresentationPayload(
                    clusterId: cluster.clusterId,
                    targetName: targetName,
                    sectionInputs: sectionInputs,
                    scopedSectionIds: scopedSectionIds,
                    isPinningSubslice: isPinningSubslice,
                    scopedRecs: scopedRecs,
                    preferredGanttRec: preferredGanttRec,
                    secMapByRecId: secMapByRecId,
                    cyclesByRec: cyclesByRec,
                    segsByRec: segsByRec,
                    config: configSnapshot,
                    patternSpecs: patternSpecs,
                    leadSpecs: leadSpecs,
                    diagIdsByLeadId: diagIdsByLeadId,
                    todStartS: todStart,
                    todEndS: todEnd,
                    todBaseMinuteUTC: todBaseMin
                )
            }.value
            guard !Task.isCancelled else { return }

            let visibleLeadModels = payload.topLeads.compactMap { leadsModelById[$0.evaluatedLead.lead.leadId] }
            let nextDiagnostics = databaseManager.resolveDashboardDiagnostics(flaggedLeads: visibleLeadModels)

            applyComputedPresentation(
                payload,
                nextDiagnostics: nextDiagnostics,
                commitDiagnosticChangesImmediately: commitDiagnosticChangesImmediately
            )
        } catch {
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }

        switch explorerLevel {
        case .recordings:
            break
        case .cycles(let oldRecRow):
            if let updated = recordingRows.first(where: { $0.recordingId == oldRecRow.recordingId }) {
                explorerLevel = .cycles(recording: updated)
                rebuildLayer2Cycles(for: updated.recordingId)
            } else {
                explorerLevel = .recordings
            }
        case .stateTimings(let oldRecRow, let oldCycRow):
            if let updatedRec = recordingRows.first(where: { $0.recordingId == oldRecRow.recordingId }) {
                rebuildLayer2Cycles(for: updatedRec.recordingId)
                if let updatedCyc = cycleRows.first(where: { $0.cycleId == oldCycRow.cycleId }) {
                    explorerLevel = .stateTimings(recording: updatedRec, cycle: updatedCyc)
                    rebuildLayer3Timings(recordingId: updatedRec.recordingId, cycleId: updatedCyc.cycleId)
                } else {
                    explorerLevel = .cycles(recording: updatedRec)
                }
            } else {
                explorerLevel = .recordings
            }
        }
    }

    private func applyComputedPresentation(
        _ payload: ComputedPresentationPayload,
        nextDiagnostics: [ActiveDiagnosticViewItem],
        commitDiagnosticChangesImmediately: Bool
    ) {
        recordingRows = payload.recordingRows
        let leadsChanged = payload.topLeads.map(\.id) != topLeads.map(\.id)

        if !commitDiagnosticChangesImmediately && hasCommittedPresentation && leadsChanged {
            // Defer lead & diagnostic card updates until the user presses the Leads widget reload button.
            pendingPresentation = PendingPresentation(payload: payload, activeDiagnostics: nextDiagnostics)
            hasPendingLeadsUpdate = true
            return
        }

        commitPresentation(payload, diagnostics: nextDiagnostics)
        pendingPresentation = nil
        hasPendingLeadsUpdate = false
        hasCommittedPresentation = true
    }

    private func commitPresentation(
        _ payload: ComputedPresentationPayload,
        diagnostics: [ActiveDiagnosticViewItem]
    ) {
        clusterBaseline = payload.baseline
        activeSnapshot = payload.activeSnapshot
        activeRecordingForGantt = payload.activeRecordingForGantt
        ganttSegments = payload.ganttSegments
        ganttConcurrencyAudit = payload.ganttConcurrencyAudit
        ganttConflictIntervals = payload.ganttConflictIntervals
        topLeads = payload.topLeads
        recordingRows = payload.recordingRows
        activeDiagnostics = diagnostics

        if let highlighted = filterState.highlightedLeadEntryId,
           !topLeads.contains(where: { $0.id == highlighted }) {
            filterState.highlightedLeadEntryId = nil
        }
    }

    /// Deterministic in-memory helper used by unit tests to verify deferred lead-reload behavior without AWS calls.
    internal func seedCacheAndEvaluateForTesting(
        recordings: [RecordingDTO],
        cyclesByRec: [String: [HaulCycleDTO]],
        segmentsByRec: [String: [StateSegmentDTO]],
        referenceDate: Date,
        commitImmediately: Bool
    ) async {
        loadCatalogAndConfig()
        self.referenceDate = referenceDate
        let bounds = DateRangePreset.last1Month.bounds(endingAt: referenceDate)
        filterState.datePreset = .last1Month
        filterState.startDate = bounds.start
        filterState.endDate = bounds.end
        cachedClusterId = activeCluster?.clusterId
        cachedStartDate = bounds.start
        cachedEndDate = bounds.end
        clusterRecordings = recordings
        cachedCyclesByRec = cyclesByRec
        cachedSegmentsByRec = segmentsByRec
        await evaluateAndProjectFromCache(commitDiagnosticChangesImmediately: commitImmediately)
    }

    internal func reevaluateCachedForTesting(commitImmediately: Bool = false) async {
        await evaluateAndProjectFromCache(commitDiagnosticChangesImmediately: commitImmediately)
    }

    private func rebuildLayer2Cycles(for recordingId: String) {
        let rec = clusterRecordings.first(where: { $0.recordingId == recordingId })
        let cycles = cachedCyclesByRec[recordingId] ?? []
        let segs = cachedSegmentsByRec[recordingId] ?? []
        cycleRows = DataExplorerBuilder.buildCycleRows(
            recording: rec,
            cycles: cycles,
            segments: segs,
            todStartS: filterState.todStartS,
            todEndS: filterState.todEndS,
            todBaseMinuteUTC: filterState.shiftBaseMinuteUTC,
            config: calcConfig
        )
    }

    private func rebuildLayer3Timings(recordingId: String, cycleId: String) {
        guard let rec = clusterRecordings.first(where: { $0.recordingId == recordingId }),
              let cycle = (cachedCyclesByRec[recordingId] ?? []).first(where: { $0.cycleId == cycleId }) else {
            stateTimingRows = []
            scoopTimingRows = []
            return
        }
        let segs = cachedSegmentsByRec[recordingId] ?? []
        let built = DataExplorerBuilder.buildStateTimingRows(
            recording: rec,
            cycle: cycle,
            allRecordingSegments: segs,
            todStartS: filterState.todStartS,
            todEndS: filterState.todEndS,
            todBaseMinuteUTC: filterState.shiftBaseMinuteUTC,
            config: calcConfig
        )
        stateTimingRows = built.segments
        scoopTimingRows = built.scoops
    }

    private func computePrePinFilteredRecordings() -> [RecordingDTO] {
        let allowedSections = activeSectionsScope
        var sectionMatchedIds: Set<String> = []
        for section in allowedSections {
            for rec in databaseManager.filterRecordings(clusterRecordings, matching: section) {
                sectionMatchedIds.insert(rec.recordingId)
            }
        }

        return clusterRecordings.filter { rec in
            guard sectionMatchedIds.contains(rec.recordingId) else { return false }
            guard let date = OviusFormat.parseISODate(rec.timestamp) else { return false }
            guard date >= filterState.startDate && date <= filterState.endDate else { return false }

            if !filterState.selectedCameraIds.isEmpty && !filterState.selectedCameraIds.contains(rec.cameraId) {
                return false
            }
            return true
        }
    }

    private func computeFilteredRecordings() -> [RecordingDTO] {
        computePrePinFilteredRecordings().filter { rec in
            if !filterState.selectedRecordingIds.isEmpty && !filterState.selectedRecordingIds.contains(rec.recordingId) {
                return false
            }
            return true
        }
    }

    private func computeCalendarScopeRecordings() -> [RecordingDTO] {
        let allowedSections = activeSectionsScope
        var sectionMatchedIds: Set<String> = []
        for section in allowedSections {
            for rec in databaseManager.filterRecordings(clusterRecordings, matching: section) {
                sectionMatchedIds.insert(rec.recordingId)
            }
        }
        return clusterRecordings.filter { rec in
            guard sectionMatchedIds.contains(rec.recordingId) else { return false }
            if !filterState.selectedCameraIds.isEmpty && !filterState.selectedCameraIds.contains(rec.cameraId) {
                return false
            }
            if !filterState.selectedRecordingIds.isEmpty && !filterState.selectedRecordingIds.contains(rec.recordingId) {
                return false
            }
            return true
        }
    }

    private func rebuildCalendarCounts(from recordings: [RecordingDTO]) {
        var counts: [Date: Int] = [:]
        for rec in recordings {
            guard let parsed = OviusFormat.parseISODate(rec.timestamp) else { continue }
            let day = OviusFormat.utcStartOfDay(for: parsed)
            counts[day, default: 0] += 1
        }
        recordingCountByDate = counts
    }
}
