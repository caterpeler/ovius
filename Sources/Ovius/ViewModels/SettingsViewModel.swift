import Foundation
import Observation

/// Coordinates AWS telemetry endpoint configuration (`NetworkManager`).
@MainActor
@Observable
public final class SettingsViewModel {
    private let networkManager: NetworkManager
    private let diskCache: TelemetryDiskCache

    // NetworkManager Configuration fields
    public var primaryBaseURLText: String = NetworkManager.Configuration.defaultCloudFrontURL.absoluteString
    public var fallbackBaseURLText: String = NetworkManager.Configuration.defaultAPIGatewayURL.absoluteString
    public var apiKeyText: String = ""
    public var requestTimeoutSeconds: Double = 30

    // Offline Telemetry Disk Cache Metrics
    public var diskCacheEnabled: Bool = true
    public var diskCacheFileCount: Int = 0
    public var diskCacheTotalBytes: Int64 = 0
    public var diskCachePath: String = ""

    // UI Status
    public var statusMessage: String?
    public var errorMessage: String?
    public var isTestingConnection: Bool = false
    public var connectionTestResult: String?

    public init(
        networkManager: NetworkManager? = nil,
        diskCache: TelemetryDiskCache? = nil
    ) {
        self.networkManager = networkManager ?? .shared
        self.diskCache = diskCache ?? .shared
    }

    public func load() async {
        errorMessage = nil
        let config = await networkManager.currentConfiguration()
        primaryBaseURLText = config.primaryBaseURL.absoluteString
        fallbackBaseURLText = config.fallbackBaseURL?.absoluteString ?? ""
        apiKeyText = config.apiKey ?? ""
        requestTimeoutSeconds = config.requestTimeoutSeconds
        refreshCacheStats()
    }

    public func refreshCacheStats() {
        diskCacheEnabled = diskCache.isEnabled
        diskCachePath = diskCache.storageDirectoryURL.path(percentEncoded: false)
        let stats = diskCache.cacheStats()
        diskCacheFileCount = stats.fileCount
        diskCacheTotalBytes = stats.totalBytes
    }

    public func clearDiskCache() {
        diskCache.clearAll()
        Task { await BoxTrackStore.shared.clearAll() }
        refreshCacheStats()
        statusMessage = "Cleared compressed offline telemetry cache and downloaded box tracks."
    }

    public func saveSettings() async {
        errorMessage = nil
        statusMessage = nil

        guard let primaryURL = URL(string: primaryBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              primaryURL.scheme?.hasPrefix("http") == true else {
            errorMessage = "Primary API URL must be a valid HTTP/HTTPS endpoint."
            return
        }

        let trimmedFallback = fallbackBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackURL: URL?
        if trimmedFallback.isEmpty {
            fallbackURL = nil
        } else if let parsed = URL(string: trimmedFallback), parsed.scheme?.hasPrefix("http") == true {
            fallbackURL = parsed
        } else {
            errorMessage = "Fallback API URL is invalid."
            return
        }

        let cleanedKey = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newConfig = NetworkManager.Configuration(
            primaryBaseURL: primaryURL,
            fallbackBaseURL: fallbackURL,
            apiKey: cleanedKey.isEmpty ? nil : cleanedKey,
            requestTimeoutSeconds: max(5, requestTimeoutSeconds)
        )
        await networkManager.configure(newConfig)
        statusMessage = "Saved AWS endpoint settings."
    }

    public func resetDefaults() async {
        primaryBaseURLText = NetworkManager.Configuration.defaultCloudFrontURL.absoluteString
        fallbackBaseURLText = NetworkManager.Configuration.defaultAPIGatewayURL.absoluteString
        apiKeyText = ""
        requestTimeoutSeconds = 30
        await saveSettings()
    }

    public func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        errorMessage = nil
        defer { isTestingConnection = false }

        do {
            let page = try await networkManager.fetchRecordingsPage(
                filters: TelemetryQueryFilters(limit: 1)
            )
            let sampleName = page.recordings.first?.filename ?? "none"
            connectionTestResult = "Connected cleanly (HTTP 200). Returned \(page.recordings.count) recording (\(sampleName))."
        } catch {
            errorMessage = "API check failed: \(error.localizedDescription)"
        }
    }
}
