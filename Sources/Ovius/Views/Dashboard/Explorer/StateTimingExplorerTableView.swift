import SwiftUI

/// Layer 3 of the Data Explorer: Cycle phase summary + native inset sortable machine `StateSegmentDTO`
/// intervals + embedded `ScoopTimingDTO` passes.
public struct StateTimingExplorerTableView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let cycle: CycleExplorerRow
    public let segmentRows: [StateTimingExplorerRow]
    public let scoopRows: [ScoopTimingExplorerRow]
    public let isLoadingDrilldown: Bool

    @State private var sortOrder: [KeyPathComparator<StateTimingExplorerRow>] = [
        .init(\.startS, order: .forward)
    ]
    @State private var sortedSegmentRows: [StateTimingExplorerRow] = []

    public init(
        cycle: CycleExplorerRow,
        segmentRows: [StateTimingExplorerRow],
        scoopRows: [ScoopTimingExplorerRow],
        isLoadingDrilldown: Bool
    ) {
        self.cycle = cycle
        self.segmentRows = segmentRows
        self.scoopRows = scoopRows
        self.isLoadingDrilldown = isLoadingDrilldown
    }

    private func refreshSortedSegmentRows() {
        sortedSegmentRows = segmentRows.sorted(using: sortOrder)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.standard) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 180 : 105), spacing: OviusDesign.Spacing.standard)],
                alignment: .leading,
                spacing: OviusDesign.Spacing.compact
            ) {
                phaseStat(title: "Cycle", value: cycle.cycleId)
                phaseStat(title: "Truck / Excavator", value: "\(cycle.truckLabel) / \(cycle.excavatorId)")
                phaseStat(title: "Queue", value: OviusFormat.duration(seconds: cycle.queueTimeS))
                phaseStat(title: "Spot", value: OviusFormat.duration(seconds: cycle.spotDurationS))
                phaseStat(title: "Load", value: OviusFormat.duration(seconds: cycle.loadDurationS))
                phaseStat(title: "Depart", value: OviusFormat.duration(seconds: cycle.departureLagS))
                phaseStat(title: "Total", value: OviusFormat.duration(seconds: cycle.totalCycleDurationS))
                phaseStat(title: "Scoops", value: "\(cycle.scoopCount)")
            }
            .padding(OviusDesign.Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelSurface(
                background: Tokens.surface,
                borderColor: Tokens.border.opacity(0.65),
                radius: OviusDesign.Radius.card
            )

            if isLoadingDrilldown && segmentRows.isEmpty {
                SectionLoadingPlaceholderView(
                    title: "Loading Machine State Timings…",
                    subtitle: "Fetching state segments and embedded bucket scoop passes.",
                    minHeight: 140
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight) {
                    Text("Machine State Timings (\(segmentRows.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Tokens.text)

                    if segmentRows.isEmpty {
                        ContentUnavailableView(
                            "No Matching State Intervals",
                            systemImage: "timeline.selection",
                            description: Text("Adjust the Role, State, Confidence, or Search filters above.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                        .panelSurface(
                            background: Tokens.surface,
                            borderColor: Tokens.border.opacity(0.65),
                            radius: OviusDesign.Radius.card
                        )
                    } else {
                        Table(sortedSegmentRows, sortOrder: $sortOrder) {
                            TableColumn("Machine", value: \.machineId) { row in
                                Text(row.machineId)
                                    .font(.callout)
                                    .foregroundStyle(Tokens.text)
                            }
                            .width(min: 55, ideal: 70)

                            TableColumn("Role", value: \.machineRole) { row in
                                Text(row.machineRole)
                                    .font(.footnote)
                                    .foregroundStyle(Tokens.text2)
                            }
                            .width(min: 60, ideal: 75)

                            TableColumn("State", value: \.state) { row in
                                Text(row.state)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(color(for: row.typedState))
                            }
                            .width(min: 105, ideal: 120)

                            TableColumn("Start (s)", value: \.startS) { row in
                                Text(String(format: "%.2f", row.startS))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(Tokens.text2)
                            }
                            .width(min: 65, ideal: 78)

                            TableColumn("End (s)", value: \.endS) { row in
                                Text(String(format: "%.2f", row.endS))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(Tokens.text2)
                            }
                            .width(min: 65, ideal: 78)

                            TableColumn("Duration", value: \.durationS) { row in
                                Text(OviusFormat.duration(seconds: row.durationS))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(Tokens.text)
                            }
                            .width(min: 65, ideal: 78)

                            TableColumn("Confidence", value: \.confidence) { row in
                                if row.isUncertain {
                                    Label(OviusFormat.percentage(row.confidence), systemImage: "exclamationmark.triangle.fill")
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(Tokens.warning.text)
                                } else {
                                    Text(OviusFormat.percentage(row.confidence))
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(Tokens.text2)
                                }
                            }
                            .width(min: 78, ideal: 90)
                        }
                        .tableStyle(.inset(alternatesRowBackgrounds: true))
                        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                        .clipShape(.rect(cornerRadius: OviusDesign.Radius.card, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: OviusDesign.Radius.card, style: .continuous)
                                .strokeBorder(Tokens.border.opacity(0.65), lineWidth: 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if !scoopRows.isEmpty {
                    StateScoopPassesTableView(rows: scoopRows)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { refreshSortedSegmentRows() }
        .onChange(of: segmentRows) { _, _ in refreshSortedSegmentRows() }
        .onChange(of: sortOrder) { _, _ in refreshSortedSegmentRows() }
    }

    private func phaseStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Tokens.text2)
            Text(value)
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func color(for state: MachineState?) -> Color {
        switch state {
        case .loadingScoop, .beingLoaded: Tokens.info.text
        case .facePrep: Tokens.teal.text
        case .queuingIdle: Tokens.warning.text
        case .spotting, .departing: Tokens.indigo.text
        case .idle: Tokens.danger.text
        case .outOfFrame, nil: Tokens.text3
        }
    }
}
