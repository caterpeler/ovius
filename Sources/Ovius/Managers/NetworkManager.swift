import Foundation

/// Typed errors produced by `NetworkManager` when calling the Ovius AWS telemetry API.
public enum NetworkError: LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case invalidQuery(String)
    case badRequest(String)
    case upstreamError(code: String, statusCode: Int)
    case httpError(statusCode: Int, message: String)
    case invalidResponse
    case decodingFailed(String)
    case paginationLoopDetected

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            "Invalid API URL: \(raw)"
        case .invalidQuery(let message):
            "Invalid query filters: \(message)"
        case .badRequest(let message):
            "Bad API request: \(message)"
        case .upstreamError(let code, let statusCode):
            "Upstream DynamoDB error (\(code), HTTP \(statusCode))."
        case .httpError(let statusCode, let message):
            message.isEmpty ? "HTTP error \(statusCode)." : "HTTP \(statusCode): \(message)"
        case .invalidResponse:
            "Received a non-HTTP response from the telemetry API."
        case .decodingFailed(let detail):
            "Failed to decode telemetry response: \(detail)"
        case .paginationLoopDetected:
            "Pagination halted because the backend returned a repeated cursor token."
        }
    }
}

/// Singleton network entry point interfacing with the Ovius CloudFront -> API Gateway -> Lambda backend.
/// Snapshot config is read cleanly on the actor while HTTP execution & JSON decoding run in parallel off-actor.
public actor NetworkManager {
    public static let shared = NetworkManager()

    public struct Configuration: Sendable, Equatable {
        public static let defaultCloudFrontURL = URL(string: "https://d1zj4agypqh81v.cloudfront.net/api/v1")!
        public static let defaultAPIGatewayURL = URL(string: "https://4jg1b9qut2.execute-api.ap-southeast-3.amazonaws.com/v1/api/v1")!
        public static let maxPageLimit = 15_000

        public var primaryBaseURL: URL
        public var fallbackBaseURL: URL?
        public var apiKey: String?
        public var requestTimeoutSeconds: TimeInterval

        public init(
            primaryBaseURL: URL = Configuration.defaultCloudFrontURL,
            fallbackBaseURL: URL? = Configuration.defaultAPIGatewayURL,
            apiKey: String? = nil,
            requestTimeoutSeconds: TimeInterval = 30
        ) {
            self.primaryBaseURL = primaryBaseURL
            self.fallbackBaseURL = fallbackBaseURL
            self.apiKey = apiKey
            self.requestTimeoutSeconds = requestTimeoutSeconds
        }

        public static var `default`: Configuration {
            let env = ProcessInfo.processInfo.environment
            let primary: URL
            let fallback: URL?
            if let overrideRaw = env["OVIUS_API_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !overrideRaw.isEmpty,
               let overrideURL = URL(string: overrideRaw) {
                primary = overrideURL
                fallback = nil
            } else {
                primary = defaultCloudFrontURL
                fallback = defaultAPIGatewayURL
            }

            let rawKey = env["OVIUS_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiKey = (rawKey?.isEmpty == false) ? rawKey : nil

            return Configuration(
                primaryBaseURL: primary,
                fallbackBaseURL: fallback,
                apiKey: apiKey,
                requestTimeoutSeconds: 30
            )
        }
    }

    private let session: URLSession
    private var configuration: Configuration

    public init(
        session: URLSession? = nil,
        configuration: Configuration = .default
    ) {
        self.session = session ?? Self.makeOptimizedSession()
        self.configuration = configuration
    }

    private static func makeOptimizedSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 12
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    /// Updates endpoint base URLs or optional `x-api-key` authentication at runtime.
    public func configure(_ newConfiguration: Configuration) {
        self.configuration = newConfiguration
    }

    /// Returns the active endpoint and header configuration.
    public func currentConfiguration() -> Configuration {
        configuration
    }

    // MARK: - Single-Page Endpoints

    /// Fetches one page from `GET /api/v1/metrics` (composite recordings, haul_cycles, optional state_segments).
    public func fetchMetricsPage(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> MetricsBundleResponse {
        let config = configuration
        return try await Self.requestNonisolated(path: "metrics", filters: filters, session: session, configuration: config)
    }

    /// Fetches one page from `GET /api/v1/metrics/recordings`.
    public func fetchRecordingsPage(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> RecordingsPageResponse {
        let config = configuration
        return try await Self.requestNonisolated(path: "metrics/recordings", filters: filters, session: session, configuration: config)
    }

    /// Fetches one page from `GET /api/v1/metrics/cycles`.
    public func fetchCyclesPage(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> CyclesPageResponse {
        let config = configuration
        return try await Self.requestNonisolated(path: "metrics/cycles", filters: filters, session: session, configuration: config)
    }

    /// Fetches one page from `GET /api/v1/metrics/segments`.
    public func fetchSegmentsPage(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> SegmentsPageResponse {
        let config = configuration
        return try await Self.requestNonisolated(path: "metrics/segments", filters: filters, session: session, configuration: config)
    }

    /// Fetches bounding-box track template pointers from `GET /api/v1/bboxes`.
    public func fetchBBoxesTemplate(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> TemplatePageResponse<BBoxTemplateItemDTO> {
        let config = configuration
        return try await Self.requestNonisolated(path: "bboxes", filters: filters, session: session, configuration: config)
    }

    /// Fetches video stream template pointers from `GET /api/v1/videos`.
    public func fetchVideosTemplate(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> TemplatePageResponse<VideoTemplateItemDTO> {
        let config = configuration
        return try await Self.requestNonisolated(path: "videos", filters: filters, session: session, configuration: config)
    }

    // MARK: - Parallel Cursor-Paginated Fetches (Off-Actor)

    /// Fetches `haul_cycles` (`include_scoops=true`) and `state_segments` in parallel for a single recording.
    public func fetchRecordingCyclesAndSegments(
        recordingId: String,
        durationS: Double,
        maxPages: Int = 12
    ) async throws -> (cycles: [HaulCycleDTO], segments: [StateSegmentDTO], truncated: Bool) {
        let config = configuration
        let sessionRef = session
        let todEnd = max(43_200.0, durationS)

        let cycleFilters = TelemetryQueryFilters(
            recordingIds: [recordingId],
            todEndS: todEnd,
            includeScoops: true,
            limit: 15_000
        )
        let segmentFilters = TelemetryQueryFilters(
            recordingIds: [recordingId],
            todEndS: todEnd,
            limit: 15_000
        )

        async let cyclesTask = Self.fetchAllCyclesNonisolated(
            filters: cycleFilters,
            maxPages: maxPages,
            session: sessionRef,
            configuration: config
        )
        async let segmentsTask = Self.fetchAllSegmentsNonisolated(
            filters: segmentFilters,
            maxPages: maxPages,
            session: sessionRef,
            configuration: config
        )

        let cycRes = try await cyclesTask
        let segRes = try await segmentsTask
        return (cycRes.items, segRes.items, cycRes.hitPageCap || segRes.hitPageCap)
    }

    /// Automatically drains all `next_token` pages for `GET /api/v1/metrics`.
    public func fetchAllMetrics(
        filters: TelemetryQueryFilters = TelemetryQueryFilters(),
        maxPages: Int? = nil
    ) async throws -> MetricsBundleResponse {
        let config = configuration
        let sessionRef = session
        var recordings: [RecordingDTO] = []
        var seenRecordingIds: Set<String> = []
        var cycles: [HaulCycleDTO] = []
        var segments: [StateSegmentDTO] = []
        var lastPagination = PaginationDTO(
            count: nil,
            totalMatchedRecordings: nil,
            matchedRecordings: 0,
            recordingsCount: 0,
            haulCyclesCount: 0,
            stateSegmentsCount: 0,
            nextToken: nil
        )
        var queryType = "metrics"

        try await Self.collectAllPages(
            initialFilters: filters,
            maxPages: maxPages,
            fetchPage: { pageFilters in
                try await Self.requestNonisolated(
                    path: "metrics",
                    filters: pageFilters,
                    session: sessionRef,
                    configuration: config
                )
            },
            nextTokenOf: { (page: MetricsBundleResponse) in page.pagination.nextToken },
            onPage: { _, page in
                queryType = page.queryType
                for rec in page.recordings where seenRecordingIds.insert(rec.recordingId).inserted {
                    recordings.append(rec)
                }
                cycles.append(contentsOf: page.haulCycles)
                segments.append(contentsOf: page.stateSegments)
                lastPagination = page.pagination
            }
        )

        return MetricsBundleResponse(
            queryType: queryType,
            recordings: recordings,
            haulCycles: cycles,
            stateSegments: segments,
            pagination: PaginationDTO(
                count: nil,
                totalMatchedRecordings: lastPagination.totalMatchedRecordings,
                matchedRecordings: lastPagination.matchedRecordings,
                recordingsCount: recordings.count,
                haulCyclesCount: cycles.count,
                stateSegmentsCount: segments.count,
                nextToken: lastPagination.nextToken
            )
        )
    }

    /// Automatically drains all `next_token` pages for `GET /api/v1/metrics/recordings`.
    public func fetchAllRecordings(
        filters: TelemetryQueryFilters = TelemetryQueryFilters(),
        maxPages: Int? = nil
    ) async throws -> [RecordingDTO] {
        try await fetchAllRecordingsWithStatus(filters: filters, maxPages: maxPages).items
    }

    /// Drains `GET /api/v1/metrics/recordings` pages and reports whether `maxPages` clipped an active `next_token`.
    public func fetchAllRecordingsWithStatus(
        filters: TelemetryQueryFilters = TelemetryQueryFilters(),
        maxPages: Int? = nil
    ) async throws -> (items: [RecordingDTO], hitPageCap: Bool) {
        let config = configuration
        let sessionRef = session
        var collected: [RecordingDTO] = []
        let hitCap = try await Self.collectAllPages(
            initialFilters: filters,
            maxPages: maxPages,
            fetchPage: { pageFilters in
                try await Self.requestNonisolated(
                    path: "metrics/recordings",
                    filters: pageFilters,
                    session: sessionRef,
                    configuration: config
                )
            },
            nextTokenOf: { (page: RecordingsPageResponse) in page.pagination.nextToken },
            onPage: { _, page in
                collected.append(contentsOf: page.recordings)
            }
        )
        return (collected, hitCap)
    }

    /// Automatically drains all `next_token` pages for `GET /api/v1/metrics/cycles`.
    public func fetchAllCycles(
        filters: TelemetryQueryFilters = TelemetryQueryFilters(),
        maxPages: Int? = nil
    ) async throws -> [HaulCycleDTO] {
        try await fetchAllCyclesWithStatus(filters: filters, maxPages: maxPages).items
    }

    /// Drains `GET /api/v1/metrics/cycles` pages and reports whether `maxPages` clipped an active `next_token`.
    public func fetchAllCyclesWithStatus(
        filters: TelemetryQueryFilters = TelemetryQueryFilters(),
        maxPages: Int? = nil
    ) async throws -> (items: [HaulCycleDTO], hitPageCap: Bool) {
        let config = configuration
        return try await Self.fetchAllCyclesNonisolated(
            filters: filters,
            maxPages: maxPages,
            session: session,
            configuration: config
        )
    }

    /// Automatically drains all `next_token` pages for `GET /api/v1/metrics/segments`.
    public func fetchAllSegments(
        filters: TelemetryQueryFilters = TelemetryQueryFilters(),
        maxPages: Int? = nil
    ) async throws -> [StateSegmentDTO] {
        try await fetchAllSegmentsWithStatus(filters: filters, maxPages: maxPages).items
    }

    /// Drains `GET /api/v1/metrics/segments` pages and reports whether `maxPages` clipped an active `next_token`.
    public func fetchAllSegmentsWithStatus(
        filters: TelemetryQueryFilters = TelemetryQueryFilters(),
        maxPages: Int? = nil
    ) async throws -> (items: [StateSegmentDTO], hitPageCap: Bool) {
        let config = configuration
        return try await Self.fetchAllSegmentsNonisolated(
            filters: filters,
            maxPages: maxPages,
            session: session,
            configuration: config
        )
    }

    // MARK: - Nonisolated Parallel HTTP & Decoding Helpers

    private nonisolated static func fetchAllCyclesNonisolated(
        filters: TelemetryQueryFilters,
        maxPages: Int?,
        session: URLSession,
        configuration: Configuration
    ) async throws -> (items: [HaulCycleDTO], hitPageCap: Bool) {
        var collected: [HaulCycleDTO] = []
        let hitCap = try await collectAllPages(
            initialFilters: filters,
            maxPages: maxPages,
            fetchPage: { pageFilters in
                try await requestNonisolated(
                    path: "metrics/cycles",
                    filters: pageFilters,
                    session: session,
                    configuration: configuration
                )
            },
            nextTokenOf: { (page: CyclesPageResponse) in page.pagination.nextToken },
            onPage: { _, page in
                collected.append(contentsOf: page.haulCycles)
            }
        )
        return (collected, hitCap)
    }

    private nonisolated static func fetchAllSegmentsNonisolated(
        filters: TelemetryQueryFilters,
        maxPages: Int?,
        session: URLSession,
        configuration: Configuration
    ) async throws -> (items: [StateSegmentDTO], hitPageCap: Bool) {
        var collected: [StateSegmentDTO] = []
        let hitCap = try await collectAllPages(
            initialFilters: filters,
            maxPages: maxPages,
            fetchPage: { pageFilters in
                try await requestNonisolated(
                    path: "metrics/segments",
                    filters: pageFilters,
                    session: session,
                    configuration: configuration
                )
            },
            nextTokenOf: { (page: SegmentsPageResponse) in page.pagination.nextToken },
            onPage: { _, page in
                collected.append(contentsOf: page.stateSegments)
            }
        )
        return (collected, hitCap)
    }

    @discardableResult
    private nonisolated static func collectAllPages<Page>(
        initialFilters: TelemetryQueryFilters,
        maxPages: Int?,
        fetchPage: (TelemetryQueryFilters) async throws -> Page,
        nextTokenOf: (Page) -> String?,
        onPage: (Int, Page) -> Void
    ) async throws -> Bool {
        var currentFilters = initialFilters
        var seenTokens: Set<String> = []
        var pageIndex = 0

        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(currentFilters)
            onPage(pageIndex, page)

            guard let token = nextTokenOf(page), !token.isEmpty else {
                return false
            }
            if let maxPages, pageIndex + 1 >= maxPages {
                return true
            }
            if !seenTokens.insert(token).inserted {
                throw NetworkError.paginationLoopDetected
            }

            currentFilters.nextToken = token
            pageIndex += 1
        }
    }

    private nonisolated static func requestNonisolated<Response: Decodable & Sendable>(
        path: String,
        filters: TelemetryQueryFilters,
        session: URLSession,
        configuration: Configuration
    ) async throws -> Response {
        try validate(filters)

        let primaryURL = try buildURL(baseURL: configuration.primaryBaseURL, path: path, filters: filters)
        do {
            return try await execute(url: primaryURL, session: session, configuration: configuration)
        } catch let error as NetworkError {
            guard shouldRetryOnFallback(for: error),
                  let fallbackBase = configuration.fallbackBaseURL,
                  fallbackBase != configuration.primaryBaseURL else {
                throw error
            }
            let fallbackURL = try buildURL(baseURL: fallbackBase, path: path, filters: filters)
            return try await execute(url: fallbackURL, session: session, configuration: configuration)
        } catch {
            if error is CancellationError {
                throw error
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            guard let fallbackBase = configuration.fallbackBaseURL,
                  fallbackBase != configuration.primaryBaseURL else {
                throw error
            }
            let fallbackURL = try buildURL(baseURL: fallbackBase, path: path, filters: filters)
            return try await execute(url: fallbackURL, session: session, configuration: configuration)
        }
    }

    private nonisolated static func shouldRetryOnFallback(for error: NetworkError) -> Bool {
        switch error {
        case .upstreamError, .invalidResponse:
            true
        case .httpError(let statusCode, _):
            statusCode >= 500
        case .invalidURL, .invalidQuery, .badRequest, .decodingFailed, .paginationLoopDetected:
            false
        }
    }

    private nonisolated static func validate(_ filters: TelemetryQueryFilters) throws {
        if let limit = filters.limit, !(1...Configuration.maxPageLimit).contains(limit) {
            throw NetworkError.invalidQuery("limit must be between 1 and \(Configuration.maxPageLimit).")
        }
        if let todStart = filters.todStartS, todStart < 0 {
            throw NetworkError.invalidQuery("tod_start_s must be >= 0.")
        }
        if let todEnd = filters.todEndS, todEnd < 0 {
            throw NetworkError.invalidQuery("tod_end_s must be >= 0.")
        }
        if let todStart = filters.todStartS, let todEnd = filters.todEndS, todStart > todEnd {
            throw NetworkError.invalidQuery("tod_start_s must be <= tod_end_s.")
        }
    }

    private nonisolated static func buildURL(baseURL: URL, path: String, filters: TelemetryQueryFilters) throws -> URL {
        let endpointURL = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL(endpointURL.absoluteString)
        }
        let queryItems = filters.toQueryItems()
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let finalURL = components.url else {
            throw NetworkError.invalidURL(endpointURL.absoluteString)
        }
        return finalURL
    }

    private nonisolated static func execute<Response: Decodable & Sendable>(
        url: URL,
        session: URLSession,
        configuration: Configuration
    ) async throws -> Response {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = configuration.requestTimeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw mapHTTPError(statusCode: httpResponse.statusCode, data: data)
        }

        return try await Task.detached(priority: .userInitiated) {
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw NetworkError.decodingFailed(error.localizedDescription)
            }
        }.value
    }

    private nonisolated static func mapHTTPError(statusCode: Int, data: Data) -> NetworkError {
        if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            if statusCode == 400 {
                return .badRequest(apiError.message ?? apiError.error)
            }
            if statusCode == 502, let code = apiError.code {
                return .upstreamError(code: code, statusCode: statusCode)
            }
            return .httpError(statusCode: statusCode, message: apiError.message ?? apiError.error)
        }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .httpError(statusCode: statusCode, message: raw)
    }
}
