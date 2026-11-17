import Foundation

/// Top-level navigation destinations in the Ovius sidebar.
public enum AppSidebarTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case clusters
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .clusters: "Clusters & Sections"
        case .settings: "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .clusters: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}
