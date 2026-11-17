import SwiftUI

/// Layer 2 of the Data Explorer: Recording statistics strip + searchable, filterable, sortable table of `HaulCycleDTO` rows.
public struct CycleExplorerTableView: View {
    public let recording: RecordingExplorerRow
    public let rows: [CycleExplorerRow]
    public let isLoadingDrilldown: Bool
    public let onOpenCycle: (CycleExplorerRow) -> Void

    @State private var sortOrder: [KeyPathComparator<CycleExplorerRow>] = [
        .init(\.tLoadStartS, order: .forward)
    ]

    public init(
        recording: RecordingExplorerRow,
        rows: [CycleExplorerRow],
        isLoadingDrilldown: Bool,
        onOpenCycle: @escaping (CycleExplorerRow) -> Void
    ) {
        self.recording = recording
        self.rows = rows
        self.isLoadingDrilldown = isLoadingDrilldown
        self.onOpenCycle = onOpenCycle
    }

    private var sortedRows: [CycleExplorerRow] {
        rows.sorted(using: sortOrder)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Recording Summary Stats Header
            GroupBox {
                HStack(spacing: 20) {
                    statItem(title: "Camera / File", value: "\(recording.cameraId) • \(recording.filename)")
                    statItem(title: "Complete / Total", value: "\(recording.completeCycleCount) / \(recording.totalCycleCount)")
                    statItem(title: "Volume", value: OviusFormat.volumeM3(recording.totalVolumeM3))
                    statItem(title: "Rate", value: OviusFormat.metricValue(recording.volumetricRateM3Hr, key: .volumetricRateM3Hr))
                    statItem(title: "Mean Queue / Load", value: "\(OviusFormat.duration(seconds: recording.avgQueueTimeS)) / \(OviusFormat.duration(seconds: recording.avgLoadDurationS))")
                    statItem(title: "Fleet Active", value: "\(recording.excavatorCount) exc • \(recording.truckCount) trucks")
                    Spacer()
                    if isLoadingDrilldown {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Syncing scoops & segments…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if isLoadingDrilldown && rows.isEmpty {
                SectionLoadingPlaceholderView(
                    title: "Loading Recording Cycles & Scoops…",
                    subtitle: "Fetching full haul cycles and machine state segments for \(recording.recordingId).",
                    minHeight: 240
                )
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Matching Cycles",
                    systemImage: "truck.box",
                    description: Text("No cycles match the active Time Range or Cycle Explorer filters.")
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                Table(sortedRows, sortOrder: $sortOrder) {
                    TableColumn("Cycle ID", value: \.cycleId) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.cycleId)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Text("Load @ \(OviusFormat.duration(seconds: row.tLoadStartS))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 145, ideal: 170)

                    TableColumn("Truck", value: \.truckLabel) { row in
                        Text(row.truckLabel).font(.caption.weight(.medium))
                    }
                    .width(min: 55, ideal: 65)

                    TableColumn("Excavator", value: \.excavatorId) { row in
                        Text(row.excavatorId).font(.caption)
                    }
                    .width(min: 65, ideal: 75)

                    TableColumn("Status", value: \.cycleStatus) { row in
                        Text(row.cycleStatus)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(row.isComplete ? Color.green : Color.orange)
                    }
                    .width(min: 75, ideal: 90)

                    TableColumn("Queue", value: \.queueTimeS) { row in
                        Text(OviusFormat.duration(seconds: row.queueTimeS))
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 60, ideal: 70)

                    TableColumn("Load Dur", value: \.loadDurationS) { row in
                        Text(OviusFormat.duration(seconds: row.loadDurationS))
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 65, ideal: 75)

                    TableColumn("Scoops", value: \.scoopCount) { row in
                        Text("\(row.scoopCount)")
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("Total Cycle", value: \.totalCycleDurationSortKey) { row in
                        if let total = row.totalCycleDurationS {
                            Text(OviusFormat.duration(seconds: total))
                                .font(.caption.monospacedDigit())
                        } else {
                            Text("Excluded (null)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .width(min: 90, ideal: 105)

                    TableColumn("Uncertain", value: \.uncertainSegmentCount) { row in
                        Text("\(row.uncertainSegmentCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(row.uncertainSegmentCount > 0 ? Color.orange : Color.secondary)
                    }
                    .width(min: 65, ideal: 75)

                    TableColumn("Timings") { row in
                        Button("Open Timings") {
                            onOpenCycle(row)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .width(min: 100, ideal: 110)
                }
                .frame(minHeight: 300, maxHeight: 440)
            }
        }
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1)
        }
    }
}
