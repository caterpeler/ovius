import Foundation
import Observation

/// Coordinates Cluster & Section CRUD (`DatabaseManager`) and live selector verification (`NetworkManager`).
@MainActor
@Observable
public final class ClustersViewModel {
    private let databaseManager: DatabaseManager
    private let networkManager: NetworkManager

    public var clusters: [Cluster] = []
    public var selectedClusterId: String?
    public var selectedSectionId: String?

    public var previewRecordings: [RecordingDTO] = []
    public var isTestingSelector: Bool = false
    public var selectorTestMessage: String?
    public var errorMessage: String?

    public init(
        databaseManager: DatabaseManager? = nil,
        networkManager: NetworkManager? = nil
    ) {
        self.databaseManager = databaseManager ?? .shared
        self.networkManager = networkManager ?? .shared
    }

    public var selectedCluster: Cluster? {
        guard let selectedClusterId else { return clusters.first }
        return clusters.first { $0.clusterId == selectedClusterId } ?? clusters.first
    }

    public var sectionsInSelectedCluster: [Section] {
        guard let cluster = selectedCluster else { return [] }
        return cluster.sections.sorted { $0.sectionId < $1.sectionId }
    }

    public var selectedSection: Section? {
        let sections = sectionsInSelectedCluster
        if let selectedSectionId,
           let match = sections.first(where: { $0.sectionId == selectedSectionId }) {
            return match
        }
        return sections.first
    }

    public func reload() {
        errorMessage = nil
        do {
            clusters = try databaseManager.fetchClusters()
            if selectedClusterId == nil {
                selectedClusterId = clusters.first?.clusterId
            }
            if selectedSection == nil {
                selectedSectionId = sectionsInSelectedCluster.first?.sectionId
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func createOrUpdateCluster(clusterId: String, name: String, tagsText: String) {
        errorMessage = nil
        let cleanId = clusterId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty, !cleanName.isEmpty else {
            errorMessage = "Cluster ID and name are required."
            return
        }
        let tags = parseCSV(tagsText)
        do {
            let saved = try databaseManager.upsertCluster(clusterId: cleanId, name: cleanName, tags: tags)
            reload()
            selectedClusterId = saved.clusterId
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteCluster(_ cluster: Cluster) {
        errorMessage = nil
        do {
            try databaseManager.deleteCluster(cluster)
            if selectedClusterId == cluster.clusterId {
                selectedClusterId = nil
                selectedSectionId = nil
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func createOrUpdateSection(
        sectionId: String,
        clusterId: String,
        name: String,
        cameraIdsText: String,
        locationTagsText: String,
        customTagsText: String,
        filenamesText: String,
        assignedTrucksText: String
    ) {
        errorMessage = nil
        let cleanId = sectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty, !cleanName.isEmpty else {
            errorMessage = "Section ID and name are required."
            return
        }

        let trimmedTrucks = assignedTrucksText.trimmingCharacters(in: .whitespacesAndNewlines)
        let assignedTrucks: Int? = trimmedTrucks.isEmpty ? nil : Int(trimmedTrucks)
        if !trimmedTrucks.isEmpty && assignedTrucks == nil {
            errorMessage = "Assigned trucks must be a whole number or empty."
            return
        }

        do {
            let saved = try databaseManager.upsertSection(
                sectionId: cleanId,
                clusterId: clusterId,
                name: cleanName,
                filenames: parseCSV(filenamesText),
                cameraIds: parseCSV(cameraIdsText),
                locationTags: parseCSV(locationTagsText),
                customTags: parseCSV(customTagsText),
                assignedTrucks: assignedTrucks
            )
            reload()
            selectedClusterId = clusterId
            selectedSectionId = saved.sectionId
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteSection(_ section: Section) {
        errorMessage = nil
        do {
            try databaseManager.deleteSection(section)
            if selectedSectionId == section.sectionId {
                selectedSectionId = nil
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func testSectionSelector(_ section: Section) async {
        isTestingSelector = true
        selectorTestMessage = nil
        previewRecordings = []
        errorMessage = nil
        defer { isTestingSelector = false }

        let filters = databaseManager.makeFilters(
            for: section,
            startTime: "2020-01-01T00:00:00Z",
            endTime: OviusFormat.isoString(from: Date.now.addingTimeInterval(86_400)),
            limit: 25
        )
        do {
            let response = try await networkManager.fetchRecordingsPage(filters: filters)
            previewRecordings = response.recordings
            let total = response.pagination.totalMatchedRecordings ?? response.recordings.count
            selectorTestMessage = "Matched \(total) recordings in AWS DynamoDB (showing \(response.recordings.count))."
        } catch {
            errorMessage = "Selector preview failed: \(error.localizedDescription)"
        }
    }

    private func parseCSV(_ raw: String) -> [String] {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
