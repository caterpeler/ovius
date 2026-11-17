import Foundation

/// Identifiable payload driving `SectionEditorSheet` for create and edit flows.
public enum SectionEditorDraft: Identifiable {
    case create(clusterId: String)
    case edit(Section)

    public var id: String {
        switch self {
        case .create(let clusterId): "create-\(clusterId)"
        case .edit(let section): "edit-\(section.sectionId)"
        }
    }

    public var clusterId: String {
        switch self {
        case .create(let clusterId): clusterId
        case .edit(let section): section.clusterId
        }
    }

    public var existingSection: Section? {
        switch self {
        case .create: nil
        case .edit(let section): section
        }
    }
}
