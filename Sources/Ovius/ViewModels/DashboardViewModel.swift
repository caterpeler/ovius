import Foundation
import Observation

/// Coordinates Dashboard lifecycle, cluster discovery, deferred selection refresh, and drilldown
/// loading across `DashboardSidebarViewModel`, `DataExplorerViewModel`, and `TelemetryRepository`.
@MainActor
@Observable
public final class DashboardViewModel {
    private let databaseManager: DatabaseManager
    private let repository: TelemetryRepository

    public let sidebar: DashboardSidebarViewModel
    public let explorer: DataExplorerViewModel

    // Applied Right-Panel Snapshot & Loading States
    public var filteredRecordings: [RecordingDTO] = []
    public var metricsSummary: DashboardMetricsSummary = .empty
    public var isInitialLoading: Bool = false
    public var isFilteringData: Bool = false
    public var isExplorerDrilldownLoading: Bool = false
    public var telemetryFetchProgress: String? = nil
    public var isDataTruncated: Bool = false
    public var errorMessage: String?
    public var lastRefreshedAt: Date?

    private var activeTask: Task<Void, Never>?
    private var drilldownTask: Task<Void, Never>?

    public init(
        databaseManager: DatabaseManager? = nil,
        networkManager: NetworkManager? = nil,
        diskCache: TelemetryDiskCache? = nil,
        referenceDate: Date = .now
    ) {
        let resolvedDB = databaseManager ?? .shared
        let resolvedNet = networkManager ?? .shared
        let resolvedCache = diskCache ?? .shared

        self.databaseManager = resolvedDB
        self.repository = TelemetryRepository(networkManager: resolvedNet, diskCache: resolvedCache)
        self.sidebar = DashboardSidebarViewModel(databaseManager: resolvedDB, referenceDate: referenceDate)
        self.explorer = DataExplorerViewModel()
    }

    // MARK: - Initial Load, Catalog & Cluster Switching

    public func loadInitialAndRefresh() async {
        loadCatalog()
        guard let initialCluster = sidebar.defaultInitialCluster() else { return }
        sidebar.filterState.clusterId = initialCluster.clusterId
        await loadClusterRecordings(for: initialCluster, forceRefresh: false)
    }

    public func loadCatalog() {
        if let err = sidebar.loadCatalog() {
            errorMessage = err
        }
        repository.invalidateRecordingRows()
    }

    public func refreshAll() async {
        guard let cluster = sidebar.activeCluster else { return }
        sidebar.resetSidebarPagination()
        await loadClusterRecordings(for: cluster, forceRefresh: true)
    }

    public func clearTelemetryCaches() {
        repository.clearAll()
    }

    public func selectCluster(_ clusterId: String) {
        guard repository.cachedClusterId != clusterId else { return }
        repository.resetForClusterSwitch()
        filteredRecordings = []
        metricsSummary = .empty
        explorer.resetForClusterChange()
        sidebar.prepareClusterSwitch(clusterId)

        guard let cluster = sidebar.activeCluster else { return }
        scheduleAsyncUpdate { [weak self] in
            await self?.loadClusterRecordings(for: cluster, forceRefresh: false)
        }
    }

    // MARK: - Selection Commit & Refresh

    /// Commits the pending sidebar selection and refreshes metric cards + Data Explorer.
    public func refreshPendingSelection() {
        scheduleAsyncUpdate { [weak self] in
            await self?.applyPendingSelectionAndRefresh()
        }
    }

    /// Async entry point fetching and projecting highlighted sidebar recordings to the content panel.
    public func applyPendingSelectionAndRefresh() async {
        sidebar.commitPendingSelection()
        explorer.popToRecordings()
        await fetchAppliedAndProject()
    }

    // MARK: - 3-Layer Explorer Navigation Coordination

