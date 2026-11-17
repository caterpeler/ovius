import Foundation
import Observation
import SwiftData

/// Typed errors thrown by `DatabaseManager` when enforcing relational integrity.
public enum DatabaseManagerError: LocalizedError, Sendable, Equatable {
    case clusterNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .clusterNotFound(let clusterId):
            "Cannot save section because parent cluster '\(clusterId)' does not exist."
        }
    }
}

/// Singleton SwiftData manager owning Domains 2 (settings, clusters, sections) and 3 (adaptive diagnostics).
@MainActor @Observable
public final class DatabaseManager {
    public static let shared = DatabaseManager()

    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }
    public private(set) var lastError: String?

    public init(inMemory: Bool = false) {
        let schema = Schema([
            AppSettings.self,
            Cluster.self,
            Section.self,
            AnomalyPattern.self,
            OperationalLead.self,
            DiagnosticItem.self,
            DiagnosticCard.self,
        ])

        do {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
            self.container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fall back to an in-memory container if the local persistent store cannot open.
            self.lastError = "Persistent SwiftData store failed to initialize: \(error.localizedDescription)"
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            self.container = try! ModelContainer(for: schema, configurations: [fallbackConfig])
        }

        do {
            try seedDefaultsIfNeeded()
        } catch {
            self.lastError = "Failed to seed SwiftData defaults: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence Helpers

    public func save() throws {
        try context.save()
    }

    // MARK: - Domain 2: AppSettings

    /// Fetches the singleton `AppSettings` row, creating defaults if missing.
    public func fetchSettings() throws -> AppSettings {
        let targetId = "default"
        let descriptor = FetchDescriptor<AppSettings>(
            predicate: #Predicate<AppSettings> { $0.settingsId == targetId }
        )
        if let existing = try context.fetch(descriptor).first {
            return existing
        }
        let created = AppSettings(settingsId: targetId)
        context.insert(created)
        try context.save()
        return created
    }

    /// Updates mathematical, allowance, and shift-schedule parameters in SwiftData.
    public func updateSettings(
        meanPayloadM3: Double? = nil,
        struckPayloadM3: Double? = nil,
        heapedPayloadM3: Double? = nil,
        idleThresholdS: Int? = nil,
        shiftEdgeWindowMin: Int? = nil,
        shiftStartHours: [String]? = nil,
        breakWindows: [String]? = nil
    ) throws -> AppSettings {
        let settings = try fetchSettings()
        if let meanPayloadM3 { settings.meanPayloadM3 = meanPayloadM3 }
        if let struckPayloadM3 { settings.struckPayloadM3 = struckPayloadM3 }
        if let heapedPayloadM3 { settings.heapedPayloadM3 = heapedPayloadM3 }
        if let idleThresholdS { settings.idleThresholdS = idleThresholdS }
        if let shiftEdgeWindowMin { settings.shiftEdgeWindowMin = shiftEdgeWindowMin }
        if let shiftStartHours { settings.shiftStartHours = shiftStartHours }
        if let breakWindows { settings.breakWindows = breakWindows }
        settings.updatedAt = .now
        try context.save()
        return settings
    }

    // MARK: - Domain 2: Clusters & Sections

    public func fetchClusters() throws -> [Cluster] {
        var descriptor = FetchDescriptor<Cluster>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.sections]
        return try context.fetch(descriptor)
    }

    public func fetchCluster(clusterId: String) throws -> Cluster? {
        var descriptor = FetchDescriptor<Cluster>(
            predicate: #Predicate<Cluster> { $0.clusterId == clusterId }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.sections]
        return try context.fetch(descriptor).first
    }

    @discardableResult
    public func upsertCluster(
        clusterId: String,
        name: String,
        tags: [String] = []
    ) throws -> Cluster {
        if let existing = try fetchCluster(clusterId: clusterId) {
            existing.name = name
            existing.tags = tags
            try context.save()
            return existing
        }
        let cluster = Cluster(clusterId: clusterId, name: name, tags: tags)
        context.insert(cluster)
        try context.save()
        return cluster
    }

    public func deleteCluster(_ cluster: Cluster) throws {
        context.delete(cluster)
        try context.save()
    }

    public func fetchSections(clusterId: String? = nil) throws -> [Section] {
        let descriptor: FetchDescriptor<Section>
        if let clusterId {
            descriptor = FetchDescriptor<Section>(
                predicate: #Predicate<Section> { $0.clusterId == clusterId },
                sortBy: [SortDescriptor(\.name, order: .forward)]
            )
        } else {
            descriptor = FetchDescriptor<Section>(
                sortBy: [SortDescriptor(\.name, order: .forward)]
            )
        }
        return try context.fetch(descriptor)
    }

    public func fetchSection(sectionId: String) throws -> Section? {
        let descriptor = FetchDescriptor<Section>(
            predicate: #Predicate<Section> { $0.sectionId == sectionId }
        )
        return try context.fetch(descriptor).first
    }

    @discardableResult
    public func upsertSection(
        sectionId: String,
        clusterId: String,
        name: String,
        filenames: [String] = [],
        cameraIds: [String] = [],
        locationTags: [String] = [],
        customTags: [String] = [],
        assignedTrucks: Int? = nil
    ) throws -> Section {
        guard let parentCluster = try fetchCluster(clusterId: clusterId) else {
            throw DatabaseManagerError.clusterNotFound(clusterId)
        }
        if let existing = try fetchSection(sectionId: sectionId) {
            existing.clusterId = clusterId
            existing.name = name
            existing.filenames = filenames
            existing.cameraIds = cameraIds
            existing.locationTags = locationTags
            existing.customTags = customTags
            existing.assignedTrucks = assignedTrucks
            existing.cluster = parentCluster
            try context.save()
            return existing
        }
        let section = Section(
            sectionId: sectionId,
            clusterId: clusterId,
            name: name,
            filenames: filenames,
            cameraIds: cameraIds,
            locationTags: locationTags,
            customTags: customTags,
            assignedTrucks: assignedTrucks,
            cluster: parentCluster
        )
        context.insert(section)
        try context.save()
        return section
    }

    public func deleteSection(_ section: Section) throws {
        context.delete(section)
        try context.save()
    }

    // MARK: - Network Filter Bridge

    /// Builds `TelemetryQueryFilters` for `NetworkManager` from a SwiftData `Section`'s dynamic selectors.
    public func makeFilters(
        for section: Section,
        startTime: String? = nil,
        endTime: String? = nil,
        todStartS: Double? = nil,
        todEndS: Double? = nil,
        states: [String]? = nil,
        includeSegments: Bool? = nil,
        includeScoops: Bool? = false,
        limit: Int? = 15_000
    ) -> TelemetryQueryFilters {
        TelemetryQueryFilters(
            startTime: startTime,
            endTime: endTime,
            cameraIds: section.cameraIds.isEmpty ? nil : section.cameraIds,
            locationTags: section.locationTags.isEmpty ? nil : section.locationTags,
            tags: section.customTags.isEmpty ? nil : section.customTags,
            filenames: section.filenames.isEmpty ? nil : section.filenames,
            states: states,
            todStartS: todStartS,
            todEndS: todEndS,
            includeSegments: includeSegments,
            includeScoops: includeScoops,
            limit: limit
        )
    }

    /// Client-side recording matcher mirroring `ovius_backend`'s `_filter_recordings_in_memory` AND semantics.
    public func filterRecordings(_ recordings: [RecordingDTO], matching section: Section) -> [RecordingDTO] {
        let allowedCams = section.cameraIds.isEmpty ? nil : Set(section.cameraIds)
        let allowedLocs = section.locationTags.isEmpty ? nil : Set(section.locationTags)
        let allowedTags = section.customTags.isEmpty ? nil : Set(section.customTags)
        let allowedFiles = section.filenames.isEmpty ? nil : Set(section.filenames)

        return recordings.filter { rec in
            if let allowedCams, !allowedCams.contains(rec.cameraId) { return false }
            if let allowedLocs, !allowedLocs.contains(rec.locationTag) { return false }
            if let allowedFiles, !allowedFiles.contains(rec.filename) { return false }
            if let allowedTags, Set(rec.tags).isDisjoint(with: allowedTags) { return false }
            return true
        }
    }

    /// Builds wildcard `TelemetryQueryFilters` covering every section inside a `Cluster`.
    public func makeFilters(
        for cluster: Cluster,
        startTime: String? = nil,
        endTime: String? = nil,
        todStartS: Double? = nil,
        todEndS: Double? = nil,
        includeSegments: Bool? = nil,
        includeScoops: Bool? = false,
        limit: Int? = 15_000
    ) -> TelemetryQueryFilters {
        let allCameras = Array(Set(cluster.sections.flatMap(\.cameraIds))).sorted()
        return TelemetryQueryFilters(
            startTime: startTime,
            endTime: endTime,
            cameraIds: allCameras.isEmpty ? ["*"] : allCameras,
            todStartS: todStartS,
            todEndS: todEndS,
            includeSegments: includeSegments,
            includeScoops: includeScoops,
            limit: limit
        )
    }

    // MARK: - Domain 3: Adaptive Diagnostics

    public func fetchPatterns(activeOnly: Bool = true) throws -> [AnomalyPattern] {
        let descriptor: FetchDescriptor<AnomalyPattern>
        if activeOnly {
            descriptor = FetchDescriptor<AnomalyPattern>(
                predicate: #Predicate<AnomalyPattern> { $0.isActive == true },
                sortBy: [SortDescriptor(\.patternId, order: .forward)]
            )
        } else {
            descriptor = FetchDescriptor<AnomalyPattern>(
                sortBy: [SortDescriptor(\.patternId, order: .forward)]
            )
        }
        return try context.fetch(descriptor)
    }

    public func fetchLeads(activeOnly: Bool = true) throws -> [OperationalLead] {
        var descriptor: FetchDescriptor<OperationalLead>
        if activeOnly {
            descriptor = FetchDescriptor<OperationalLead>(
                predicate: #Predicate<OperationalLead> { $0.isActive == true },
                sortBy: [SortDescriptor(\.leadId, order: .forward)]
            )
        } else {
            descriptor = FetchDescriptor<OperationalLead>(
                sortBy: [SortDescriptor(\.leadId, order: .forward)]
            )
        }
        descriptor.relationshipKeyPathsForPrefetching = [
            \.requiredPatterns,
            \.supportingPatterns,
            \.diagnostics,
        ]
        return try context.fetch(descriptor)
    }

    public func fetchDiagnosticCards(includeStaticAudit: Bool = false) throws -> [DiagnosticCard] {
        let descriptor: FetchDescriptor<DiagnosticCard>
        if includeStaticAudit {
            descriptor = FetchDescriptor<DiagnosticCard>(
                sortBy: [SortDescriptor(\.cardId, order: .forward)]
            )
        } else {
            descriptor = FetchDescriptor<DiagnosticCard>(
                predicate: #Predicate<DiagnosticCard> { $0.isStaticAudit == false },
                sortBy: [SortDescriptor(\.cardId, order: .forward)]
            )
        }
        return try context.fetch(descriptor)
    }

    public func fetchStaticAuditCard() throws -> DiagnosticCard? {
        let descriptor = FetchDescriptor<DiagnosticCard>(
            predicate: #Predicate<DiagnosticCard> { $0.isStaticAudit == true }
        )
        return try context.fetch(descriptor).first
    }

    /// Pools diagnostics across flagged leads and sorts by:
    /// 1. Lead overlap count (descending)
    /// 2. Best order-of-appearance index `min(index)` across flagged leads (`0` before `1` before `2`)
    /// 3. `diagnostic.priorityOrder` (ascending)
    public func resolveDashboardDiagnostics(
        flaggedLeads: [OperationalLead]
    ) -> [ActiveDiagnosticViewItem] {
        var groupedByDiagId: [String: (diag: DiagnosticItem, bestIndex: Int, leads: [String])] = [:]
        var seenLeadIds: Set<String> = []

        for lead in flaggedLeads where seenLeadIds.insert(lead.leadId).inserted {
            for (index, diag) in lead.orderedDiagnostics.enumerated() where diag.isActive {
                if var existing = groupedByDiagId[diag.diagnosticId] {
                    existing.bestIndex = min(existing.bestIndex, index)
                    existing.leads.append(lead.name)
                    groupedByDiagId[diag.diagnosticId] = existing
                } else {
                    groupedByDiagId[diag.diagnosticId] = (diag, index, [lead.name])
                }
            }
        }

        return groupedByDiagId.values
            .compactMap { entry -> ActiveDiagnosticViewItem? in
                guard let card = entry.diag.viewCard else { return nil }
                return ActiveDiagnosticViewItem(
                    diagnosticId: entry.diag.diagnosticId,
                    promptName: entry.diag.name,
                    bestAppearanceIndex: entry.bestIndex,
                    priorityOrder: entry.diag.priorityOrder,
                    triggeredByLeadNames: entry.leads,
                    cardId: card.cardId,
                    cardName: card.name,
                    widgetType: card.widgetType,
                    primaryMetric: card.primaryMetric,
                    secondaryMetric: card.secondaryMetric,
                    showsHorizon: card.showsHorizon,
                    dateHorizon: card.dateHorizon,
                    timeHorizon: card.timeHorizon
                )
            }
            .sorted { lhs, rhs in
                if lhs.triggeredByLeadNames.count != rhs.triggeredByLeadNames.count {
                    return lhs.triggeredByLeadNames.count > rhs.triggeredByLeadNames.count
                }
                if lhs.bestAppearanceIndex != rhs.bestAppearanceIndex {
                    return lhs.bestAppearanceIndex < rhs.bestAppearanceIndex
                }
                return lhs.priorityOrder < rhs.priorityOrder
            }
    }

    // MARK: - Idempotent Default Seeding

    public func seedDefaultsIfNeeded() throws {
        try seedDefaultSettingsIfNeeded()
        try seedDefaultClustersIfNeeded()
        try seedActiveDiagnosticCatalogIfNeeded()
    }

    private func seedDefaultSettingsIfNeeded() throws {
        _ = try fetchSettings()
    }

    private func seedDefaultClustersIfNeeded() throws {
        let count = try context.fetchCount(FetchDescriptor<Cluster>())
        guard count == 0 else { return }

        let clusterId = "CLUSTER_OPEN_PIT_MAIN"
        let mainCluster = Cluster(
            clusterId: clusterId,
            name: "Open-Pit Site",
            tags: ["site:open-pit", "horizon:12h"]
        )
        context.insert(mainCluster)

        let alpha = Section(
            sectionId: "SEC_ALPHA",
            clusterId: clusterId,
            name: "Section Alpha",
            cameraIds: ["CAM-ALPHA-01", "CAM-ALPHA-02", "CAM-ALPHA-03"],
            locationTags: [
                "Section Alpha - Wide Overview Bench",
                "Section Alpha - Pit Lake Lower Bench",
                "Section Alpha - Pit Floor Loading Pocket",
            ],
            customTags: ["section:Alpha"],
            cluster: mainCluster
        )

        let beta = Section(
            sectionId: "SEC_BETA",
            clusterId: clusterId,
            name: "Section Beta",
            cameraIds: ["CAM-BETA-01", "CAM-BETA-02", "CAM-BETA-03", "CAM-BETA-04", "CAM-BETA-05"],
            locationTags: [
                "Section Beta - Highwall Haul Ramp Pocket",
                "Section Beta - Lower West Loading Bench",
                "Section Beta - Queue Bottleneck Bench",
                "Section Beta - Pit Z East Pocket",
                "Section Beta - Panoramic 4-Pocket Bench",
            ],
            customTags: ["section:Beta"],
            cluster: mainCluster
        )

        let gamma = Section(
            sectionId: "SEC_GAMMA",
            clusterId: clusterId,
            name: "Section Gamma",
            cameraIds: ["CAM-GAMMA-01", "CAM-GAMMA-02", "CAM-GAMMA-03"],
            locationTags: [
                "Section Gamma - Dual-Truck Loading Pocket",
                "Section Gamma - Upper Spoil Berm Pocket",
                "Section Gamma - Dual-Shovel Production Bench",
            ],
            customTags: ["section:Gamma"],
            cluster: mainCluster
        )

        context.insert(alpha)
        context.insert(beta)
        context.insert(gamma)
        try context.save()
    }

    private func seedActiveDiagnosticCatalogIfNeeded() throws {
        let existingPatterns = try context.fetch(FetchDescriptor<AnomalyPattern>())
        let existingLeads = try context.fetch(FetchDescriptor<OperationalLead>())
        let existingDiagnostics = try context.fetch(FetchDescriptor<DiagnosticItem>())
        let existingCards = try context.fetch(FetchDescriptor<DiagnosticCard>())

        var patternsById = Dictionary(uniqueKeysWithValues: existingPatterns.map { ($0.patternId, $0) })
        var leadsById = Dictionary(uniqueKeysWithValues: existingLeads.map { ($0.leadId, $0) })
        var diagsById = Dictionary(uniqueKeysWithValues: existingDiagnostics.map { ($0.diagnosticId, $0) })
        var cardsById = Dictionary(uniqueKeysWithValues: existingCards.map { ($0.cardId, $0) })

        // 1. Seed 15 Active AnomalyPatterns
        let patternSpecs: [(String, String, MetricKey, ComparisonMode, AnomalyDirection, Double, String)] = [
            ("PAT_HIGH_QUEUE_TIME", "Elevated Truck Queue Time", .avgQueueTimeS, .relativeDeltaPct, .aboveBaseline, 0.35,
             "Trucks wait significantly longer in queue before spotting than the average over the set time horizon."),
            ("PAT_NEAR_ZERO_QUEUE", "Near-Zero Truck Queue", .avgQueueTimeS, .absoluteValue, .belowBaseline, 3.0,
             "Trucks wait < 3.0s on average before spotting; zero buffer of incoming trucks."),
            ("PAT_HIGH_ARRIVAL_RATE", "Elevated Truck Arrival Rate", .truckArrivalRateHr, .relativeDeltaPct, .aboveBaseline, 0.30,
             "Mean hourly truck arrival rate is >= 30% above the cluster horizon (high dispatch inflow)."),
            ("PAT_LOW_ARRIVAL_RATE", "Moderate Truck Arrival Drop", .truckArrivalRateHr, .relativeDeltaPct, .belowBaseline, -0.25,
             "Mean hourly truck arrival rate falls >= 25% below the cluster horizon (moderate inflow deficit)."),
            ("PAT_SEVERE_ARRIVAL_DROP", "Severe Truck Arrival Drop", .truckArrivalRateHr, .relativeDeltaPct, .belowBaseline, -0.50,
             "Mean hourly truck arrival rate falls >= 50% below the cluster horizon (severe starvation or prolonged halt)."),
            ("PAT_LONG_SPOT_TIME", "Prolonged Truck Spotting", .avgSpotTimeS, .relativeDeltaPct, .aboveBaseline, 0.30,
             "Trucks take significantly longer to reverse and position."),
            ("PAT_SLOW_DEPARTURE", "Sluggish Truck Departure", .avgDepartureLagS, .relativeDeltaPct, .aboveBaseline, 0.35,
             "Loaded trucks experience traction or grade delays when pulling out of the loading area."),
            ("PAT_NORMAL_DEPARTURE", "Nominal Truck Departure", .avgDepartureLagS, .zScore, .withinBand, 0.6,
             "Pull-out departure lag is within cluster norms (rules out environmental / traction hazard)."),
            ("PAT_LONG_LOAD_DURATION", "Extended Total Load Time", .avgLoadDurationS, .relativeDeltaPct, .aboveBaseline, 0.25,
             "Total active loading duration (t_load_end - t_load_start) is elevated."),
            ("PAT_NORMAL_LOAD_DURATION", "Nominal Total Load Time", .avgLoadDurationS, .zScore, .withinBand, 0.6,
             "Total active loading duration is within cluster norms (rules out excavator slowdown)."),
            ("PAT_HIGH_EXCAVATOR_HANG", "High Excavator Hang Time", .excavatorHangRatio, .relativeDeltaPct, .aboveBaseline, 0.35,
             "Excavator spends a high proportion of time idle/hanging between truck loads."),
            ("PAT_SUSTAINED_IDLE_EXCESS", "Sustained Post-Allowance Idle", .trueIdleExcessS, .absoluteValue, .aboveBaseline, 60.0,
             "Max continuous stationary spell exceeds the 300s (idle_threshold_s) allowance by > 60s (total halt > 360s)."),
            ("PAT_SLOW_SHIFT_EDGE", "Slow Shift Startup / Closing Window", .shiftEdgeIdleRatio, .relativeDeltaPct, .aboveBaseline, 0.35,
             "Shovel hang or stationary idle during the configurable shift-edge window is >= 35% above the cluster horizon."),
            ("PAT_EXTENDED_BREAK_LULL", "Extended Midday / Break Standstill", .breakWindowIdleExcessS, .absoluteValue, .aboveBaseline, 600.0,
             "Synchronized stationary idle or zero-arrival gap extends > 600s (10 min) past the configured break window."),
            ("PAT_RECURRING_HOUR_SLUMP", "Recurring Time-of-Day Productivity Dip", .hourlySlumpConcentration, .absoluteValue, .aboveBaseline, 0.50,
             "More than 50% of daily idle or queue delay consistently concentrates within the same 1-2 hour wall-clock bucket."),
        ]

        for spec in patternSpecs {
            if let existing = patternsById[spec.0] {
                if existing.name != spec.1 { existing.name = spec.1 }
                if existing.details != spec.6 { existing.details = spec.6 }
                if existing.metricKey != spec.2 { existing.metricKey = spec.2 }
                if existing.comparisonMode != spec.3 { existing.comparisonMode = spec.3 }
                if existing.direction != spec.4 { existing.direction = spec.4 }
                if existing.thresholdValue != spec.5 { existing.thresholdValue = spec.5 }
                if !existing.isActive { existing.isActive = true }
            } else {
                let pattern = AnomalyPattern(
                    patternId: spec.0,
                    name: spec.1,
                    details: spec.6,
                    metricKey: spec.2,
                    comparisonMode: spec.3,
                    direction: spec.4,
                    thresholdValue: spec.5,
                    isActive: true
                )
                context.insert(pattern)
                patternsById[spec.0] = pattern
            }
        }

        // 2. Seed / reconcile 9 Active DiagnosticItem <-> DiagnosticCard 1:1 Pairs
        let diagCardSpecs: [(Int, String, String, String, String, WidgetType, MetricKey, MetricKey?, Bool, String, String)] = [
            (2, "DIAG_02_QUEUE_DISTRIBUTION", "Inspect whether truck queue wait times exceed active loading duration across cycles.",
             "CARD_QUEUE_WAIT_HISTOGRAM", "Truck Queue Time Distribution", .histogram, .avgQueueTimeS, .truckArrivalRateHr, true, "14 days (2 wks)", "Full Shift (06:00–18:00)"),
            (3, "DIAG_03_EXCAVATOR_STATES", "Compare excavator time spent in active loading vs. idle hang states.",
             "CARD_EXCAVATOR_STATE_BAR", "Excavator Time Allocation", .phaseBreakdownBar, .excavatorHangRatio, .avgLoadDurationS, true, "30 days (1 mo)", "Full Shift (06:00–18:00)"),
            (5, "DIAG_05_CYCLE_GANTT", "Inspect the chronological machine state Gantt timeline for overlapping queues or simultaneous stoppages.",
             "CARD_STATE_GANTT_TIMELINE", "Machine State & Cycle Timeline", .stateGanttTimeline, .avgLoadDurationS, .avgQueueTimeS, false, "None (Selected Date)", "Raw Clip Window"),
            (7, "DIAG_07_PHASE_BREAKDOWN", "Compare mean Queue, Spot, Load, and Departure phase durations side-by-side against the cluster baseline.",
             "CARD_CYCLE_PHASE_STACK", "Haul Cycle Phase Breakdown", .phaseBreakdownBar, .avgLoadDurationS, .avgSpotTimeS, true, "30 days (1 mo)", "Full Shift (06:00–18:00)"),
            (8, "DIAG_08_SPOT_DEPART_TREND", "Verify whether spotting (reversing) slowdowns occur alone (tight loading area) or alongside slow departures (environmental / traction hazard).",
             "CARD_MANEUVER_COMPARISON", "Spotting vs. Departure Maneuver Time", .kpiComparison, .avgSpotTimeS, .avgDepartureLagS, true, "7–14 days (1–2 wks)", "Cycle Seq. (06:00–18:00)"),
            (9, "DIAG_09_INTER_ARRIVAL_GAPS", "Examine time gaps between consecutive truck arrivals to detect haul road delays, arrival bunching, or truck starvation.",
             "CARD_ARRIVAL_GAP_CHART", "Truck Arrival Frequency & Gaps", .histogram, .truckArrivalRateHr, .excavatorHangRatio, true, "7–14 days (1–2 wks)", "Full Shift + Peak Gap"),
            (10, "DIAG_10_IDLE_EXCESS_TIMELINE", "Check continuous stationary spells exceeding the 300s (idle_threshold_s) allowance across machines.",
             "CARD_IDLE_ALLOWANCE_KPI", "Post-Allowance Net Idle Time", .kpiComparison, .trueIdleExcessS, .excavatorHangRatio, true, "90 days (1 qtr)", "Full Shift (>300s Cutoff)"),
            (13, "DIAG_13_HOURLY_PRODUCTIVITY", "Compare hourly volumetric output (m3/hr) and truck arrival rate across the day (06:00–18:00) against cluster hourly averages to pinpoint startup, break, or closing drops.",
             "CARD_HOURLY_PRODUCTIVITY_TREND", "Hourly Productivity vs. Day Curve", .hourlyMetricTrend, .volumetricRateM3Hr, .truckArrivalRateHr, true, "14–30 days (2–4 wks)", "1h Buckets + 60m Edges (06:00–18:00)"),
            (14, "DIAG_14_HOURLY_CYCLE_METRICS", "Plot hourly average loading duration, queue wait, and excavator hang across the day against cluster hourly baselines to see when cycle slowdowns emerge.",
             "CARD_HOURLY_CYCLE_METRIC_TREND", "Hourly Cycle & Queue Metrics Across Day", .hourlyMetricTrend, .avgLoadDurationS, .excavatorHangRatio, true, "14–30 days (2–4 wks)", "1h Buckets (06:00–18:00)"),
        ]

        for spec in diagCardSpecs {
            let card: DiagnosticCard
            if let existingCard = cardsById[spec.3] {
                if existingCard.name != spec.4 { existingCard.name = spec.4 }
                if existingCard.widgetType != spec.5 { existingCard.widgetType = spec.5 }
                if existingCard.primaryMetric != spec.6 { existingCard.primaryMetric = spec.6 }
                if existingCard.secondaryMetric != spec.7 { existingCard.secondaryMetric = spec.7 }
                if existingCard.showsHorizon != spec.8 { existingCard.showsHorizon = spec.8 }
                if existingCard.dateHorizon != spec.9 { existingCard.dateHorizon = spec.9 }
                if existingCard.timeHorizon != spec.10 { existingCard.timeHorizon = spec.10 }
                if existingCard.isStaticAudit { existingCard.isStaticAudit = false }
                card = existingCard
            } else {
                card = DiagnosticCard(
                    cardId: spec.3,
                    name: spec.4,
                    widgetType: spec.5,
                    primaryMetric: spec.6,
                    secondaryMetric: spec.7,
                    showsHorizon: spec.8,
                    dateHorizon: spec.9,
                    timeHorizon: spec.10,
                    isStaticAudit: false
                )
                context.insert(card)
                cardsById[spec.3] = card
            }

            if let existingDiag = diagsById[spec.1] {
                if existingDiag.name != spec.2 { existingDiag.name = spec.2 }
                if existingDiag.priorityOrder != spec.0 { existingDiag.priorityOrder = spec.0 }
                if existingDiag.viewCard?.cardId != card.cardId { existingDiag.viewCard = card }
                if !existingDiag.isActive { existingDiag.isActive = true }
            } else {
                let diag = DiagnosticItem(
                    diagnosticId: spec.1,
                    name: spec.2,
                    priorityOrder: spec.0,
                    viewCard: card,
                    isActive: true
                )
                context.insert(diag)
                diagsById[spec.1] = diag
            }
        }

        // Static Data Quality / Rule 4.2-4.3 audit card (non-lead-triggered).
        if let existingAudit = cardsById["CARD_INCOMPLETE_CYCLE_TABLE"] {
            if !existingAudit.isStaticAudit { existingAudit.isStaticAudit = true }
        } else {
            let auditCard = DiagnosticCard(
                cardId: "CARD_INCOMPLETE_CYCLE_TABLE",
                name: "Sample Coverage & Cutoff Audit",
                widgetType: .cycleTable,
                primaryMetric: .incompleteCycleRatio,
                secondaryMetric: .outOfFrameRatio,
                showsHorizon: false,
                dateHorizon: "None (Selected Date)",
                timeHorizon: "Raw Clip Window",
                isStaticAudit: true
            )
            context.insert(auditCard)
            cardsById["CARD_INCOMPLETE_CYCLE_TABLE"] = auditCard
        }

        // 3. Seed 9 Active OperationalLeads
        let leadSpecs: [(String, String, String, [String], [String], [String], String)] = [
            ("LEAD_DUMPTRUCK_OVERSUPPLY", "Dumptruck Oversupply (Over-Trucked)", "Fleet Balance",
             ["PAT_HIGH_QUEUE_TIME"],
             ["PAT_HIGH_ARRIVAL_RATE", "PAT_NORMAL_LOAD_DURATION"],
             ["DIAG_02_QUEUE_DISTRIBUTION", "DIAG_05_CYCLE_GANTT"],
             "Too many trucks are assigned to this shovel (or high arrival inflow on the haul road), causing excessive queuing while the shovel loads at normal capacity."),
            ("LEAD_EXCAVATOR_OVERSUPPLY", "Excavator Oversupply (Under-Trucked)", "Fleet Balance",
             ["PAT_HIGH_EXCAVATOR_HANG", "PAT_NEAR_ZERO_QUEUE"],
             ["PAT_LOW_ARRIVAL_RATE"],
             ["DIAG_03_EXCAVATOR_STATES", "DIAG_09_INTER_ARRIVAL_GAPS"],
             "The excavator is starved of trucks with zero queue buffer and spends excessive time hanging waiting for the next truck arrival."),
            ("LEAD_BAD_WEATHER", "Bad Weather / Environmental Hazard", "Environmental",
             ["PAT_LONG_SPOT_TIME", "PAT_SLOW_DEPARTURE"],
             ["PAT_LONG_LOAD_DURATION", "PAT_HIGH_QUEUE_TIME"],
             ["DIAG_07_PHASE_BREAKDOWN", "DIAG_08_SPOT_DEPART_TREND", "DIAG_05_CYCLE_GANTT"],
             "Simultaneous slowdown across truck reversing (spotting), loading, and pulling out (departing) points to rain, mud, dust/haze, or poor floor traction on the bench."),
            ("LEAD_BLOCKING_INCIDENT", "Blocking Incident", "Incident / Stoppage",
             ["PAT_SEVERE_ARRIVAL_DROP", "PAT_SUSTAINED_IDLE_EXCESS"],
             ["PAT_HIGH_EXCAVATOR_HANG"],
             ["DIAG_05_CYCLE_GANTT", "DIAG_10_IDLE_EXCESS_TIMELINE"],
             "Abrupt halt in haul road arrivals combined with continuous post-allowance machine idling indicates a blocking incident (overturned equipment, slope failure, or emergency stoppage)."),
            ("LEAD_HAUL_ROAD_BOTTLENECK", "Downstream Road / Crusher Delay", "Haul Network",
             ["PAT_SEVERE_ARRIVAL_DROP", "PAT_NEAR_ZERO_QUEUE"],
             ["PAT_HIGH_EXCAVATOR_HANG", "PAT_HIGH_ARRIVAL_RATE"],
             ["DIAG_09_INTER_ARRIVAL_GAPS", "DIAG_05_CYCLE_GANTT"],
             "Trucks stop arriving at regular intervals without local pocket congestion (often followed by platoon recovery bursts), indicating a downstream bottleneck at the dump/crusher or main ramp."),
            ("LEAD_TIGHT_POCKET_GEOMETRY", "Tight Loading Area / Poor Floor Cleanup", "Bench Operations",
             ["PAT_LONG_SPOT_TIME", "PAT_NORMAL_DEPARTURE"],
             ["PAT_HIGH_QUEUE_TIME", "PAT_NORMAL_LOAD_DURATION"],
             ["DIAG_08_SPOT_DEPART_TREND", "DIAG_07_PHASE_BREAKDOWN", "DIAG_02_QUEUE_DISTRIBUTION"],
             "Spotting takes abnormally long while forward departure pull-out speed remains normal, indicating a cramped loading area or spillage obstructing the backing path."),
            ("LEAD_LOADING_SLOWDOWN", "Inflated Excavator Loading", "Loading Operations",
             ["PAT_LONG_LOAD_DURATION"],
             ["PAT_HIGH_QUEUE_TIME", "PAT_NORMAL_DEPARTURE"],
             ["DIAG_07_PHASE_BREAKDOWN", "DIAG_03_EXCAVATOR_STATES", "DIAG_05_CYCLE_GANTT"],
             "Active truck loading duration is elevated while floor traction remains normal, pointing to tough digging conditions, awkward bench presentation, or reduced shovel cycle pace."),
            ("LEAD_SHIFT_TRANSITION_LOSS", "Shift Startup / Closing Transition Loss", "Shift Discipline",
             ["PAT_SLOW_SHIFT_EDGE"],
             ["PAT_HIGH_EXCAVATOR_HANG", "PAT_LOW_ARRIVAL_RATE", "PAT_RECURRING_HOUR_SLUMP"],
             ["DIAG_13_HOURLY_PRODUCTIVITY", "DIAG_14_HOURLY_CYCLE_METRICS", "DIAG_05_CYCLE_GANTT"],
             "Productivity drops during the first or last 60 minutes of the shift (settings.shift_edge_window_min), pointing to delayed pre-start checks, late dispatch, or early park-up."),
            ("LEAD_LATE_BREAK_RETURN", "Late Break Return / Midday Standstill", "Shift Discipline",
             ["PAT_EXTENDED_BREAK_LULL"],
             ["PAT_SUSTAINED_IDLE_EXCESS", "PAT_SEVERE_ARRIVAL_DROP", "PAT_RECURRING_HOUR_SLUMP"],
             ["DIAG_13_HOURLY_PRODUCTIVITY", "DIAG_14_HOURLY_CYCLE_METRICS", "DIAG_10_IDLE_EXCESS_TIMELINE"],
             "Multi-machine idling or arrival gaps cluster around the midday break window, indicating late or staggered operator return from lunch rather than an unplanned blocking incident."),
        ]

        for spec in leadSpecs {
            let req = spec.3.compactMap { patternsById[$0] }
            let sup = spec.4.compactMap { patternsById[$0] }
            let diags = spec.5.compactMap { diagsById[$0] }
            if let existingLead = leadsById[spec.0] {
                if existingLead.name != spec.1 { existingLead.name = spec.1 }
                if existingLead.category != spec.2 { existingLead.category = spec.2 }
                if existingLead.details != spec.6 { existingLead.details = spec.6 }
                if existingLead.requiredPatterns.map(\.patternId) != req.map(\.patternId) {
                    existingLead.requiredPatterns = req
                }
                if existingLead.supportingPatterns.map(\.patternId) != sup.map(\.patternId) {
                    existingLead.supportingPatterns = sup
                }
                if existingLead.diagnosticIds != diags.map(\.diagnosticId) {
                    existingLead.diagnostics = diags
                    existingLead.diagnosticIds = diags.map(\.diagnosticId)
                }
                if !existingLead.isActive { existingLead.isActive = true }
            } else {
                let lead = OperationalLead(
                    leadId: spec.0,
                    name: spec.1,
                    category: spec.2,
                    details: spec.6,
                    requiredPatterns: req,
                    supportingPatterns: sup,
                    diagnostics: diags,
                    isActive: true
                )
                context.insert(lead)
                leadsById[spec.0] = lead
            }
        }

        try context.save()
    }
}
