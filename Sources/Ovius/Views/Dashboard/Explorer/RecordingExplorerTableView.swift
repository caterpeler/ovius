import SwiftUI

/// Layer 1 of the Data Explorer: Searchable, filterable, multi-column sortable table of filtered Recordings + computed stats.
public struct RecordingExplorerTableView: View {
    public let rows: [RecordingExplorerRow]
    @Binding public var sortOrder: [KeyPathComparator<RecordingExplorerRow>]
    public let onOpenRecording: (RecordingExplorerRow) -> Void

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
                description: Text("Adjust the Cluster, Section, Date Range, Time Range, or Explorer search filters.")
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Date (UTC)", value: \.startDate) { row in
                    Text(OviusFormat.utcDateTime(row.startDate))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 120, ideal: 135)

                TableColumn("Section", value: \.sectionName) { row in
                    Text(row.sectionName)
                        .font(.caption)
                }
                .width(min: 95, ideal: 115)

                TableColumn("Camera", value: \.cameraId) { row in
                    Text(row.cameraId)
                        .font(.caption.monospaced())
                }
                .width(min: 95, ideal: 110)

                TableColumn("Recording / Location", value: \.locationTag) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.filename)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(row.locationTag)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .width(min: 170, ideal: 230)

                TableColumn("Cycles", value: \.totalCycleCount) { row in
                    Text("\(row.completeCycleCount)/\(row.totalCycleCount)")
                        .font(.caption.monospacedDigit())
                }
                .width(min: 65, ideal: 75)

                TableColumn("Volume (m³)", value: \.totalVolumeM3) { row in
                    Text(OviusFormat.volumeM3(row.totalVolumeM3))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 80, ideal: 95)

                TableColumn("Avg Queue", value: \.avgQueueTimeS) { row in
                    Text(OviusFormat.duration(seconds: row.avgQueueTimeS))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 70, ideal: 80)

                TableColumn("Avg Load", value: \.avgLoadDurationS) { row in
                    Text(OviusFormat.duration(seconds: row.avgLoadDurationS))
                        .font(.caption.monospacedDigit())
                }
                .width(min: 70, ideal: 80)

                TableColumn("Inspect") { row in
                    Button("Open Cycles") {
                        onOpenRecording(row)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .width(min: 95, ideal: 105)
            }
            .frame(minHeight: 300, maxHeight: 440)
        }
    }
}
