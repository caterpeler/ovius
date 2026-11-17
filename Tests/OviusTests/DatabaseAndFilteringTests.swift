import Foundation
import SwiftData
import Testing
@testable import Ovius

struct DatabaseAndFilteringTests {
    @MainActor
    @Test func inMemoryDatabaseSeedsDomainTwoAndPersistsCustomCluster() throws {
        let db = DatabaseManager(inMemory: true)

        let clusters = try db.fetchClusters()
        #expect(clusters.count == 4)
        #expect(clusters.map(\.name) == ["Open-Pit Site", "Cluster A", "Cluster B", "Cluster C"])

        let mainCluster = try #require(clusters.first { $0.clusterId == DatabaseManager.defaultMainClusterId })
        let mainSections = try db.fetchSections(clusterId: mainCluster.clusterId)
        #expect(mainSections.count == 3)

        let clusterA = try #require(clusters.first { $0.clusterId == "CLUSTER_A" })
        let clusterASections = try db.fetchSections(clusterId: clusterA.clusterId)
        #expect(clusterASections.count == 1)
        #expect(clusterASections[0].name == "Section Alpha")
        #expect(clusterASections[0].cameraIds == ["CAM-ALPHA-01", "CAM-ALPHA-02", "CAM-ALPHA-03"])

        let clusterB = try #require(clusters.first { $0.clusterId == "CLUSTER_B" })
        let clusterBSections = try db.fetchSections(clusterId: clusterB.clusterId)
        #expect(clusterBSections.count == 1)
        #expect(clusterBSections[0].name == "Section Beta")
        #expect(clusterBSections[0].cameraIds == ["CAM-BETA-01", "CAM-BETA-02", "CAM-BETA-03", "CAM-BETA-04", "CAM-BETA-05"])

        let clusterC = try #require(clusters.first { $0.clusterId == "CLUSTER_C" })
        let clusterCSections = try db.fetchSections(clusterId: clusterC.clusterId)
        #expect(clusterCSections.count == 1)
        #expect(clusterCSections[0].name == "Section Gamma")
        #expect(clusterCSections[0].cameraIds == ["CAM-GAMMA-01", "CAM-GAMMA-02", "CAM-GAMMA-03"])

        let alphaClip = RecordingDTO(
            recordingId: "r-alpha",
            filename: "alpha.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Section Alpha - Wide Overview Bench",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Alpha"]
        )
        let betaClip = RecordingDTO(
            recordingId: "r-beta",
            filename: "beta.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-BETA-01",
            locationTag: "Section Beta - Highwall Haul Ramp Pocket",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Beta"]
        )
        let gammaClip = RecordingDTO(
            recordingId: "r-gamma",
            filename: "gamma.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-GAMMA-01",
            locationTag: "Section Gamma - Dual-Truck Loading Pocket",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Gamma"]
        )
        #expect(db.filterRecordings([alphaClip, betaClip, gammaClip], matching: clusterASections[0]).map(\.recordingId) == ["r-alpha"])
        #expect(db.filterRecordings([alphaClip, betaClip, gammaClip], matching: clusterBSections[0]).map(\.recordingId) == ["r-beta"])
        #expect(db.filterRecordings([alphaClip, betaClip, gammaClip], matching: clusterCSections[0]).map(\.recordingId) == ["r-gamma"])

        // Persistent store smoke check: verify Domain 2 persists across reopen without fallback errors.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ovius-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("ovius_test.store")

        let persistentDb1 = DatabaseManager(inMemory: false, storeURL: storeURL)
        #expect(persistentDb1.lastError == nil)
        try persistentDb1.upsertCluster(clusterId: "CLUSTER_PERSIST", name: "Persistent Pit", tags: ["site:test"])

        // Simulate a legacy store containing only Open-Pit Site and verify Cluster A/B/C backfill cleanly on reopen.
        for extra in try persistentDb1.fetchClusters() where ["CLUSTER_A", "CLUSTER_B", "CLUSTER_C"].contains(extra.clusterId) {
            try persistentDb1.deleteCluster(extra)
        }
        #expect(try persistentDb1.fetchClusters().count == 2)

        let persistentDb2 = DatabaseManager(inMemory: false, storeURL: storeURL)
        #expect(persistentDb2.lastError == nil)
        let reopened = try persistentDb2.fetchCluster(clusterId: "CLUSTER_PERSIST")
        #expect(reopened?.name == "Persistent Pit")
        #expect(try persistentDb2.fetchCluster(clusterId: "CLUSTER_A") != nil)
        #expect(try persistentDb2.fetchCluster(clusterId: "CLUSTER_B") != nil)
        #expect(try persistentDb2.fetchCluster(clusterId: "CLUSTER_C") != nil)

        // Incompatible/unopenable prior store file recovers cleanly to persistent storage with backup.
        let corruptURL = tempDir.appendingPathComponent("legacy_incompatible.store")
        try Data("not-a-sqlite-store".utf8).write(to: corruptURL)
        let recoveredDb = DatabaseManager(inMemory: false, storeURL: corruptURL)
        #expect(recoveredDb.lastError == nil)
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        #expect(dirContents.contains { $0.hasPrefix("legacy_incompatible.store.legacy-") })
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

    @MainActor
    @Test func upsertSectionRejectsMissingParentCluster() throws {
        let db = DatabaseManager(inMemory: true)
        #expect(throws: DatabaseManagerError.clusterNotFound("DOES_NOT_EXIST")) {
            try db.upsertSection(sectionId: "SEC_ORPHAN", clusterId: "DOES_NOT_EXIST", name: "Orphan")
        }
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

    @MainActor
    @Test func settingsViewModelValidatesAndPersistsEndpointConfiguration() async throws {
        let isolatedNetwork = NetworkManager()
        let vm = SettingsViewModel(networkManager: isolatedNetwork)
        await vm.load()

        vm.primaryBaseURLText = "not-a-valid-url"
        await vm.saveSettings()
        #expect(vm.errorMessage != nil)

        vm.primaryBaseURLText = "https://example.com/api/v1"
        vm.fallbackBaseURLText = ""
        vm.apiKeyText = "secret-key"
        vm.requestTimeoutSeconds = 45
        await vm.saveSettings()

        #expect(vm.errorMessage == nil)
        let saved = await isolatedNetwork.currentConfiguration()
        #expect(saved.primaryBaseURL.absoluteString == "https://example.com/api/v1")
        #expect(saved.fallbackBaseURL == nil)
        #expect(saved.apiKey == "secret-key")
        #expect(saved.requestTimeoutSeconds == 45)
    }

    @MainActor
    @Test func toolbarAndTableSortOrderStayBidirectionallySynchronized() {
        let vm = DashboardViewModel(
            databaseManager: DatabaseManager(inMemory: true),
            networkManager: .shared,
            diskCache: TelemetryDiskCache(isEnabled: false)
        )

        vm.explorer.recordingSortField = .passesDesc
        vm.explorer.recordingSortAscending = true
        vm.explorer.applyToolbarRecordingSort()
        #expect(vm.explorer.recordingSortOrder.first?.keyPath == \RecordingExplorerRow.avgPassesPerCycle)
        #expect(vm.explorer.recordingSortOrder.first?.order == .forward)

        let tableSort: [KeyPathComparator<RecordingExplorerRow>] = [.init(\.avgQueueTimeS, order: .reverse)]
        vm.explorer.recordingSortOrder = tableSort
        vm.explorer.syncToolbarSortFromTable(tableSort)
        #expect(vm.explorer.recordingSortField == .queueDesc)
        #expect(vm.explorer.recordingSortAscending == false)
    }

    @MainActor
    @Test func selectingSectionFiltersListOnlyAndSelectAllDefersRefreshUntilTriggered() async {
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-11-17T12:00:00Z")!
        let vm = DashboardViewModel(
            databaseManager: DatabaseManager(inMemory: true),
            networkManager: .shared,
            diskCache: TelemetryDiskCache(isEnabled: false),
            referenceDate: referenceDate
        )

        let recAlpha1 = RecordingDTO(
            recordingId: "rec-a1",
            filename: "alpha1.mp4",
            timestamp: "2026-11-16T06:00:00Z",
            cameraId: "CAM-ALPHA-01",
            locationTag: "Section Alpha - Wide Overview Bench",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Alpha"]
        )
        let recAlpha2 = RecordingDTO(
            recordingId: "rec-a2",
            filename: "alpha2.mp4",
            timestamp: "2026-11-16T07:00:00Z",
            cameraId: "CAM-ALPHA-02",
            locationTag: "Section Alpha - Pit Lake Lower Bench",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Alpha"]
        )
        let recBeta = RecordingDTO(
            recordingId: "rec-b1",
            filename: "beta1.mp4",
            timestamp: "2026-11-16T08:00:00Z",
            cameraId: "CAM-BETA-01",
            locationTag: "Section Beta - Highwall Haul Ramp Pocket",
            durationS: 43_200,
            fps: 25,
            resolution: "1920x1080",
            tags: ["section:Beta"]
        )

        let cA1 = HaulCycleDTO(
            recordingId: "rec-a1",
            cycleId: "ca1",
            excavatorId: "E1",
            excavatorSortKey: nil,
            truckLabel: "T1",
            cycleStatus: "complete",
            tArriveS: 100,
            tSpotS: 120,
            tLoadStartS: 140,
            tLoadEndS: 240,
            tDepartS: 260,
            queueTimeS: 20,
            scoops: [
                ScoopTimingDTO(scoopNumber: 1, excavatorSegmentId: "sa-l", startS: 140, dumpS: 160, endS: 190),
                ScoopTimingDTO(scoopNumber: 2, excavatorSegmentId: "sa-l", startS: 195, dumpS: 220, endS: 240),
            ],
            truckSegments: nil
        )
        let cA2 = HaulCycleDTO(
            recordingId: "rec-a2",
            cycleId: "ca2",
            excavatorId: "E1",
            excavatorSortKey: nil,
            truckLabel: "T1",
            cycleStatus: "complete",
            tArriveS: 100,
            tSpotS: 120,
            tLoadStartS: 140,
            tLoadEndS: 280,
            tDepartS: 300,
            queueTimeS: 20,
            scoops: (1...4).map { idx in
                ScoopTimingDTO(scoopNumber: idx, excavatorSegmentId: "sa2-l", startS: 140, dumpS: 160, endS: 180)
            },
            truckSegments: nil
        )
        let cB1 = HaulCycleDTO(
            recordingId: "rec-b1",
            cycleId: "cb1",
            excavatorId: "E2",
            excavatorSortKey: nil,
            truckLabel: "T2",
            cycleStatus: "complete",
            tArriveS: 100,
            tSpotS: 140,
            tLoadStartS: 160,
            tLoadEndS: 280,
            tDepartS: 300,
            queueTimeS: 40,
            scoops: (1...3).map { idx in
                ScoopTimingDTO(scoopNumber: idx, excavatorSegmentId: "sb-l", startS: 160, dumpS: 180, endS: 200)
            },
            truckSegments: nil
        )

        let segsAlpha1 = [
            StateSegmentDTO(segmentId: "sa1-l", recordingId: "rec-a1", cycleId: "ca1", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "loading_scoop", startS: 140, endS: 240, confidence: 0.95),
            StateSegmentDTO(segmentId: "sa1-i", recordingId: "rec-a1", cycleId: "NONE", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "idle", startS: 240, endS: 340, confidence: 0.95),
            StateSegmentDTO(segmentId: "ta1-q", recordingId: "rec-a1", cycleId: "ca1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "queuing_idle", startS: 100, endS: 120, confidence: 0.95),
            StateSegmentDTO(segmentId: "ta1-b", recordingId: "rec-a1", cycleId: "ca1", cycleSortKey: nil, machineId: "T1", scoopNumber: nil, state: "being_loaded", startS: 140, endS: 240, confidence: 0.95),
        ]
        let segsAlpha2 = [
            StateSegmentDTO(segmentId: "sa2-l", recordingId: "rec-a2", cycleId: "ca2", cycleSortKey: nil, machineId: "E1", scoopNumber: nil, state: "loading_scoop", startS: 140, endS: 280, confidence: 0.95),
        ]
        let segsBeta = [
            StateSegmentDTO(segmentId: "sb-l", recordingId: "rec-b1", cycleId: "cb1", cycleSortKey: nil, machineId: "E2", scoopNumber: nil, state: "loading_scoop", startS: 160, endS: 280, confidence: 0.95),
        ]

        await vm.seedCacheAndProjectForTesting(
            recordings: [recAlpha1, recAlpha2, recBeta],
            cyclesByRec: ["rec-a1": [cA1], "rec-a2": [cA2], "rec-b1": [cB1]],
            segmentsByRec: ["rec-a1": segsAlpha1, "rec-a2": segsAlpha2, "rec-b1": segsBeta],
            selectedRecordingIds: ["rec-a1"]
        )

        #expect(vm.sidebar.appliedRecordingIds == ["rec-a1"])
        #expect(vm.sidebar.hasPendingSelectionChanges == false)
        #expect(vm.explorer.recordingRows.map(\.recordingId) == ["rec-a1"])
        #expect(vm.metricsSummary.completeCycleCount == 1)

        // Filtering to Section Alpha must filter the sidebar list ONLY without altering `selectedRecordingIds`.
        vm.sidebar.toggleSectionFilter("SEC_ALPHA")
        #expect(Set(vm.sidebar.sidebarRecordings.map(\.recordingId)) == ["rec-a1", "rec-a2"])
        #expect(vm.sidebar.filterState.selectedRecordingIds == ["rec-a1"])
        #expect(vm.sidebar.hasPendingSelectionChanges == false)
        #expect(vm.sidebar.allSidebarRecordingsSelected == false)

        // Clicking Select All highlights every recording in the filtered Section while deferring refresh.
        vm.sidebar.selectAllSidebarRecordings()
        #expect(vm.sidebar.filterState.selectedRecordingIds == ["rec-a1", "rec-a2"])
        #expect(vm.sidebar.allSidebarRecordingsSelected == true)
        #expect(vm.sidebar.hasPendingSelectionChanges == true)
        #expect(vm.explorer.recordingRows.map(\.recordingId) == ["rec-a1"])
        #expect(vm.metricsSummary.completeCycleCount == 1)

        // Manually trigger refresh -> content panel updates to both Alpha clips.
        await vm.applyPendingSelectionAndRefresh()
        #expect(vm.sidebar.hasPendingSelectionChanges == false)
        #expect(vm.sidebar.appliedRecordingIds == ["rec-a1", "rec-a2"])
        #expect(Set(vm.explorer.recordingRows.map(\.recordingId)) == ["rec-a1", "rec-a2"])
        #expect(vm.metricsSummary.completeCycleCount == 2)
        #expect(abs(vm.metricsSummary.meanCyclesPerRecording - 1.0) < 0.001)
        #expect(abs(vm.metricsSummary.meanPassesPerCycle - 3.0) < 0.001)
        #expect(abs(vm.metricsSummary.meanCycleTimeS - 180.0) < 0.001)
        #expect(abs(vm.metricsSummary.excavatorMeanIdleS - 100.0) < 0.001)
        #expect(abs(vm.metricsSummary.truckMeanIdleS - 20.0) < 0.001)

        // Selecting a single recording directly via Mail sidebar List also defers refresh until applied.
        vm.sidebar.updateSelectedRecordings(["rec-b1"])
        #expect(vm.sidebar.hasPendingSelectionChanges == true)
        #expect(Set(vm.explorer.recordingRows.map(\.recordingId)) == ["rec-a1", "rec-a2"])

        await vm.applyPendingSelectionAndRefresh()
        #expect(vm.sidebar.hasPendingSelectionChanges == false)
        #expect(vm.explorer.recordingRows.map(\.recordingId) == ["rec-b1"])
        #expect(vm.metricsSummary.completeCycleCount == 1)
        #expect(abs(vm.metricsSummary.meanPassesPerCycle - 3.0) < 0.001)
    }

    @MainActor
    @Test func sidebarPaginatesRecordingsInBatchesOfTwentyFiveWithLoadMoreAndSelectAll() async {
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-10-15T12:00:00Z")!
        let vm = DashboardViewModel(
            databaseManager: DatabaseManager(inMemory: true),
            networkManager: .shared,
            diskCache: TelemetryDiskCache(isEnabled: false),
            referenceDate: referenceDate
        )

        let baseDate = formatter.date(from: "2026-10-01T06:00:00Z")!

        // 60 Alpha clips -> 25 + 25 + 10 pages cleanly.
        let alphaClips: [RecordingDTO] = (0..<60).map { idx in
            let ts = formatter.string(from: baseDate.addingTimeInterval(Double(idx) * 3600.0))
            return RecordingDTO(
                recordingId: String(format: "rec-a-%02d", idx),
                filename: String(format: "alpha_%02d.mp4", idx),
                timestamp: ts,
                cameraId: "CAM-ALPHA-01",
                locationTag: "Section Alpha - Wide Overview Bench",
                durationS: 3600,
                fps: 25,
                resolution: "1920x1080",
                tags: ["section:Alpha"]
            )
        }

        await vm.seedCacheAndProjectForTesting(
            recordings: alphaClips,
            cyclesByRec: [:],
            segmentsByRec: [:],
            selectedRecordingIds: ["rec-a-59"]
        )

        #expect(vm.sidebar.sidebarRecordings.count == 60)
        #expect(vm.sidebar.displayedSidebarRecordings.count == 25)
        #expect(vm.sidebar.hasMoreSidebarRecordings == true)
        #expect(vm.sidebar.remainingSidebarRecordingCount == 35)
        #expect(vm.sidebar.displayedSidebarRecordings.first?.recordingId == "rec-a-59")

        vm.sidebar.loadMoreSidebarRecordings()
        #expect(vm.sidebar.displayedSidebarRecordings.count == 50)
        #expect(vm.sidebar.hasMoreSidebarRecordings == true)
        #expect(vm.sidebar.remainingSidebarRecordingCount == 10)

        vm.sidebar.loadMoreSidebarRecordings()
        #expect(vm.sidebar.displayedSidebarRecordings.count == 60)
        #expect(vm.sidebar.hasMoreSidebarRecordings == false)
        #expect(vm.sidebar.remainingSidebarRecordingCount == 0)

        // Filtering to a section resets sidebar pagination back to 25 WITHOUT changing selection yet.
        vm.sidebar.toggleSectionFilter("SEC_ALPHA")
        #expect(vm.sidebar.displayedSidebarRecordings.count == 25)
        #expect(vm.sidebar.hasMoreSidebarRecordings == true)
        #expect(vm.sidebar.filterState.selectedRecordingIds == ["rec-a-59"])
        #expect(vm.sidebar.hasPendingSelectionChanges == false)

        // Select All selects every matching recording across all pages in the section and triggers pending state.
        vm.sidebar.selectAllSidebarRecordings()
        #expect(vm.sidebar.filterState.selectedRecordingIds.count == 60)
        #expect(vm.sidebar.allSidebarRecordingsSelected == true)
        #expect(vm.sidebar.hasPendingSelectionChanges == true)
    }

    @MainActor
    @Test func defaultDateRangeIsLastMonthAndDateFilterNarrowsSidebarListOnly() async {
        let formatter = ISO8601DateFormatter()
        let referenceDate = formatter.date(from: "2026-11-17T12:00:00Z")!
        let vm = DashboardViewModel(
            databaseManager: DatabaseManager(inMemory: true),
            networkManager: .shared,
            diskCache: TelemetryDiskCache(isEnabled: false),
            referenceDate: referenceDate
        )

        #expect(vm.sidebar.filterState.datePreset == .lastMonth)

        let recs = [
            RecordingDTO(
                recordingId: "rec-aug20",
                filename: "aug20.mp4",
                timestamp: "2026-08-20T06:00:00Z",
                cameraId: "CAM-ALPHA-01",
                locationTag: "Section Alpha - Wide Overview Bench",
                durationS: 43_200,
                fps: 25,
                resolution: "1920x1080",
                tags: ["section:Alpha"]
            ),
            RecordingDTO(
                recordingId: "rec-oct01",
                filename: "oct01.mp4",
                timestamp: "2026-10-01T06:00:00Z",
                cameraId: "CAM-ALPHA-01",
                locationTag: "Section Alpha - Wide Overview Bench",
                durationS: 43_200,
                fps: 25,
                resolution: "1920x1080",
                tags: ["section:Alpha"]
            ),
            RecordingDTO(
                recordingId: "rec-oct20",
                filename: "oct20.mp4",
                timestamp: "2026-10-20T06:00:00Z",
                cameraId: "CAM-ALPHA-02",
                locationTag: "Section Alpha - Pit Lake Lower Bench",
                durationS: 43_200,
                fps: 25,
                resolution: "1920x1080",
                tags: ["section:Alpha"]
            ),
            RecordingDTO(
                recordingId: "rec-nov16",
                filename: "nov16.mp4",
                timestamp: "2026-11-16T06:00:00Z",
                cameraId: "CAM-ALPHA-03",
                locationTag: "Section Alpha - Pit Floor Loading Pocket",
                durationS: 43_200,
                fps: 25,
                resolution: "1920x1080",
                tags: ["section:Alpha"]
            ),
        ]

        await vm.seedCacheAndProjectForTesting(
            recordings: recs,
            cyclesByRec: [:],
            segmentsByRec: [:],
            selectedRecordingIds: ["rec-nov16"]
        )

        // Default `.lastMonth` from 2026-11-17 spans 2026-10-17 ..< 2026-11-18 UTC.
        #expect(vm.sidebar.sidebarRecordings.map(\.recordingId) == ["rec-nov16", "rec-oct20"])
        #expect(vm.sidebar.filterState.selectedRecordingIds == ["rec-nov16"])
        #expect(vm.sidebar.hasPendingSelectionChanges == false)

        // Switching date range filters the sidebar list only without altering selection.
        vm.sidebar.selectDatePreset(.last7Days)
        #expect(vm.sidebar.sidebarRecordings.map(\.recordingId) == ["rec-nov16"])
        #expect(vm.sidebar.filterState.selectedRecordingIds == ["rec-nov16"])
        #expect(vm.sidebar.hasPendingSelectionChanges == false)

        vm.sidebar.selectDatePreset(.last3Months)
        #expect(vm.sidebar.sidebarRecordings.map(\.recordingId) == ["rec-nov16", "rec-oct20", "rec-oct01", "rec-aug20"])

        vm.sidebar.selectDatePreset(.allDates)
        #expect(vm.sidebar.sidebarRecordings.count == 4)

        // Custom start/end range activates `.custom` and filters strictly by inclusive UTC day boundaries.
        vm.sidebar.filterState.startDate = formatter.date(from: "2026-09-25T10:00:00Z")!
        vm.sidebar.onCustomStartDateEdited()
        vm.sidebar.filterState.endDate = formatter.date(from: "2026-10-21T08:00:00Z")!
        vm.sidebar.onCustomEndDateEdited()

        #expect(vm.sidebar.filterState.datePreset == .custom)
        #expect(vm.sidebar.sidebarRecordings.map(\.recordingId) == ["rec-oct20", "rec-oct01"])
    }
}
