import Foundation
import Observation

/// Manages the left recordings sidebar: cluster catalog, section/camera chips, UTC date range,
/// search query, 25-entry pagination, and deferred recording selection.
@MainActor
@Observable
public final class DashboardSidebarViewModel {
    public static let pageSize: Int = 25

    private let databaseManager: DatabaseManager
    private let referenceDate: Date

    public var clusters: [Cluster] = []
    public var filterState: DashboardFilterState
    public var sidebarSearchText: String = ""
    public private(set) var visibleLimit: Int = pageSize

    public var clusterRecordings: [RecordingDTO] = []
    public private(set) var scopeRecordings: [RecordingDTO] = []
    public private(set) var sidebarRecordings: [RecordingDTO] = []
    public private(set) var displayedSidebarRecordings: [RecordingDTO] = []
    public internal(set) var appliedRecordingIds: Set<String> = []
    public private(set) var sectionMapByRecId: [String: (sectionId: String, sectionName: String)] = [:]

    private var sectionRecordingIdsBySectionId: [String: Set<String>] = [:]
    private var expectedPresetStart: Date
    private var expectedPresetEnd: Date

    public init(
        databaseManager: DatabaseManager? = nil,
        referenceDate: Date = .now
    ) {
        self.databaseManager = databaseManager ?? .shared
        self.referenceDate = referenceDate
        let initialFilters = DashboardFilterState(datePreset: .lastMonth, referenceDate: referenceDate)
        self.filterState = initialFilters
        self.expectedPresetStart = initialFilters.startDate
        self.expectedPresetEnd = initialFilters.endDate
    }

    // MARK: - Derived Scope Properties

    public var hasPendingSelectionChanges: Bool {
        filterState.selectedRecordingIds != appliedRecordingIds
    }

    public var hasMoreSidebarRecordings: Bool {
        sidebarRecordings.count > displayedSidebarRecordings.count
    }

    public var remainingSidebarRecordingCount: Int {
        max(0, sidebarRecordings.count - displayedSidebarRecordings.count)
    }

    public var allSidebarRecordingsSelected: Bool {
        !sidebarRecordings.isEmpty
            && sidebarRecordings.allSatisfy { filterState.selectedRecordingIds.contains($0.recordingId) }
    }

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

    public var activeSectionsScope: [Section] {
        let all = sectionsInActiveCluster
        if filterState.selectedSectionIds.isEmpty {
            return all
        }
        return all.filter { filterState.selectedSectionIds.contains($0.sectionId) }
    }

    public var camerasInScope: [String] {
        Array(Set(activeSectionsScope.flatMap(\.cameraIds))).sorted()
    }

    // MARK: - Catalog & Cluster Transitions

