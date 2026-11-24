import SwiftUI

/// Modal sheet for creating or editing a Domain 2 `Section` and its recording selectors.
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
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            Text(existingSection == nil ? "New section" : "Edit section")
                .font(.system(size: 20, weight: .semibold))

            VStack(alignment: .leading, spacing: Ov.Space.m) {
                OvCardHeader("About")
                OvField("Section ID", prompt: "SEC_…", text: $sectionId)
                    .disabled(existingSection != nil)
                    .opacity(existingSection != nil ? 0.6 : 1)
                OvField("Name", prompt: "Section Alpha", text: $name)
                OvField("Assigned trucks (optional; found from telemetry when empty)", prompt: "8", text: $assignedTrucksText)
            }
            .ovCard()

            VStack(alignment: .leading, spacing: Ov.Space.m) {
                OvCardHeader("Recording selectors", subtitle: "Separate several with commas. A recording must match every one that is set.")
                OvField("Camera IDs", prompt: "CAM-ALPHA-01, CAM-ALPHA-02", text: $cameraIdsText)
                OvField("Location tags", prompt: "Section Alpha - Wide Overview Bench", text: $locationTagsText)
                OvField("Custom tags", prompt: "section:Alpha", text: $customTagsText)
                OvField("Exact filenames", prompt: "2026-11-16_clip.mp4", text: $filenamesText)
            }
            .ovCard()

            HStack {
                Spacer()
                Button("Cancel", action: closeSheet)
                    .buttonStyle(.ovQuiet)
                    .keyboardShortcut(.cancelAction)
                Button("Save section", action: saveAndClose)
                    .buttonStyle(.ovPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sectionId.trimmingCharacters(in: .whitespaces).isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Ov.Space.xxl)
        .frame(width: 560)
        .background(Ov.canvas)
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
