import Foundation

// MARK: - Query Filters

/// Validated query filters matching `ovius_backend/src/ovius_api/filters.py`.
public struct TelemetryQueryFilters: Sendable, Equatable {
    public var startTime: String?
    public var endTime: String?
    public var cameraIds: [String]?
    public var recordingIds: [String]?
    public var locationTags: [String]?
    public var tags: [String]?
    public var filenames: [String]?
    public var states: [String]?
    public var cycleId: String?
    public var excavatorId: String?
    public var todStartS: Double?
    public var todEndS: Double?
    public var includeSegments: Bool?
    public var includeScoops: Bool?
    public var limit: Int?
    public var nextToken: String?

    public init(
        startTime: String? = nil,
        endTime: String? = nil,
        cameraIds: [String]? = nil,
        recordingIds: [String]? = nil,
        locationTags: [String]? = nil,
        tags: [String]? = nil,
        filenames: [String]? = nil,
        states: [String]? = nil,
        cycleId: String? = nil,
        excavatorId: String? = nil,
        todStartS: Double? = nil,
        todEndS: Double? = nil,
        includeSegments: Bool? = nil,
        includeScoops: Bool? = nil,
        limit: Int? = nil,
        nextToken: String? = nil
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.cameraIds = cameraIds
        self.recordingIds = recordingIds
        self.locationTags = locationTags
        self.tags = tags
        self.filenames = filenames
        self.states = states
        self.cycleId = cycleId
        self.excavatorId = excavatorId
        self.todStartS = todStartS
        self.todEndS = todEndS
        self.includeSegments = includeSegments
        self.includeScoops = includeScoops
        self.limit = limit
        self.nextToken = nextToken
    }

    /// Converts filters to query items expected by `/api/v1/*` endpoints.
    public func toQueryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []

        func appendIfPresent(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: value))
        }

        func appendList(_ name: String, _ values: [String]?) {
            guard let values, !values.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: values.joined(separator: ",")))
        }

        appendIfPresent("start_time", startTime)
        appendIfPresent("end_time", endTime)
        appendList("camera_id", cameraIds)
        appendList("recording_id", recordingIds)
        appendList("location_tag", locationTags)
        appendList("tag", tags)
        appendList("filename", filenames)
        appendList("state", states)
        appendIfPresent("cycle_id", cycleId)
        appendIfPresent("excavator_id", excavatorId)

        if let todStartS {
            items.append(URLQueryItem(name: "tod_start_s", value: String(todStartS)))
        }
        if let todEndS {
            items.append(URLQueryItem(name: "tod_end_s", value: String(todEndS)))
        }
        if let includeSegments {
            items.append(URLQueryItem(name: "include_segments", value: includeSegments ? "true" : "false"))
        }
        if let includeScoops {
            items.append(URLQueryItem(name: "include_scoops", value: includeScoops ? "true" : "false"))
        }
        if let limit {
            items.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        appendIfPresent("next_token", nextToken)

        return items
    }
}

// MARK: - Domain 1 Telemetry Entities (DynamoDB DTOs)

/// Recording item from `ovius-recording`.
public struct RecordingDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String { recordingId }

    public let recordingId: String
    public let filename: String
    public let timestamp: String
    public let cameraId: String
    public let locationTag: String
    public let durationS: Double
    public let fps: Double
    public let resolution: String
    public let tags: [String]

    /// Parses the recording start ISO-8601 timestamp into a `Date`.
    public var startDate: Date? {
        ISO8601TimestampParser.parse(timestamp)
    }

    public init(
        recordingId: String,
        filename: String,
        timestamp: String,
        cameraId: String,
        locationTag: String,
        durationS: Double,
        fps: Double,
        resolution: String,
        tags: [String] = []
    ) {
        self.recordingId = recordingId
        self.filename = filename
        self.timestamp = timestamp
        self.cameraId = cameraId
        self.locationTag = locationTag
        self.durationS = durationS
        self.fps = fps
        self.resolution = resolution
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingId = try container.decode(String.self, forKey: .recordingId)
        filename = try container.decode(String.self, forKey: .filename)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        cameraId = try container.decode(String.self, forKey: .cameraId)
        locationTag = try container.decode(String.self, forKey: .locationTag)
        durationS = try container.decode(Double.self, forKey: .durationS)
        fps = try container.decode(Double.self, forKey: .fps)
        resolution = try container.decode(String.self, forKey: .resolution)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

/// Embedded bucket pass timing inside `HaulCycleDTO`.
public struct ScoopTimingDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { scoopNumber }

    public let scoopNumber: Int
    public let excavatorSegmentId: String
    public let startS: Double
    public let dumpS: Double
    public let endS: Double
}