    public func openRecording(_ row: RecordingExplorerRow) {
        drilldownTask?.cancel()
        explorer.beginOpenRecording(
            row,
            cycles: repository.cycles(for: row.recordingId),
            segments: repository.segments(for: row.recordingId)
        )

        drilldownTask = Task {
            await loadDrilldownTelemetry(recordingId: row.recordingId)
            guard !Task.isCancelled else { return }
            explorer.rebuildLayer2Cycles(
                cycles: repository.cycles(for: row.recordingId),
                segments: repository.segments(for: row.recordingId)
            )
        }
    }

    public func openRecordingAndAwait(_ row: RecordingExplorerRow) async {
        openRecording(row)
        await drilldownTask?.value
    }

    public func openCycle(_ row: CycleExplorerRow) {
        guard case .cycles(let recordingRow) = explorer.explorerLevel else { return }
        drilldownTask?.cancel()
        explorer.beginOpenCycle(
            row,
            in: recordingRow,
            cycles: repository.cycles(for: recordingRow.recordingId),
            segments: repository.segments(for: recordingRow.recordingId)
        )

        drilldownTask = Task {
            await loadDrilldownTelemetry(recordingId: recordingRow.recordingId)
            guard !Task.isCancelled else { return }
            explorer.rebuildLayer3Timings(
                cycleId: row.cycleId,
                cycles: repository.cycles(for: recordingRow.recordingId),
                segments: repository.segments(for: recordingRow.recordingId)
            )
        }
    }

    public func openCycleAndAwait(_ row: CycleExplorerRow) async {
        openCycle(row)
        await drilldownTask?.value
    }

    public func popToRecordings() {
        drilldownTask?.cancel()
        explorer.popToRecordings()
    }

    public func popToCycles() {
        drilldownTask?.cancel()
        explorer.popToCycles(
            cyclesProvider: repository.cycles(for:),
            segmentsProvider: repository.segments(for:)
        )
    }

    // MARK: - Private Pipeline

    private func scheduleAsyncUpdate(_ operation: @escaping @MainActor () async -> Void) {
        activeTask?.cancel()
        activeTask = Task {
            await operation()
        }
    }

