import Foundation
import SwiftData

/// Client-side mathematical, operational allowance, and shift-schedule constants (Domain 2).
@Model
public final class AppSettings {
    @Attribute(.unique)
    public var settingsId: String

    public var meanPayloadM3: Double
    public var struckPayloadM3: Double
    public var heapedPayloadM3: Double
    public var idleThresholdS: Int
    public var shiftEdgeWindowMin: Int
    public var shiftStartHours: [String]
    public var breakWindows: [String]
    public var updatedAt: Date

    public init(
        settingsId: String = "default",
        meanPayloadM3: Double = 51.1,
        struckPayloadM3: Double = 42.1,
        heapedPayloadM3: Double = 60.1,
        idleThresholdS: Int = 300,
        shiftEdgeWindowMin: Int = 60,
        shiftStartHours: [String] = ["06:00"],
        breakWindows: [String] = ["12:00-13:00"],
        updatedAt: Date = .now
    ) {
        self.settingsId = settingsId
        self.meanPayloadM3 = meanPayloadM3
        self.struckPayloadM3 = struckPayloadM3
        self.heapedPayloadM3 = heapedPayloadM3
        self.idleThresholdS = idleThresholdS
        self.shiftEdgeWindowMin = shiftEdgeWindowMin
        self.shiftStartHours = shiftStartHours
        self.breakWindows = breakWindows
        self.updatedAt = updatedAt
    }
}

/// Top-level site or horizon grouping of operational sections (Domain 2).
@Model
public final class Cluster {
    @Attribute(.unique)
    public var clusterId: String

    public var name: String
    public var createdAt: Date
    public var tags: [String]

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
