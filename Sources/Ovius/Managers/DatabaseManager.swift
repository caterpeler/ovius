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

/// Singleton SwiftData manager owning Domain 2 (clusters and sections).
@MainActor @Observable
public final class DatabaseManager {
    public static let shared = DatabaseManager()
    public static let defaultMainClusterId = "CLUSTER_OPEN_PIT_MAIN"

    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }
    public private(set) var lastError: String?
    private let isDefaultPersistentStore: Bool

    public init(inMemory: Bool = false, storeURL: URL? = nil) {
        self.isDefaultPersistentStore = (!inMemory && storeURL == nil)
        let schema = Schema([
            Cluster.self,
            Section.self,
        ])

        do {
            let config: ModelConfiguration
            if inMemory {
                config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            } else if let storeURL {
                config = ModelConfiguration(schema: schema, url: storeURL)
            } else {
                config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            }
            self.container = try Self.makeContainerWithLegacyStoreRecovery(
                schema: schema,
                config: config,
                inMemory: inMemory
            )
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

    /// Opens the persistent SwiftData store, archiving an incompatible pre-trim store if schema recovery is required.
    private static func makeContainerWithLegacyStoreRecovery(
        schema: Schema,
        config: ModelConfiguration,
        inMemory: Bool
    ) throws -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            guard !inMemory else { throw error }
            let url = config.url
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else {
                throw error
            }
            let backupBase = "\(url.path).legacy-\(Int(Date().timeIntervalSince1970))"
            for suffix in ["", "-shm", "-wal"] {
                let src = URL(fileURLWithPath: url.path + suffix)
                let dst = URL(fileURLWithPath: backupBase + suffix)
                if fm.fileExists(atPath: src.path) {
                    try? fm.moveItem(at: src, to: dst)
                }
            }
            return try ModelContainer(for: schema, configurations: [config])
        }
    }

    // MARK: - Persistence Helpers

    public func save() throws {
        try context.save()
    }

    // MARK: - Domain 2: Clusters & Sections

    public func fetchClusters() throws -> [Cluster] {
        var descriptor = FetchDescriptor<Cluster>(
            sortBy: [
                SortDescriptor(\.createdAt, order: .forward),
                SortDescriptor(\.name, order: .forward),
            ]
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
        includeSegments: Bool? = nil,
        includeScoops: Bool? = false,
        limit: Int? = 15_000
    ) -> TelemetryQueryFilters {
        let allCameras = Array(Set(cluster.sections.flatMap(\.cameraIds))).sorted()
        return TelemetryQueryFilters(
            startTime: startTime,
            endTime: endTime,
            cameraIds: allCameras.isEmpty ? ["*"] : allCameras,
            includeSegments: includeSegments,
            includeScoops: includeScoops,
            limit: limit
        )
    }

    // MARK: - Idempotent Default Seeding

    private struct SectionSeedSpec {
        let suffix: String
        let mainSectionId: String
        let clusterId: String
        let clusterName: String
        let clusterOffsetSeconds: TimeInterval
        let name: String
        let cameraIds: [String]
        let locationTags: [String]
        let customTags: [String]
    }

    private static let defaultSectionSpecs: [SectionSeedSpec] = [
        SectionSeedSpec(
            suffix: "ALPHA",
            mainSectionId: "SEC_ALPHA",
            clusterId: "CLUSTER_A",
            clusterName: "Cluster A",
            clusterOffsetSeconds: 1,
            name: "Section Alpha",
            cameraIds: ["CAM-ALPHA-01", "CAM-ALPHA-02", "CAM-ALPHA-03"],
            locationTags: [
                "Section Alpha - Wide Overview Bench",
                "Section Alpha - Pit Lake Lower Bench",
                "Section Alpha - Pit Floor Loading Pocket",
            ],
            customTags: ["section:Alpha"]
        ),
        SectionSeedSpec(
            suffix: "BETA",
            mainSectionId: "SEC_BETA",
            clusterId: "CLUSTER_B",
            clusterName: "Cluster B",
            clusterOffsetSeconds: 2,
            name: "Section Beta",
            cameraIds: ["CAM-BETA-01", "CAM-BETA-02", "CAM-BETA-03", "CAM-BETA-04", "CAM-BETA-05"],
            locationTags: [
                "Section Beta - Highwall Haul Ramp Pocket",
                "Section Beta - Lower West Loading Bench",
                "Section Beta - Queue Bottleneck Bench",
                "Section Beta - Pit Z East Pocket",
                "Section Beta - Panoramic 4-Pocket Bench",
            ],
            customTags: ["section:Beta"]
        ),
        SectionSeedSpec(
            suffix: "GAMMA",
            mainSectionId: "SEC_GAMMA",
            clusterId: "CLUSTER_C",
            clusterName: "Cluster C",
            clusterOffsetSeconds: 3,
            name: "Section Gamma",
            cameraIds: ["CAM-GAMMA-01", "CAM-GAMMA-02", "CAM-GAMMA-03"],
            locationTags: [
                "Section Gamma - Dual-Truck Loading Pocket",
                "Section Gamma - Upper Spoil Berm Pocket",
                "Section Gamma - Dual-Shovel Production Bench",
            ],
            customTags: ["section:Gamma"]
        ),
    ]

    private static let mockClustersSeededDefaultsKey = "ovius.defaultClustersABCSeeded.v1"

    public func seedDefaultsIfNeeded() throws {
        try seedDefaultClustersIfNeeded()
    }

    private func seedDefaultClustersIfNeeded() throws {
        let count = try context.fetchCount(FetchDescriptor<Cluster>())
        if count == 0 {
            let baseCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let mainCluster = Cluster(
                clusterId: Self.defaultMainClusterId,
                name: "Open-Pit Site",
                createdAt: baseCreatedAt,
                tags: ["site:open-pit", "horizon:12h"]
            )
            context.insert(mainCluster)

            for spec in Self.defaultSectionSpecs {
                let mainSection = makeSection(sectionId: spec.mainSectionId, cluster: mainCluster, spec: spec)
                context.insert(mainSection)
            }

            insertSingleSectionClusters(baseCreatedAt: baseCreatedAt)
            try context.save()
            if isDefaultPersistentStore {
                UserDefaults.standard.set(true, forKey: Self.mockClustersSeededDefaultsKey)
            }
            return
        }

        // Upgrade pre-existing stores that only have the original `Open-Pit Site` cluster.
        if isDefaultPersistentStore && UserDefaults.standard.bool(forKey: Self.mockClustersSeededDefaultsKey) {
            return
        }
        guard let existingMain = try fetchCluster(clusterId: Self.defaultMainClusterId) else {
            return
        }
        let hasAnySectionCluster = try Self.defaultSectionSpecs.contains { spec in
            try fetchCluster(clusterId: spec.clusterId) != nil
        }
        guard !hasAnySectionCluster else {
            if isDefaultPersistentStore {
                UserDefaults.standard.set(true, forKey: Self.mockClustersSeededDefaultsKey)
            }
            return
        }

        insertSingleSectionClusters(baseCreatedAt: existingMain.createdAt)
        try context.save()
        if isDefaultPersistentStore {
            UserDefaults.standard.set(true, forKey: Self.mockClustersSeededDefaultsKey)
        }
    }

    private func insertSingleSectionClusters(baseCreatedAt: Date) {
        for spec in Self.defaultSectionSpecs {
            let cluster = Cluster(
                clusterId: spec.clusterId,
                name: spec.clusterName,
                createdAt: baseCreatedAt.addingTimeInterval(spec.clusterOffsetSeconds),
                tags: ["site:open-pit", "horizon:12h"] + spec.customTags
            )
            context.insert(cluster)

            let section = makeSection(
                sectionId: "SEC_\(spec.clusterId)_\(spec.suffix)",
                cluster: cluster,
                spec: spec
            )
            context.insert(section)
        }
    }

    private func makeSection(sectionId: String, cluster: Cluster, spec: SectionSeedSpec) -> Section {
        Section(
            sectionId: sectionId,
            clusterId: cluster.clusterId,
            name: spec.name,
            cameraIds: spec.cameraIds,
            locationTags: spec.locationTags,
            customTags: spec.customTags,
            cluster: cluster
        )
    }
}
