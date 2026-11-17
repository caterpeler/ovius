import Foundation
import SwiftData
import Testing
@testable import Ovius

struct DatabaseAndDiagnosticsTests {
    @MainActor
    @Test func inMemoryDatabaseSeedsCompleteDomainTwoAndThreeCatalog() throws {
        let db = DatabaseManager(inMemory: true)

        let settings = try db.fetchSettings()
        #expect(abs(settings.meanPayloadM3 - 51.1) < 0.001)
        #expect(settings.idleThresholdS == 300)
        #expect(settings.shiftEdgeWindowMin == 60)
        #expect(settings.shiftStartHours == ["06:00"])
        #expect(settings.breakWindows == ["12:00-13:00"])

        let clusters = try db.fetchClusters()
        #expect(clusters.count == 1)

        let sections = try db.fetchSections(clusterId: clusters[0].clusterId)
        #expect(sections.count == 3)

        let patterns = try db.fetchPatterns(activeOnly: true)
        let leads = try db.fetchLeads(activeOnly: true)
        let activeCards = try db.fetchDiagnosticCards(includeStaticAudit: false)
        let auditCard = try db.fetchStaticAuditCard()

        #expect(patterns.count == 15)
        #expect(leads.count == 9)
        #expect(activeCards.count == 9)
        #expect(auditCard?.cardId == "CARD_INCOMPLETE_CYCLE_TABLE")
    }

    @MainActor
    @Test func diagnosticResolutionPrioritizesLeadOverlapThenOrderOfAppearance() throws {
        let db = DatabaseManager(inMemory: true)
        let leads = try db.fetchLeads(activeOnly: true)
        let oversupply = try #require(leads.first { $0.leadId == "LEAD_DUMPTRUCK_OVERSUPPLY" })
        let blocking = try #require(leads.first { $0.leadId == "LEAD_BLOCKING_INCIDENT" })

        let resolved = db.resolveDashboardDiagnostics(flaggedLeads: [oversupply, blocking])
        #expect(resolved.isEmpty == false)

        // Diagnostics shared across multiple triggered leads must sort above single-lead items.
        if let first = resolved.first, let last = resolved.last, first.triggeredByLeadNames.count != last.triggeredByLeadNames.count {
            #expect(first.triggeredByLeadNames.count > last.triggeredByLeadNames.count)
        }
    }

    @MainActor
    @Test func makeFiltersOmitEmptySelectorArraysForBackendGSIRouting() throws {
        let db = DatabaseManager(inMemory: true)
        let alpha = try #require(try db.fetchSection(sectionId: "SEC_ALPHA"))
        let filters = db.makeFilters(for: alpha, startTime: "2026-11-15T00:00:00Z", endTime: "2026-11-16T00:00:00Z")

        #expect(filters.cameraIds == ["CAM-ALPHA-01", "CAM-ALPHA-02", "CAM-ALPHA-03"])
        #expect(filters.filenames == nil)
        #expect(filters.includeScoops == false)
    }

    @Test func hourlyRollupsAndShiftEdgeMetricsTrackWallClockWindows() {
        let config = TelemetryCalculationConfig(
            meanPayloadM3: 51.1,
            idleThresholdS: 300,
            shiftEdgeWindowMin: 60,
            shiftStartHours: ["06:00"],
            breakWindows: ["12:00-13:00"]
        )

        let recording = RecordingDTO(
            recordingId: "rec-edge",
            filename: "shift.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Pocket",
            durationS: 7 * 3600,
            fps: 30,
            resolution: "1920x1080",
            tags: []
        )

        // Idle during 06:00-06:30 (shift edge) + idle spanning 12:00-13:20 UTC (20m past 13:00 break end).
        let edgeIdle = StateSegmentDTO(
            segmentId: "s-edge",
            recordingId: "rec-edge",
            cycleId: "c1",
            cycleSortKey: nil,
            machineId: "EXC-01",
            scoopNumber: nil,
            state: "idle",
            startS: 0,
            endS: 1800,
            confidence: 0.95
        )
        let edgeLoad = StateSegmentDTO(
            segmentId: "s-load",
            recordingId: "rec-edge",
            cycleId: "c1",
            cycleSortKey: nil,
            machineId: "EXC-01",
            scoopNumber: nil,
            state: "loading_scoop",
            startS: 1800,
            endS: 3600,
            confidence: 0.95
        )
        let breakOverrun = StateSegmentDTO(
            segmentId: "s-break",
            recordingId: "rec-edge",
            cycleId: "c2",
            cycleSortKey: nil,
            machineId: "TRK-01",
            scoopNumber: nil,
            state: "idle",
            startS: 6 * 3600,
            endS: 7 * 3600 + 1200,
            confidence: 0.90
        )

        let snapshot = TelemetryMetricsCalculator.computeSectionSnapshot(
            sectionId: "ALPHA",
            sectionName: "Alpha",
            recordings: [recording],
            cycles: [],
            segments: [edgeIdle, edgeLoad, breakOverrun],
            config: config
        )

        #expect(abs(snapshot.value(for: .shiftEdgeIdleRatio) - 0.5) < 0.001)
        #expect(abs(snapshot.value(for: .excavatorHangRatio) - 0.5) < 0.001)
        #expect(snapshot.value(for: .breakWindowIdleExcessS) >= 1190.0)
    }

