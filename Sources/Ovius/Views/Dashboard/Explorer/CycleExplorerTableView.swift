import SwiftUI

/// Layer 2 of the Data Explorer: Recording summary strip + native inset sortable table of `HaulCycleDTO` rows.
public struct CycleExplorerTableView: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    public let recording: RecordingExplorerRow
    public let rows: [CycleExplorerRow]
    public let isLoadingDrilldown: Bool
    public let onOpenCycle: (CycleExplorerRow) -> Void

    @State private var selectedCycleId: CycleExplorerRow.ID?
    @State private var sortOrder: [KeyPathComparator<CycleExplorerRow>] = [
        .init(\.tLoadStartS, order: .forward)
    ]
    @State private var sortedRows: [CycleExplorerRow] = []

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

    private func refreshSortedRows() {
        sortedRows = rows.sorted(using: sortOrder)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.standard) {
            CycleSummaryStripView(
                recording: recording,
                isLoadingDrilldown: isLoadingDrilldown
            )

            if isLoadingDrilldown && rows.isEmpty {
                SectionLoadingPlaceholderView(
                    title: "Loading Recording Cycles & Scoops…",
                    subtitle: "Fetching full haul cycles and machine state segments for \(recording.recordingId).",
                    minHeight: 140
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Matching Cycles",
                    systemImage: "truck.box",
                    description: Text("No cycles match the active Cycle Explorer filters.")
                )
                .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                .panelSurface(
                    background: Tokens.surface,
                    borderColor: Tokens.border.opacity(0.65),
                    radius: OviusDesign.Radius.card
                )
            } else {
                Table(sortedRows, selection: $selectedCycleId, sortOrder: $sortOrder) {
                    TableColumn("Cycle ID", value: \.cycleId) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.cycleId)
                                .font(.footnote.monospaced())
                                .foregroundStyle(Tokens.text)
                                .lineLimit(1)
                            Text("Load @ \(OviusFormat.duration(seconds: row.tLoadStartS))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Tokens.text2)
                        }
                    }
                    .width(min: 106, ideal: 118)

                    TableColumn("Truck", value: \.truckLabel) { row in
                        Text(row.truckLabel)
                            .font(.callout)
                            .foregroundStyle(Tokens.text)
                    }
                    .width(min: 44, ideal: 52)

                    TableColumn("Exc", value: \.excavatorId) { row in
                        Text(row.excavatorId)
                            .font(.footnote)
                            .foregroundStyle(Tokens.text2)
                    }
                    .width(min: 42, ideal: 48)

                    TableColumn("Status", value: \.cycleStatus) { row in
                        Label(
                            row.cycleStatus,
                            systemImage: row.isComplete ? "checkmark.circle.fill" : "clock.badge.exclamationmark"
                        )
                        .font(.footnote)
                        .foregroundStyle(row.isComplete ? Tokens.success.text : Tokens.warning.text)
                    }
                    .width(min: 78, ideal: 88)

                    TableColumn("Queue", value: \.queueTimeS) { row in
                        Text(OviusFormat.duration(seconds: row.queueTimeS))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Tokens.text2)
                    }
                    .width(min: 46, ideal: 54)

                    TableColumn("Load", value: \.loadDurationS) { row in
                        Text(OviusFormat.duration(seconds: row.loadDurationS))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Tokens.text2)
                    }
                    .width(min: 46, ideal: 54)

                    TableColumn("Scoops", value: \.scoopCount) { row in
                        Text("\(row.scoopCount)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Tokens.text)
                    }
                    .width(min: 44, ideal: 50)

                    TableColumn("Total", value: \.totalCycleDurationSortKey) { row in
                        if let total = row.totalCycleDurationS {
                            Text(OviusFormat.duration(seconds: total))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Tokens.text)
                        } else {
                            Text("Excluded (null)")
                                .font(.footnote)
                                .foregroundStyle(Tokens.warning.text)
                        }
                    }
                    .width(min: 66, ideal: 76)

                    TableColumn("Uncertain", value: \.uncertainSegmentCount) { row in
                        if row.uncertainSegmentCount > 0 {
                            Label("\(row.uncertainSegmentCount)", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Tokens.warning.text)
                        } else {
                            Text(differentiateWithoutColor ? "0 (OK)" : "0")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Tokens.text3)
                        }
                    }
                    .width(min: 54, ideal: 62)

                    TableColumn("") { row in
                        Button("Open Timings", systemImage: "chevron.right") {
                            onOpenCycle(row)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(Tokens.primary.text)
                        .accessibilityLabel("Open timings for cycle \(row.cycleId)")
                        .help("Open state timings and scoop passes")
                    }
                    .width(min: 24, ideal: 28)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: CycleExplorerRow.ID.self) { ids in
                    if let id = ids.first, let row = sortedRows.first(where: { $0.id == id }) {
                        Button("Open Timings", systemImage: "chevron.right") {
                            onOpenCycle(row)
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let row = sortedRows.first(where: { $0.id == id }) {
                        onOpenCycle(row)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { refreshSortedRows() }
        .onChange(of: rows) { _, _ in refreshSortedRows() }
        .onChange(of: sortOrder) { _, _ in refreshSortedRows() }
    }
}