/// Discrete hauler loading visit from `ovius-haul-cycle`.
public struct HaulCycleDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String { cycleId }

    public let recordingId: String
    public let cycleId: String
    public let excavatorId: String
    public let excavatorSortKey: String?
    public let truckLabel: String
    public let cycleStatus: String
    public let tArriveS: Double?
    public let tSpotS: Double?
    public let tLoadStartS: Double?
    public let tLoadEndS: Double?
    public let tDepartS: Double?
    public let queueTimeS: Double?
    public let scoops: [ScoopTimingDTO]?
    public let truckSegments: [String]?

    /// Typed representation of `cycleStatus`, or `nil` for unrecognized values.
    public var typedStatus: CycleStatus? {
        CycleStatus(rawValue: cycleStatus)
    }
}

/// Continuous machine state interval from `ovius-state-segment`.
public struct StateSegmentDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String { segmentId }

    public let segmentId: String
    public let recordingId: String
    public let cycleId: String
    public let cycleSortKey: String?
    public let machineId: String
    public let scoopNumber: Int?
    public let state: String
    public let startS: Double
    public let endS: Double
    public let confidence: Double

    /// Typed representation of `state`, or `nil` for unrecognized values.
    public var typedState: MachineState? {
        MachineState(rawValue: state)
    }

    /// Segment duration in seconds.
    public var durationS: Double {
        max(0, endS - startS)
    }
}

// MARK: - Template Items

/// Future S3 Parquet bounding-box pointer returned by `GET /api/v1/bboxes`.
public struct BBoxTemplateItemDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String { recordingId }

    public let recordingId: String
    public let cameraId: String?
    public let timestamp: String?
    public let bboxArtifactUri: String
    public let presignedUrl: String?
}

/// Future CloudFront video stream pointer returned by `GET /api/v1/videos`.
public struct VideoTemplateItemDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String { recordingId }

    public let recordingId: String
    public let cameraId: String?
    public let filename: String?
    public let timestamp: String?
    public let durationS: Double?
    public let fps: Double?
    public let resolution: String?
    public let streamUrl: String
    public let signedCookiesRequired: Bool
}

// MARK: - API Response Envelopes

/// Pagination cursor & count metadata returned across `/api/v1/*` endpoints.
public struct PaginationDTO: Codable, Sendable, Equatable {
    public let count: Int?
    public let totalMatchedRecordings: Int?
    public let matchedRecordings: Int?
    public let recordingsCount: Int?
    public let haulCyclesCount: Int?
    public let stateSegmentsCount: Int?
    public let nextToken: String?
}

/// Response from `GET /api/v1/metrics`.
public struct MetricsBundleResponse: Codable, Sendable, Equatable {
    public let queryType: String
    public let recordings: [RecordingDTO]
    public let haulCycles: [HaulCycleDTO]
    public let stateSegments: [StateSegmentDTO]
    public let pagination: PaginationDTO
}

/// Response from `GET /api/v1/metrics/recordings`.
public struct RecordingsPageResponse: Codable, Sendable, Equatable {
    public let queryType: String
    public let recordings: [RecordingDTO]
    public let pagination: PaginationDTO
}

/// Response from `GET /api/v1/metrics/cycles`.
public struct CyclesPageResponse: Codable, Sendable, Equatable {
    public let queryType: String
    public let haulCycles: [HaulCycleDTO]
    public let pagination: PaginationDTO
}

/// Response from `GET /api/v1/metrics/segments`.
public struct SegmentsPageResponse: Codable, Sendable, Equatable {
    public let queryType: String
    public let stateSegments: [StateSegmentDTO]
    public let pagination: PaginationDTO
}

/// Generic template response envelope for `GET /api/v1/bboxes` and `GET /api/v1/videos`.
public struct TemplatePageResponse<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let queryType: String
    public let status: String
    public let items: [Item]
    public let pagination: PaginationDTO
}

/// Backend error body returned on HTTP 4xx/5xx responses.
public struct APIErrorResponse: Codable, Sendable, Equatable {
    public let error: String
    public let message: String?
    public let code: String?
}

// MARK: - Timestamp Utilities

private enum ISO8601TimestampParser {
    static func parse(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }
}
