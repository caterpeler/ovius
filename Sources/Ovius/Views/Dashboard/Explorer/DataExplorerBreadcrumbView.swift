import SwiftUI

/// Hierarchical drilldown breadcrumb header using standard chevron path separators.
public struct DataExplorerBreadcrumbView: View {
    public let explorer: DataExplorerViewModel
    public let onPopToRecordings: () -> Void
    public let onPopToCycles: () -> Void

    public init(
        explorer: DataExplorerViewModel,
        onPopToRecordings: @escaping () -> Void,
        onPopToCycles: @escaping () -> Void
    ) {
        self.explorer = explorer
        self.onPopToRecordings = onPopToRecordings
        self.onPopToCycles = onPopToCycles
    }

    public var body: some View {
        HStack(spacing: OviusDesign.Spacing.tight) {
            Text("Data Explorer")
                .font(.headline)
                .foregroundStyle(Tokens.text)

            breadcrumbSeparator

            Button("All Recordings (\(explorer.displayedRecordingRows.count))", action: onPopToRecordings)
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(explorer.explorerLevel == .recordings ? Tokens.text2 : Tokens.primary.text)
                .disabled(explorer.explorerLevel == .recordings)

            if case .cycles(let rec) = explorer.explorerLevel {
                breadcrumbSeparator
                Text("\(rec.cameraId) (\(rec.filename))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if case .stateTimings(let rec, let cycle) = explorer.explorerLevel {
                breadcrumbSeparator
                Button("\(rec.cameraId) (\(rec.filename))", action: onPopToCycles)
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(Tokens.primary.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                breadcrumbSeparator
                Text(cycle.cycleId)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
    }

    private var breadcrumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(Tokens.text3)
            .accessibilityHidden(true)
    }
}
