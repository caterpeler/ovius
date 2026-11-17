import Foundation
import Observation

/// Coordinates client-side `AppSettings` (`DatabaseManager`) and AWS endpoint config (`NetworkManager`).
@MainActor
@Observable
public final class SettingsViewModel {
    private let databaseManager: DatabaseManager
    private let networkManager: NetworkManager

    // Domain 2: AppSettings fields
    public var meanPayloadM3: Double = 51.1
    public var struckPayloadM3: Double = 42.1
    public var heapedPayloadM3: Double = 60.1
    public var idleThresholdS: Int = 300
    public var shiftEdgeWindowMin: Int = 60
    public var shiftStartHoursText: String = "06:00"
    public var breakWindowsText: String = "12:00-13:00"

    // NetworkManager Configuration fields
    public var primaryBaseURLText: String = NetworkManager.Configuration.defaultCloudFrontURL.absoluteString
    public var fallbackBaseURLText: String = NetworkManager.Configuration.defaultAPIGatewayURL.absoluteString
    public var apiKeyText: String = ""
    public var requestTimeoutSeconds: Double = 30

    // UI Status
    public var statusMessage: String?
    public var errorMessage: String?
    public var isTestingConnection: Bool = false
    public var connectionTestResult: String?

    public init(
        databaseManager: DatabaseManager? = nil,
        networkManager: NetworkManager? = nil
    ) {
        self.databaseManager = databaseManager ?? .shared
        self.networkManager = networkManager ?? .shared
    }

    public func load() async {
        errorMessage = nil
        do {
            let settings = try databaseManager.fetchSettings()
            meanPayloadM3 = settings.meanPayloadM3
            struckPayloadM3 = settings.struckPayloadM3
            heapedPayloadM3 = settings.heapedPayloadM3
            idleThresholdS = settings.idleThresholdS
            shiftEdgeWindowMin = settings.shiftEdgeWindowMin
            shiftStartHoursText = settings.shiftStartHours.joined(separator: ", ")
            breakWindowsText = settings.breakWindows.joined(separator: ", ")
        } catch {
            errorMessage = error.localizedDescription
        }

        let config = await networkManager.currentConfiguration()
        primaryBaseURLText = config.primaryBaseURL.absoluteString
        fallbackBaseURLText = config.fallbackBaseURL?.absoluteString ?? ""
        apiKeyText = config.apiKey ?? ""
        requestTimeoutSeconds = config.requestTimeoutSeconds
    }

    public func saveSettings() async {
        errorMessage = nil
        statusMessage = nil

        let shiftHours = parseCommaSeparatedList(shiftStartHoursText)
        let breaks = parseCommaSeparatedList(breakWindowsText)

        guard meanPayloadM3 > 0, struckPayloadM3 > 0, heapedPayloadM3 > 0 else {
            errorMessage = "Payload volumes must be positive numbers."
            return
        }
        guard idleThresholdS >= 0 else {
            errorMessage = "Idle allowance threshold cannot be negative."
            return
        }
        guard shiftEdgeWindowMin > 0 else {
            errorMessage = "Shift-edge window must be at least 1 minute."
            return
        }

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

        do {
            _ = try databaseManager.updateSettings(
                meanPayloadM3: meanPayloadM3,
                struckPayloadM3: struckPayloadM3,
                heapedPayloadM3: heapedPayloadM3,
                idleThresholdS: idleThresholdS,
                shiftEdgeWindowMin: shiftEdgeWindowMin,
                shiftStartHours: shiftHours.isEmpty ? ["06:00"] : shiftHours,
                breakWindows: breaks.isEmpty ? ["12:00-13:00"] : breaks
            )

            let cleanedKey = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
            let newConfig = NetworkManager.Configuration(
                primaryBaseURL: primaryURL,
                fallbackBaseURL: fallbackURL,
                apiKey: cleanedKey.isEmpty ? nil : cleanedKey,
                requestTimeoutSeconds: max(5, requestTimeoutSeconds)
            )
            await networkManager.configure(newConfig)
            statusMessage = "Saved client-side analytics rules and endpoint settings."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func resetDefaults() async {
        meanPayloadM3 = 51.1
        struckPayloadM3 = 42.1
        heapedPayloadM3 = 60.1
        idleThresholdS = 300
        shiftEdgeWindowMin = 60
        shiftStartHoursText = "06:00"
        breakWindowsText = "12:00-13:00"
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

    private func parseCommaSeparatedList(_ raw: String) -> [String] {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
