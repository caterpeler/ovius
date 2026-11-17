import Foundation

/// Navigation categories for the Settings workspace in the 3-column `NavigationSplitView`.
public enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case endpoint
    case storage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .endpoint: "AWS Endpoint"
        case .storage: "Offline Cache"
        }
    }

    public var subtitle: String {
        switch self {
        case .endpoint: "CloudFront, API Gateway & Timeouts"
        case .storage: "LZFSE Compressed Telemetry Storage"
        }
    }

    public var systemImage: String {
        switch self {
        case .endpoint: "network"
        case .storage: "internaldrive"
        }
    }
}
