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
    private let decoder: JSONDecoder

    public init(
        session: URLSession = .shared,
        configuration: Configuration = .default
    ) {
        self.session = session
        self.configuration = configuration

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
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
        try await request(path: "metrics", filters: filters)
    }

    /// Fetches one page from `GET /api/v1/metrics/recordings`.
    public func fetchRecordingsPage(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> RecordingsPageResponse {
        try await request(path: "metrics/recordings", filters: filters)
    }

    /// Fetches one page from `GET /api/v1/metrics/cycles`.
    public func fetchCyclesPage(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> CyclesPageResponse {
        try await request(path: "metrics/cycles", filters: filters)
    }

    /// Fetches one page from `GET /api/v1/metrics/segments`.
    public func fetchSegmentsPage(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> SegmentsPageResponse {
        try await request(path: "metrics/segments", filters: filters)
    }

    /// Fetches bounding-box track template pointers from `GET /api/v1/bboxes`.
    public func fetchBBoxesTemplate(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> TemplatePageResponse<BBoxTemplateItemDTO> {
        try await request(path: "bboxes", filters: filters)
    }

    /// Fetches video stream template pointers from `GET /api/v1/videos`.
    public func fetchVideosTemplate(filters: TelemetryQueryFilters = TelemetryQueryFilters()) async throws -> TemplatePageResponse<VideoTemplateItemDTO> {
        try await request(path: "videos", filters: filters)
    }

    // MARK: - Cursor-Paginated Full Fetches

    /// Automatically drains all `next_token` pages for `GET /api/v1/metrics`.
    public func fetchAllMetrics(
        filters: TelemetryQueryFilters = TelemetryQueryFilters(),
        maxPages: Int? = nil
    ) async throws -> MetricsBundleResponse {
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

        try await collectAllPages(
            initialFilters: filters,
            maxPages: maxPages,
            fetchPage: { try await fetchMetricsPage(filters: $0) },
            nextTokenOf: { $0.pagination.nextToken },
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
        var collected: [RecordingDTO] = []
        let hitCap = try await collectAllPages(
            initialFilters: filters,
            maxPages: maxPages,
            fetchPage: { try await fetchRecordingsPage(filters: $0) },
            nextTokenOf: { $0.pagination.nextToken },
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
        var collected: [HaulCycleDTO] = []
        let hitCap = try await collectAllPages(
            initialFilters: filters,
            maxPages: maxPages,
            fetchPage: { try await fetchCyclesPage(filters: $0) },
            nextTokenOf: { $0.pagination.nextToken },
            onPage: { _, page in
                collected.append(contentsOf: page.haulCycles)
            }
        )
        return (collected, hitCap)
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
        var collected: [StateSegmentDTO] = []
        let hitCap = try await collectAllPages(
            initialFilters: filters,
            maxPages: maxPages,
            fetchPage: { try await fetchSegmentsPage(filters: $0) },
            nextTokenOf: { $0.pagination.nextToken },
            onPage: { _, page in
                collected.append(contentsOf: page.stateSegments)
            }
        )
        return (collected, hitCap)
    }

    // MARK: - Internal Helpers

    @discardableResult
    private func collectAllPages<Page>(
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

    private func request<Response: Decodable>(
        path: String,
        filters: TelemetryQueryFilters
    ) async throws -> Response {
        try validate(filters)

        let primaryURL = try buildURL(baseURL: configuration.primaryBaseURL, path: path, filters: filters)
        do {
            return try await execute(url: primaryURL)
        } catch let error as NetworkError {
            guard shouldRetryOnFallback(for: error),
                  let fallbackBase = configuration.fallbackBaseURL,
                  fallbackBase != configuration.primaryBaseURL else {
                throw error
            }
            let fallbackURL = try buildURL(baseURL: fallbackBase, path: path, filters: filters)
            return try await execute(url: fallbackURL)
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
            return try await execute(url: fallbackURL)
        }
    }

    private func shouldRetryOnFallback(for error: NetworkError) -> Bool {
        switch error {
        case .upstreamError, .invalidResponse:
            true
        case .httpError(let statusCode, _):
            statusCode >= 500
        case .invalidURL, .invalidQuery, .badRequest, .decodingFailed, .paginationLoopDetected:
            false
        }
    }

    private func validate(_ filters: TelemetryQueryFilters) throws {
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

    private func buildURL(baseURL: URL, path: String, filters: TelemetryQueryFilters) throws -> URL {
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

    private func execute<Response: Decodable>(url: URL) async throws -> Response {
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

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw NetworkError.decodingFailed(error.localizedDescription)
        }
    }

    private func mapHTTPError(statusCode: Int, data: Data) -> NetworkError {
        if let apiError = try? decoder.decode(APIErrorResponse.self, from: data) {
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
