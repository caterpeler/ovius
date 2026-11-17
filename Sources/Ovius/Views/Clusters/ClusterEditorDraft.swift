import Foundation

/// Identifiable payload driving `ClusterEditorSheet` for create and edit flows.
public enum ClusterEditorDraft: Identifiable {
    case create
    case edit(Cluster)

    public var id: String {
        switch self {
        case .create: "create"
        case .edit(let cluster): "edit-\(cluster.clusterId)"
        }
    }

    public var existingCluster: Cluster? {
        switch self {
        case .create: nil
        case .edit(let cluster): cluster
        }
    }
}