    private func loadClusterRecordings(for cluster: Cluster, forceRefresh: Bool) async {
        loadCatalog()
        if let dbErr = databaseManager.lastError, errorMessage == nil {
            errorMessage = dbErr
        }

        let sections = cluster.sections.sorted { $0.sectionId < $1.sectionId }
        guard !sections.isEmpty else {
            sidebar.clearRecordings()
            filteredRecordings = []
            explorer.recordingRows = []
            metricsSummary = .empty
            return
        }

        isInitialLoading = sidebar.clusterRecordings.isEmpty || forceRefresh
        isFilteringData = true
        isDataTruncated = false
        errorMessage = nil
        defer {
            isInitialLoading = false
            isFilteringData = false
        }

        do {
            let filters = sidebar.makeClusterDiscoveryFilters(for: cluster)
            let discoveryRes = try await repository.fetchClusterRecordings(filters: filters)
            guard !Task.isCancelled else { return }

            if forceRefresh {
                repository.clearAll()
            }

            sidebar.replaceClusterRecordings(discoveryRes.items)
            repository.cachedClusterId = cluster.clusterId
            repository.cachedDiscoveryTruncated = discoveryRes.hitPageCap
            sidebar.reconcileSelectionAfterClusterLoad()

            await fetchAppliedAndProject(manageLoadingFlags: false, bypassDiskCache: forceRefresh)
            if !Task.isCancelled {
                lastRefreshedAt = .now
            }
        } catch {
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func fetchAppliedAndProject(
        manageLoadingFlags: Bool = true,
        bypassDiskCache: Bool = false
    ) async {
        if manageLoadingFlags {
            isFilteringData = true
            errorMessage = nil
        }
        defer {
            if manageLoadingFlags {
                isFilteringData = false
            }
        }

        let activeRecs = sidebar.resolveAppliedRecordings()
        filteredRecordings = activeRecs
        await Task.yield()
        guard !Task.isCancelled else { return }

        let targetIds = activeRecs.map(\.recordingId)
        if !targetIds.isEmpty {
            isExplorerDrilldownLoading = true
            defer {
                isExplorerDrilldownLoading = false
                telemetryFetchProgress = nil
            }
            do {
                try await repository.ensureLoaded(
                    recordingIds: targetIds,
                    recordingsById: sidebar.recordingsDictionary(),
                    sectionMapByRecId: sidebar.sectionMapByRecId,
                    bypassDiskCache: bypassDiskCache,
                    onProgress: { [weak self] progress in
                        self?.telemetryFetchProgress = progress
                    },
                    onPartialUpdate: { [weak self] in
                        self?.publishAppliedSnapshotSync(progressive: true)
                    }
                )
            } catch {
                if !(error is CancellationError) {
                    errorMessage = "Telemetry load failed: \(error.localizedDescription)"
                }
            }
            guard !Task.isCancelled else { return }
        }

        isDataTruncated = repository.hasTruncatedData
        if manageLoadingFlags {
            lastRefreshedAt = .now
        }
        await projectFromCache()
    }

    private func loadDrilldownTelemetry(recordingId: String) async {
        isExplorerDrilldownLoading = true
        defer {
            isExplorerDrilldownLoading = false
            telemetryFetchProgress = nil
        }
        do {
            try await repository.ensureLoaded(
                recordingIds: [recordingId],
                recordingsById: sidebar.recordingsDictionary(),
                sectionMapByRecId: sidebar.sectionMapByRecId
            )
        } catch {
            if !(error is CancellationError) {
                errorMessage = "Telemetry load failed: \(error.localizedDescription)"
            }
        }
    }

    private func publishAppliedSnapshotSync(progressive: Bool) {
        let activeRecs = sidebar.resolveAppliedRecordings()
        filteredRecordings = activeRecs
        let snapshot = repository.makeSnapshotSync(for: activeRecs, progressive: progressive)
        metricsSummary = snapshot.summary
        explorer.recordingRows = snapshot.rows
    }

    private func projectFromCache() async {
        guard sidebar.activeCluster != nil else { return }

        let activeRecs = sidebar.resolveAppliedRecordings()
        filteredRecordings = activeRecs

        let snapshot = await repository.buildSnapshot(
            for: activeRecs,
            sectionMapByRecId: sidebar.sectionMapByRecId
        )
        guard !Task.isCancelled else { return }

        metricsSummary = snapshot.summary
        explorer.recordingRows = snapshot.rows
        explorer.reconcileAfterRecordingSnapshotUpdate(
            cyclesProvider: repository.cycles(for:),
            segmentsProvider: repository.segments(for:)
        )
    }

    // MARK: - Testing Support

    /// Deterministic in-memory helper used by unit tests to project metrics & Data Explorer rows without AWS calls.
    internal func seedCacheAndProjectForTesting(
        recordings: [RecordingDTO],
        cyclesByRec: [String: [HaulCycleDTO]],
        segmentsByRec: [String: [StateSegmentDTO]] = [:],
        selectedRecordingIds: Set<String>? = nil
    ) async {
        loadCatalog()
        sidebar.replaceClusterRecordings(recordings)
        repository.seedForTesting(
            clusterId: sidebar.activeCluster?.clusterId,
            recordingIds: recordings.map(\.recordingId),
            cyclesByRec: cyclesByRec,
            segmentsByRec: segmentsByRec
        )
        sidebar.resetSidebarPagination()
        let initialSelection = selectedRecordingIds ?? Set(recordings.map(\.recordingId))
        sidebar.filterState.selectedRecordingIds = initialSelection
        sidebar.commitPendingSelection()
        await projectFromCache()
    }

    internal func reprojectCachedForTesting() async {
        await projectFromCache()
    }
}
