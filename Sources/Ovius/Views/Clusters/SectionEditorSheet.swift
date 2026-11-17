import SwiftUI

/// Modal sheet for creating or editing a Domain 2 `Section` and its dynamic recording selectors.
public struct SectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let clusterId: String
    public let existingSection: Section?
    public let onSave: (
        _ sectionId: String,
        _ clusterId: String,
        _ name: String,
        _ cameraIdsText: String,
        _ locationTagsText: String,
        _ customTagsText: String,
        _ filenamesText: String,
        _ assignedTrucksText: String
    ) -> Void

    @State private var sectionId: String = ""
    @State private var name: String = ""
    @State private var cameraIdsText: String = ""
    @State private var locationTagsText: String = ""
    @State private var customTagsText: String = ""
    @State private var filenamesText: String = ""
    @State private var assignedTrucksText: String = ""

    public init(
        clusterId: String,
        existingSection: Section? = nil,
        onSave: @escaping (
            _ sectionId: String,
            _ clusterId: String,
            _ name: String,
            _ cameraIdsText: String,
            _ locationTagsText: String,
            _ customTagsText: String,
            _ filenamesText: String,
            _ assignedTrucksText: String
        ) -> Void
    ) {
        self.clusterId = clusterId
        self.existingSection = existingSection
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.section) {
            Text(existingSection == nil ? "New Section" : "Edit Section Selectors")
                .font(.title3.bold())

            Form {
                SwiftUI.Section("Identity") {
                    TextField("Section ID", text: $sectionId)
                        .disabled(existingSection != nil)
                    TextField("Display Name", text: $name)
                    TextField("Assigned Trucks (optional)", text: $assignedTrucksText)
                }

                SwiftUI.Section("Dynamic AWS Query Selectors (comma-separated)") {
                    TextField("Camera IDs (uses GSI)", text: $cameraIdsText)
                    TextField("Location Tags", text: $locationTagsText)
                    TextField("Custom Tags", text: $customTagsText)
                    TextField("Exact Filenames", text: $filenamesText)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", action: closeSheet)
                    .keyboardShortcut(.cancelAction)

                Button("Save Section", action: saveAndClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(sectionId.trimmingCharacters(in: .whitespaces).isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(OviusDesign.Spacing.page)
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 640)
        .onAppear {
            if let existingSection {
                sectionId = existingSection.sectionId
                name = existingSection.name
                cameraIdsText = existingSection.cameraIds.joined(separator: ", ")
                locationTagsText = existingSection.locationTags.joined(separator: ", ")
                customTagsText = existingSection.customTags.joined(separator: ", ")
                filenamesText = existingSection.filenames.joined(separator: ", ")
                assignedTrucksText = existingSection.assignedTrucks.map(String.init) ?? ""
            } else {
                sectionId = "SEC_\(UUID().uuidString.prefix(6).uppercased())"
            }
        }
    }

    private func closeSheet() {
        dismiss()
    }

    private func saveAndClose() {
        onSave(
            sectionId,
            clusterId,
            name,
            cameraIdsText,
            locationTagsText,
            customTagsText,
            filenamesText,
            assignedTrucksText
        )
        dismiss()
    }
}