    @discardableResult
    public func loadCatalog() -> String? {
        do {
            clusters = try databaseManager.fetchClusters()
            if filterState.clusterId == nil {
                filterState.clusterId = clusters.first(where: { $0.clusterId == DatabaseManager.defaultMainClusterId })?.clusterId
                    ?? clusters.first?.clusterId
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func defaultInitialCluster() -> Cluster? {
        clusters.first(where: { $0.clusterId == DatabaseManager.defaultMainClusterId }) ?? clusters.first
    }

    public func makeClusterDiscoveryFilters(for cluster: Cluster) -> TelemetryQueryFilters {
        databaseManager.makeFilters(
            for: cluster,
            startTime: "2020-01-01T00:00:00Z",
            endTime: OviusFormat.isoString(from: Date.now.addingTimeInterval(86_400)),
            limit: 2_000
        )
    }

    public func prepareClusterSwitch(_ clusterId: String) {
        clusterRecordings = []
        appliedRecordingIds = []
        filterState.clusterId = clusterId
        filterState.selectedSectionIds = []
        filterState.selectedCameraIds = []
        filterState.selectedRecordingIds = []
        visibleLimit = Self.pageSize
        rebuildSectionMapAndSidebar()
    }

    public func clearRecordings() {
        clusterRecordings = []
        scopeRecordings = []
        sidebarRecordings = []
        displayedSidebarRecordings = []
        appliedRecordingIds = []
    }

    public func replaceClusterRecordings(_ recordings: [RecordingDTO]) {
        clusterRecordings = recordings.sorted { $0.timestamp > $1.timestamp }
        rebuildSectionMapAndSidebar()
    }

    public func reconcileSelectionAfterClusterLoad() {
        let clusterIds = Set(clusterRecordings.map(\.recordingId))
        let survivingApplied = appliedRecordingIds.intersection(clusterIds)
        let survivingSelected = filterState.selectedRecordingIds.intersection(clusterIds)

        if !survivingApplied.isEmpty {
            appliedRecordingIds = survivingApplied
            filterState.selectedRecordingIds = survivingSelected.isEmpty ? survivingApplied : survivingSelected
        } else if let newest = scopeRecordings.first ?? clusterRecordings.first {
            appliedRecordingIds = [newest.recordingId]
            filterState.selectedRecordingIds = survivingSelected.isEmpty ? [newest.recordingId] : survivingSelected
        } else {
            appliedRecordingIds = []
            filterState.selectedRecordingIds = []
        }
    }

    public func commitPendingSelection() {
        appliedRecordingIds = filterState.selectedRecordingIds
    }

    public func resolveAppliedRecordings() -> [RecordingDTO] {
        guard !appliedRecordingIds.isEmpty else { return [] }
        return clusterRecordings.filter { appliedRecordingIds.contains($0.recordingId) }
    }

    public func recordingsDictionary() -> [String: RecordingDTO] {
        Dictionary(uniqueKeysWithValues: clusterRecordings.map { ($0.recordingId, $0) })
    }

    // MARK: - Pagination & Search

    public func loadMoreSidebarRecordings() {
        visibleLimit += Self.pageSize
        displayedSidebarRecordings = Array(sidebarRecordings.prefix(visibleLimit))
    }

    public func resetSidebarPagination() {
        visibleLimit = Self.pageSize
        displayedSidebarRecordings = Array(sidebarRecordings.prefix(visibleLimit))
    }

    public func rebuildSidebarForSearchChange() {
        visibleLimit = Self.pageSize
        rebuildSidebarSearchAndPagination()
    }

    // MARK: - Filter Mutators (Filter Sidebar List Only)

    /// Toggles a Section chip — filters the left sidebar list ONLY without altering `selectedRecordingIds`.
    public func toggleSectionFilter(_ sectionId: String) {
        if filterState.selectedSectionIds.contains(sectionId) {
            filterState.selectedSectionIds.remove(sectionId)
        } else {
            filterState.selectedSectionIds.insert(sectionId)
        }
        let validCams = Set(activeSectionsScope.flatMap(\.cameraIds))
        filterState.selectedCameraIds = filterState.selectedCameraIds.intersection(validCams)
        applyScopeChangeToSidebarFilterOnly()
    }

    /// Toggles a Camera chip — filters the left sidebar list ONLY without altering `selectedRecordingIds`.
    public func toggleCameraFilter(_ cameraId: String) {
        if filterState.selectedCameraIds.contains(cameraId) {
            filterState.selectedCameraIds.remove(cameraId)
        } else {
            filterState.selectedCameraIds.insert(cameraId)
        }
        applyScopeChangeToSidebarFilterOnly()
    }

    /// Clears active Section and Camera chips — resets sidebar filtering ONLY without altering `selectedRecordingIds`.
    public func clearScopeSelection() {
        filterState.selectedSectionIds = []
        filterState.selectedCameraIds = []
        applyScopeChangeToSidebarFilterOnly()
    }

    /// Clears only Section filters without altering `selectedRecordingIds`.
    public func clearSectionFilters() {
        guard !filterState.selectedSectionIds.isEmpty else { return }
        filterState.selectedSectionIds = []
        applyScopeChangeToSidebarFilterOnly()
    }

    /// Clears only Camera filters without altering `selectedRecordingIds`.
    public func clearCameraFilters() {
        guard !filterState.selectedCameraIds.isEmpty else { return }
        filterState.selectedCameraIds = []
        applyScopeChangeToSidebarFilterOnly()
    }

    /// Applies a Date Range preset (`7 Days`, `Last Month`, `3 Months`, `All`) to sidebar filtering ONLY.
    public func selectDatePreset(_ preset: DateRangePreset) {
        let earliestDate = clusterRecordings.last?.startDate
        filterState.applyDatePreset(
            preset,
            referenceDate: referenceDate,
            earliestAvailableDate: earliestDate
        )
        expectedPresetStart = filterState.startDate
        expectedPresetEnd = filterState.endDate
        applyScopeChangeToSidebarFilterOnly()
    }

    /// Resets the sidebar Date Range back to the default `Last Month` window.
    public func resetDateRangeToDefault() {
        selectDatePreset(.lastMonth)
    }

    /// Handles manual edits to the sidebar `From` date picker, switching to `.custom` and filtering the sidebar list ONLY.
    public func onCustomStartDateEdited() {
        if filterState.startDate == expectedPresetStart && filterState.endDate == expectedPresetEnd {
            return
        }
        let normalizedStart = DashboardFilterState.utcStartOfDay(for: filterState.startDate)
        filterState.startDate = normalizedStart
        if filterState.endDate < normalizedStart {
            filterState.endDate = normalizedStart
        }
        filterState.datePreset = .custom
        expectedPresetStart = filterState.startDate
        expectedPresetEnd = filterState.endDate
        applyScopeChangeToSidebarFilterOnly()
    }

    /// Handles manual edits to the sidebar `To` date picker, switching to `.custom` and filtering the sidebar list ONLY.
    public func onCustomEndDateEdited() {
        if filterState.startDate == expectedPresetStart && filterState.endDate == expectedPresetEnd {
            return
        }
        let normalizedEnd = DashboardFilterState.utcStartOfDay(for: filterState.endDate)
        filterState.endDate = normalizedEnd
        if filterState.startDate > normalizedEnd {
            filterState.startDate = normalizedEnd
        }
        filterState.datePreset = .custom
        expectedPresetStart = filterState.startDate
        expectedPresetEnd = filterState.endDate
        applyScopeChangeToSidebarFilterOnly()
    }

    /// Selects every recording matching the active Section, Camera, Date Range, and Search filters in the sidebar.
    public func selectAllSidebarRecordings() {
        updateSelectedRecordings(Set(sidebarRecordings.map(\.recordingId)))
    }

    /// Updates the left sidebar highlight/selection ONLY — defers content panel reload until refresh is clicked.
    public func updateSelectedRecordings(_ ids: Set<String>) {
        guard filterState.selectedRecordingIds != ids else { return }
        filterState.selectedRecordingIds = ids
    }

    // MARK: - Private Rebuild Helpers

    private func applyScopeChangeToSidebarFilterOnly() {
        visibleLimit = Self.pageSize
        rebuildScopeAndSidebar()
    }

    private func rebuildSectionMapAndSidebar() {
        var secMap: [String: (sectionId: String, sectionName: String)] = [:]
        var secRecIds: [String: Set<String>] = [:]
        for section in sectionsInActiveCluster {
            let matched = databaseManager.filterRecordings(clusterRecordings, matching: section)
            secRecIds[section.sectionId] = Set(matched.map(\.recordingId))
            for rec in matched {
                secMap[rec.recordingId] = (section.sectionId, section.name)
            }
        }
        sectionMapByRecId = secMap
        sectionRecordingIdsBySectionId = secRecIds
        rebuildScopeAndSidebar()
    }

    private func rebuildScopeAndSidebar() {
        let allowedSections = activeSectionsScope
        var sectionMatchedIds: Set<String> = []
        for section in allowedSections {
            if let ids = sectionRecordingIdsBySectionId[section.sectionId] {
                sectionMatchedIds.formUnion(ids)
            }
        }
        let dateBounds = filterState.utcDateBounds()
        scopeRecordings = clusterRecordings.filter { rec in
            guard sectionMatchedIds.contains(rec.recordingId) else { return false }
            if !filterState.selectedCameraIds.isEmpty && !filterState.selectedCameraIds.contains(rec.cameraId) {
                return false
            }
            if let dateBounds, let recDate = rec.startDate {
                guard recDate >= dateBounds.lower && recDate < dateBounds.upper else { return false }
            }
            return true
        }
        rebuildSidebarSearchAndPagination()
    }

    private func rebuildSidebarSearchAndPagination() {
        let q = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            sidebarRecordings = scopeRecordings
        } else {
            sidebarRecordings = scopeRecordings.filter { rec in
                rec.cameraId.localizedCaseInsensitiveContains(q)
                    || rec.filename.localizedCaseInsensitiveContains(q)
                    || rec.locationTag.localizedCaseInsensitiveContains(q)
                    || rec.recordingId.localizedCaseInsensitiveContains(q)
            }
        }
        displayedSidebarRecordings = Array(sidebarRecordings.prefix(visibleLimit))
    }
}
