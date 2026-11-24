import SwiftUI

/// Modal sheet for creating or renaming a Domain 2 `Cluster`. Its targets are set on the cluster's page.
public struct ClusterEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    public let existingCluster: Cluster?
    public let onSave: (_ clusterId: String, _ name: String, _ tagsText: String) -> Void

    @State private var clusterId: String = ""
    @State private var name: String = ""
    @State private var tagsText: String = ""

    public init(
        existingCluster: Cluster? = nil,
        onSave: @escaping (_ clusterId: String, _ name: String, _ tagsText: String) -> Void
    ) {
        self.existingCluster = existingCluster
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            Text(existingCluster == nil ? "New cluster" : "Rename cluster")
                .font(.system(size: 20, weight: .semibold))

            VStack(alignment: .leading, spacing: Ov.Space.m) {
                OvField("Cluster ID", prompt: "CLUSTER_…", text: $clusterId)
                    .disabled(existingCluster != nil)
                    .opacity(existingCluster != nil ? 0.6 : 1)
                OvField("Name", prompt: "Open-Pit Site", text: $name)
                OvField("Tags, separated by commas", prompt: "site:north, shift:day", text: $tagsText)
            }
            .ovCard()

            HStack {
                Spacer()
                Button("Cancel", action: closeSheet)
                    .buttonStyle(.ovQuiet)
                    .keyboardShortcut(.cancelAction)
                Button("Save cluster", action: saveAndClose)
                    .buttonStyle(.ovPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(clusterId.trimmingCharacters(in: .whitespaces).isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Ov.Space.xxl)
        .frame(width: 480)
        .background(Ov.canvas)
        .onAppear {
            if let existingCluster {
                clusterId = existingCluster.clusterId
                name = existingCluster.name
                tagsText = existingCluster.tags.joined(separator: ", ")
            } else {
                clusterId = "CLUSTER_\(UUID().uuidString.prefix(6).uppercased())"
            }
        }
    }

    private func closeSheet() {
        dismiss()
    }

    private func saveAndClose() {
        onSave(clusterId, name, tagsText)
        dismiss()
    }
}
