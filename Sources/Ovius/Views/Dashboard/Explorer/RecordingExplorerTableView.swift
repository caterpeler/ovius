import SwiftUI

/// Layer 1 of the Data Explorer: native inset multi-column sortable table of selected Recordings.
public struct RecordingExplorerTableView: View {
    public let rows: [RecordingExplorerRow]
    @Binding public var sortOrder: [KeyPathComparator<RecordingExplorerRow>]
    public let onOpenRecording: (RecordingExplorerRow) -> Void

    @State private var selectedRecordingId: RecordingExplorerRow.ID?

    public init(
        rows: [RecordingExplorerRow],
        sortOrder: Binding<[KeyPathComparator<RecordingExplorerRow>]>,
        onOpenRecording: @escaping (RecordingExplorerRow) -> Void
    ) {
        self.rows = rows
        self._sortOrder = sortOrder
        self.onOpenRecording = onOpenRecording
    }

    public var body: some View {
        if rows.isEmpty {
            ContentUnavailableView(
                "No Matching Recordings",
                systemImage: "film.stack",
                description: Text("Adjust your sidebar selection or Explorer search filters.")
            )
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
            .panelSurface(
                background: Tokens.surface,
                borderColor: Tokens.border.opacity(0.65),
                radius: OviusDesign.Radius.card
            )
        } else {
            Table(rows, selection: $selectedRecordingId, sortOrder: $sortOrder) {
                TableColumn("Timestamp", value: \.startDate) { row in
                    Text(row.formattedTimestamp)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                }
                .width(min: 122, ideal: 130)

                TableColumn("Camera", value: \.cameraId) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.cameraId)
                            .font(.footnote.monospaced().weight(.medium))
                            .foregroundStyle(Tokens.text)
                            .lineLimit(1)
                        Text(row.sectionName)
                            .font(.caption)
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .width(min: 94, ideal: 102)

                TableColumn("Recording", value: \.locationTag) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.filename)
                            .font(.callout)
                            .foregroundStyle(Tokens.text)
                            .lineLimit(1)
                        Text(row.locationTag)
                            .font(.caption)
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                    .help("\(row.filename) — \(row.locationTag)")
                }
                .width(min: 120, ideal: 145, max: 320)

                TableColumn("Cycles", value: \.totalCycleCount) { row in
                    Text("\(row.completeCycleCount)/\(row.totalCycleCount)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text)
                }
                .width(min: 44, ideal: 48)

                TableColumn("Passes", value: \.avgPassesPerCycle) { row in
                    Text(row.avgPassesPerCycle > 0 ? OviusFormat.decimal(row.avgPassesPerCycle) : "—")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text)
                }
                .width(min: 46, ideal: 50)

                TableColumn("Queue", value: \.avgQueueTimeS) { row in
                    Text(OviusFormat.duration(seconds: row.avgQueueTimeS))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text2)
                }
                .width(min: 48, ideal: 54)

                TableColumn("Load", value: \.avgLoadDurationS) { row in
                    Text(OviusFormat.duration(seconds: row.avgLoadDurationS))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text2)
                }
                .width(min: 46, ideal: 52)

                TableColumn("") { row in
                    Button("Open Cycles", systemImage: "chevron.right") {
                        onOpenRecording(row)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.primary.text)
                    .accessibilityLabel("Open cycles for \(row.filename)")
                    .help("Open haul cycles for this recording")
                }
                .width(min: 24, ideal: 28)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: RecordingExplorerRow.ID.self) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Open Cycles", systemImage: "chevron.right") {
                        onOpenRecording(row)
                    }
                }
            } primaryAction: { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    onOpenRecording(row)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: OviusDesign.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OviusDesign.Radius.card, style: .continuous)
                    .strokeBorder(Tokens.border.opacity(0.65), lineWidth: 1)
            }
        }
    }
}
