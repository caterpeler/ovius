import Foundation
import SwiftData

/// Top-level site or horizon grouping of operational sections (Domain 2).
@Model
public final class Cluster {
    @Attribute(.unique)
    public var clusterId: String

    public var name: String
    public var createdAt: Date
    public var tags: [String]

    // Optional performance targets (SLA). Each one set turns the dashboard's comparison to it on; with none set the
    // dashboard judges figures by their own spread.
    /// Least excavator EEU, in percent.
    public var targetExcavatorEEU: Double?
    /// Least truck EEU, in percent.
    public var targetTruckEEU: Double?
    /// Longest a truck should queue, in seconds.
    public var targetMaxQueueS: Double?
    /// Longest a cycle (arrival to departure) should take, in seconds.
    public var targetMaxCycleS: Double?

    @Relationship(deleteRule: .cascade, inverse: \Section.cluster)
    public var sections: [Section] = []

    public init(
        clusterId: String,
        name: String,
        createdAt: Date = .now,
        tags: [String] = []
    ) {
        self.clusterId = clusterId
        self.name = name
        self.createdAt = createdAt
        self.tags = tags
    }
}

extension Cluster {
    /// The cluster's targets, as the dashboard reads them.
    public var fleetTargets: FleetTargets {
        FleetTargets(excEEU: targetExcavatorEEU, truckEEU: targetTruckEEU, maxQueueS: targetMaxQueueS, maxCycleS: targetMaxCycleS)
    }

    func apply(_ t: FleetTargets) {
        targetExcavatorEEU = t.excEEU
        targetTruckEEU = t.truckEEU
        targetMaxQueueS = t.maxQueueS
        targetMaxCycleS = t.maxCycleS
    }
}

/// Logical mining zone whose recording selectors dynamically match cloud telemetry (Domain 2).
@Model
public final class Section {
    @Attribute(.unique)
    public var sectionId: String

    public var clusterId: String
    public var name: String
    public var filenames: [String]
    public var cameraIds: [String]
    public var locationTags: [String]
    public var customTags: [String]
    public var assignedTrucks: Int?

    public var cluster: Cluster?

    public init(
        sectionId: String,
        clusterId: String,
        name: String,
        filenames: [String] = [],
        cameraIds: [String] = [],
        locationTags: [String] = [],
        customTags: [String] = [],
        assignedTrucks: Int? = nil,
        cluster: Cluster? = nil
    ) {
        self.sectionId = sectionId
        self.clusterId = clusterId
        self.name = name
        self.filenames = filenames
        self.cameraIds = cameraIds
        self.locationTags = locationTags
        self.customTags = customTags
        self.assignedTrucks = assignedTrucks
        self.cluster = cluster
    }
}
