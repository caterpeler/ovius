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

/// Recording item from `ovius-recording` with parsed timestamp & display label cached at decode time.
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

    /// Parsed start date cached once at decode/init time instead of re-allocating formatters during SwiftUI renders.
    public let startDate: Date?
    /// Preformatted UTC date-time label (`yyyy-MM-dd HH:mm UTC`) for fast sidebar & table row rendering.
    public let formattedTimestampLabel: String

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case filename
        case timestamp
        case cameraId = "camera_id"
        case locationTag = "location_tag"
        case durationS = "duration_s"
        case fps
        case resolution
        case tags
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
        let parsed = OviusFormat.parseISODate(timestamp)
        self.startDate = parsed
        self.formattedTimestampLabel = parsed.map(OviusFormat.utcDateTime) ?? timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let recordingId = try container.decode(String.self, forKey: .recordingId)
        let filename = try container.decode(String.self, forKey: .filename)
        let timestamp = try container.decode(String.self, forKey: .timestamp)
        let cameraId = try container.decode(String.self, forKey: .cameraId)
        let locationTag = try container.decode(String.self, forKey: .locationTag)
        let durationS = try container.decode(Double.self, forKey: .durationS)
        let fps = try container.decode(Double.self, forKey: .fps)
        let resolution = try container.decode(String.self, forKey: .resolution)
        let tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.init(
            recordingId: recordingId,
            filename: filename,
            timestamp: timestamp,
            cameraId: cameraId,
            locationTag: locationTag,
            durationS: durationS,
            fps: fps,
            resolution: resolution,
            tags: tags
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordingId, forKey: .recordingId)
        try container.encode(filename, forKey: .filename)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(cameraId, forKey: .cameraId)
        try container.encode(locationTag, forKey: .locationTag)
        try container.encode(durationS, forKey: .durationS)
        try container.encode(fps, forKey: .fps)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(tags, forKey: .tags)
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

    private enum CodingKeys: String, CodingKey {
        case scoopNumber = "scoop_number"
        case excavatorSegmentId = "excavator_segment_id"
        case startS = "start_s"
        case dumpS = "dump_s"
        case endS = "end_s"
    }

    public init(
        scoopNumber: Int,
        excavatorSegmentId: String,
        startS: Double,
        dumpS: Double,
        endS: Double
    ) {
        self.scoopNumber = scoopNumber
        self.excavatorSegmentId = excavatorSegmentId
        self.startS = startS
        self.dumpS = dumpS
        self.endS = endS
    }
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

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case cycleId = "cycle_id"
        case excavatorId = "excavator_id"
        case excavatorSortKey = "excavator_sort_key"
        case truckLabel = "truck_label"
        case cycleStatus = "cycle_status"
        case tArriveS = "t_arrive_s"
        case tSpotS = "t_spot_s"
        case tLoadStartS = "t_load_start_s"
        case tLoadEndS = "t_load_end_s"
        case tDepartS = "t_depart_s"
        case queueTimeS = "queue_time_s"
        case scoops
        case truckSegments = "truck_segments"
    }

    public init(
        recordingId: String,
        cycleId: String,
        excavatorId: String,
        excavatorSortKey: String?,
        truckLabel: String,
        cycleStatus: String,
        tArriveS: Double?,
        tSpotS: Double?,
        tLoadStartS: Double?,
        tLoadEndS: Double?,
        tDepartS: Double?,
        queueTimeS: Double?,
        scoops: [ScoopTimingDTO]?,
        truckSegments: [String]?
    ) {
        self.recordingId = recordingId
        self.cycleId = cycleId
        self.excavatorId = excavatorId
        self.excavatorSortKey = excavatorSortKey
        self.truckLabel = truckLabel
        self.cycleStatus = cycleStatus
        self.tArriveS = tArriveS
        self.tSpotS = tSpotS
        self.tLoadStartS = tLoadStartS
        self.tLoadEndS = tLoadEndS
        self.tDepartS = tDepartS
        self.queueTimeS = queueTimeS
        self.scoops = scoops
        self.truckSegments = truckSegments
    }

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

    private enum CodingKeys: String, CodingKey {
        case segmentId = "segment_id"
        case recordingId = "recording_id"
        case cycleId = "cycle_id"
        case cycleSortKey = "cycle_sort_key"
        case machineId = "machine_id"
        case scoopNumber = "scoop_number"
        case state
        case startS = "start_s"
        case endS = "end_s"
        case confidence
    }

    public init(
        segmentId: String,
        recordingId: String,
        cycleId: String,
        cycleSortKey: String?,
        machineId: String,
        scoopNumber: Int?,
        state: String,
        startS: Double,
        endS: Double,
        confidence: Double
    ) {
        self.segmentId = segmentId
        self.recordingId = recordingId
        self.cycleId = cycleId
        self.cycleSortKey = cycleSortKey
        self.machineId = machineId
        self.scoopNumber = scoopNumber
        self.state = state
        self.startS = startS
        self.endS = endS
        self.confidence = confidence
    }

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

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case cameraId = "camera_id"
        case timestamp
        case bboxArtifactUri = "bbox_artifact_uri"
        case presignedUrl = "presigned_url"
    }
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

    private enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id"
        case cameraId = "camera_id"
        case filename
        case timestamp
        case durationS = "duration_s"
        case fps
        case resolution
        case streamUrl = "stream_url"
        case signedCookiesRequired = "signed_cookies_required"
    }
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

    private enum CodingKeys: String, CodingKey {
        case count
        case totalMatchedRecordings = "total_matched_recordings"
        case matchedRecordings = "matched_recordings"
        case recordingsCount = "recordings_count"
        case haulCyclesCount = "haul_cycles_count"
        case stateSegmentsCount = "state_segments_count"
        case nextToken = "next_token"
    }

    public init(
        count: Int?,
        totalMatchedRecordings: Int?,
        matchedRecordings: Int?,
        recordingsCount: Int?,
        haulCyclesCount: Int?,
        stateSegmentsCount: Int?,
        nextToken: String?
    ) {
        self.count = count
        self.totalMatchedRecordings = totalMatchedRecordings
        self.matchedRecordings = matchedRecordings
        self.recordingsCount = recordingsCount
        self.haulCyclesCount = haulCyclesCount
        self.stateSegmentsCount = stateSegmentsCount
        self.nextToken = nextToken
    }
}