    @MainActor
    @Test func upsertSectionRejectsMissingParentClusterAndDeduplicatesLeads() throws {
        let db = DatabaseManager(inMemory: true)
        #expect(throws: DatabaseManagerError.clusterNotFound("DOES_NOT_EXIST")) {
            try db.upsertSection(sectionId: "SEC_ORPHAN", clusterId: "DOES_NOT_EXIST", name: "Orphan")
        }

        let leads = try db.fetchLeads(activeOnly: true)
        let oversupply = try #require(leads.first { $0.leadId == "LEAD_DUMPTRUCK_OVERSUPPLY" })
        // Duplicate lead inputs must not artificially inflate trigger counts.
        let resolved = db.resolveDashboardDiagnostics(flaggedLeads: [oversupply, oversupply])
        #expect(resolved.allSatisfy { $0.triggeredByLeadNames.count == 1 })
    }

    @MainActor
    @Test func filterRecordingsMirrorsBackendAndSemantics() throws {
        let db = DatabaseManager(inMemory: true)
        let alpha = try #require(try db.fetchSection(sectionId: "SEC_ALPHA"))
        let matchingRec = RecordingDTO(
            recordingId: "r1",
            filename: "clip1.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Section Alpha - Wide Overview Bench",
            durationS: 43200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Alpha"]
        )
        let mismatchLoc = RecordingDTO(
            recordingId: "r2",
            filename: "clip2.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Wrong Location",
            durationS: 43200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Alpha"]
        )

        let matched = db.filterRecordings([matchingRec, mismatchLoc], matching: alpha)
        #expect(matched.map(\.recordingId) == ["r1"])
    }

    @Test func dateRangePresetsUseExactUTCCalendarBoundsAndDefaultToOneMonth() throws {
        let anchor = try #require(OviusFormat.parseISODate("2026-11-16T06:00:00Z"))
        let priorShift = try #require(OviusFormat.parseISODate("2026-11-15T06:00:00Z"))

        let defaultFilter = DashboardFilterState(referenceDate: anchor)
        #expect(defaultFilter.datePreset == .last1Month)
        #expect(defaultFilter.timePreset == .fullShift)

        let oneDayBounds = DateRangePreset.latestDay.bounds(endingAt: anchor)
        #expect(anchor >= oneDayBounds.start && anchor <= oneDayBounds.end)
        #expect((priorShift >= oneDayBounds.start && priorShift <= oneDayBounds.end) == false)

        let oneMonthBounds = DateRangePreset.last1Month.bounds(endingAt: anchor)
        let thirtyDaysAgo = try #require(OviusFormat.parseISODate("2026-10-18T06:00:00Z"))
        let thirtyOneDaysAgo = try #require(OviusFormat.parseISODate("2026-10-17T06:00:00Z"))
        #expect(thirtyDaysAgo >= oneMonthBounds.start && thirtyDaysAgo <= oneMonthBounds.end)
        #expect((thirtyOneDaysAgo >= oneMonthBounds.start && thirtyOneDaysAgo <= oneMonthBounds.end) == false)
    }

    @MainActor
    @Test func leadHighlightDoesNotMutateFilteredDataScope() {
        let vm = DashboardViewModel(databaseManager: DatabaseManager(inMemory: true), networkManager: .shared)
        vm.loadCatalogAndConfig()

        #expect(vm.activeCluster?.clusterId == "CLUSTER_OPEN_PIT_MAIN")
        #expect(vm.filterState.datePreset == .last1Month)

        vm.toggleHighlightedLead("SEC_ALPHA|LEAD_LATE_BREAK_RETURN")
        #expect(vm.filterState.highlightedLeadEntryId == "SEC_ALPHA|LEAD_LATE_BREAK_RETURN")
        #expect(vm.filteredRecordings.isEmpty)

        vm.toggleHighlightedLead("SEC_ALPHA|LEAD_LATE_BREAK_RETURN")
        #expect(vm.filterState.highlightedLeadEntryId == nil)
    }

    @MainActor
    @Test func toolbarAndTableSortOrderStayBidirectionallySynchronized() {
        let vm = DashboardViewModel(databaseManager: DatabaseManager(inMemory: true), networkManager: .shared)

        vm.recordingSortField = .volumeDesc
        vm.recordingSortAscending = true
        vm.applyToolbarRecordingSort()
        #expect(vm.recordingSortOrder.first?.keyPath == \RecordingExplorerRow.totalVolumeM3)
        #expect(vm.recordingSortOrder.first?.order == .forward)

        let tableSort: [KeyPathComparator<RecordingExplorerRow>] = [.init(\.avgQueueTimeS, order: .reverse)]
        vm.recordingSortOrder = tableSort
        vm.syncToolbarSortFromTable(tableSort)
        #expect(vm.recordingSortField == .queueDesc)
        #expect(vm.recordingSortAscending == false)
    }

    @Test func shiftTimePresetsAdaptDynamicallyToCustomShiftSettings() {
        let customConfig = TelemetryCalculationConfig(
            shiftEdgeWindowMin: 45,
            shiftStartHours: ["07:00"],
            breakWindows: ["12:30-13:30"]
        )

        #expect(ShiftTimePreset.startupEdge.clockLabel(using: customConfig) == "07:00–07:45")
        #expect(ShiftTimePreset.middayBreak.clockLabel(using: customConfig) == "12:30–13:30")
        #expect(ShiftTimePreset.closingEdge.clockLabel(using: customConfig) == "18:15–19:00")
    }

    @MainActor
    @Test func changingRecordsThatAlterLeadsDefersDiagnosticRefreshUntilManualReload() async throws {
        let vm = DashboardViewModel(databaseManager: DatabaseManager(inMemory: true), networkManager: .shared)
        let anchor = try #require(OviusFormat.parseISODate("2026-11-16T06:00:00Z"))

        let recAlpha = RecordingDTO(
            recordingId: "rec-a",
            filename: "alpha.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Section Alpha - Wide Overview Bench",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Alpha"]
        )
        let recBeta = RecordingDTO(
            recordingId: "rec-b",
            filename: "beta.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-BETA-01",
            locationTag: "Section Beta - Highwall Haul Ramp Pocket",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Beta"]
        )

        let recGamma = RecordingDTO(
            recordingId: "rec-g",
            filename: "gamma.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-GAMMA-01",
            locationTag: "Section Gamma - Dual-Truck Loading Pocket",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Gamma"]
        )

        // Alpha & Gamma nominal (load=100s, spot=20s, depart=20s, queue=10s); Beta high queue (160s) -> triggers Beta Dumptruck Oversupply.
        let cA = HaulCycleDTO(recordingId: "rec-a", cycleId: "ca1", excavatorId: "EXC-A", excavatorSortKey: nil, truckLabel: "T1", cycleStatus: "complete", tArriveS: 100, tSpotS: 110, tLoadStartS: 130, tLoadEndS: 230, tDepartS: 250, queueTimeS: 10, scoops: nil, truckSegments: nil)
        let cG = HaulCycleDTO(recordingId: "rec-g", cycleId: "cg1", excavatorId: "EXC-G", excavatorSortKey: nil, truckLabel: "T4", cycleStatus: "complete", tArriveS: 100, tSpotS: 110, tLoadStartS: 130, tLoadEndS: 230, tDepartS: 250, queueTimeS: 10, scoops: nil, truckSegments: nil)
        let cB1 = HaulCycleDTO(recordingId: "rec-b", cycleId: "cb1", excavatorId: "EXC-B", excavatorSortKey: nil, truckLabel: "T2", cycleStatus: "complete", tArriveS: 100, tSpotS: 260, tLoadStartS: 280, tLoadEndS: 380, tDepartS: 400, queueTimeS: 160, scoops: nil, truckSegments: nil)

        await vm.seedCacheAndEvaluateForTesting(
            recordings: [recAlpha, recBeta, recGamma],
            cyclesByRec: ["rec-a": [cA], "rec-g": [cG], "rec-b": [cB1]],
            segmentsByRec: ["rec-a": [], "rec-g": [], "rec-b": []],
            referenceDate: anchor,
            commitImmediately: true
        )

        let initialLeads = vm.topLeads.map(\.id)
        let initialDiagnostics = vm.activeDiagnostics.map(\.diagnosticId)
        #expect(initialLeads.isEmpty == false)
        #expect(vm.hasPendingLeadsUpdate == false)

        // Filter exclusively to Section Alpha (where no leads trigger -> identified leads change).
        vm.filterState.selectedSectionIds = ["SEC_ALPHA"]
        await vm.reevaluateCachedForTesting(commitImmediately: false)

        // Previous leads and diagnostics must remain frozen until reload button is pressed; Data Explorer updates immediately.
        #expect(vm.hasPendingLeadsUpdate == true)
        #expect(vm.topLeads.map(\.id) == initialLeads)
        #expect(vm.activeDiagnostics.map(\.diagnosticId) == initialDiagnostics)
        #expect(vm.recordingRows.map(\.recordingId) == ["rec-a"])

        // Reverting filter back before pressing Reload clears pending banner automatically.
        vm.filterState.selectedSectionIds = []
        await vm.reevaluateCachedForTesting(commitImmediately: false)
        #expect(vm.hasPendingLeadsUpdate == false)

        // Narrow again to Section Alpha, then press manual reload -> leads and diagnostics update.
        vm.filterState.selectedSectionIds = ["SEC_ALPHA"]
        await vm.reevaluateCachedForTesting(commitImmediately: false)
        #expect(vm.hasPendingLeadsUpdate == true)
        vm.applyPendingLeadsAndDiagnostics()

        #expect(vm.hasPendingLeadsUpdate == false)
        #expect(vm.topLeads.isEmpty)
        #expect(vm.activeDiagnostics.isEmpty)
    }
}
