import SwiftUI

/// Modal sheet for creating or renaming a Domain 2 `Cluster`.
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
        VStack(alignment: .leading, spacing: 16) {
            Text(existingCluster == nil ? "New Cluster" : "Edit Cluster")
                .font(.title3.bold())

            Form {
                TextField("Cluster ID", text: $clusterId)
                    .disabled(existingCluster != nil)
                TextField("Display Name", text: $name)
                TextField("Tags (comma-separated)", text: $tagsText)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Cluster") {
                    onSave(clusterId, name, tagsText)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(clusterId.trimmingCharacters(in: .whitespaces).isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
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
}