/// Response from `GET /api/v1/metrics`.
public struct MetricsBundleResponse: Codable, Sendable, Equatable {
    public let queryType: String
    public let recordings: [RecordingDTO]
    public let haulCycles: [HaulCycleDTO]
    public let stateSegments: [StateSegmentDTO]
    public let pagination: PaginationDTO

    private enum CodingKeys: String, CodingKey {
        case queryType = "query_type"
        case recordings
        case haulCycles = "haul_cycles"
        case stateSegments = "state_segments"
        case pagination
    }

    public init(
        queryType: String,
        recordings: [RecordingDTO],
        haulCycles: [HaulCycleDTO],
        stateSegments: [StateSegmentDTO],
        pagination: PaginationDTO
    ) {
        self.queryType = queryType
        self.recordings = recordings
        self.haulCycles = haulCycles
        self.stateSegments = stateSegments
        self.pagination = pagination
    }
}

/// Response from `GET /api/v1/metrics/recordings`.
public struct RecordingsPageResponse: Codable, Sendable, Equatable {
    public let queryType: String
    public let recordings: [RecordingDTO]
    public let pagination: PaginationDTO

    private enum CodingKeys: String, CodingKey {
        case queryType = "query_type"
        case recordings
        case pagination
    }
}

/// Response from `GET /api/v1/metrics/cycles`.
public struct CyclesPageResponse: Codable, Sendable, Equatable {
    public let queryType: String
    public let haulCycles: [HaulCycleDTO]
    public let pagination: PaginationDTO

    private enum CodingKeys: String, CodingKey {
        case queryType = "query_type"
        case haulCycles = "haul_cycles"
        case pagination
    }
}

/// Response from `GET /api/v1/metrics/segments`.
public struct SegmentsPageResponse: Codable, Sendable, Equatable {
    public let queryType: String
    public let stateSegments: [StateSegmentDTO]
    public let pagination: PaginationDTO

    private enum CodingKeys: String, CodingKey {
        case queryType = "query_type"
        case stateSegments = "state_segments"
        case pagination
    }
}

/// Generic template response envelope for `GET /api/v1/bboxes` and `GET /api/v1/videos`.
public struct TemplatePageResponse<Item: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let queryType: String
    public let status: String
    public let items: [Item]
    public let pagination: PaginationDTO

    private enum CodingKeys: String, CodingKey {
        case queryType = "query_type"
        case status
        case items
        case pagination
    }
}

/// Backend error body returned on HTTP 4xx/5xx responses.
public struct APIErrorResponse: Codable, Sendable, Equatable {
    public let error: String
    public let message: String?
    public let code: String?
}
