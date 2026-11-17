import SwiftUI

/// Layer 3 of the Data Explorer: Specific cycle phase summary + sortable machine `StateSegmentDTO`
/// intervals (Rule 4.3 uncertain highlighting) + embedded `ScoopTimingDTO` passes.
public struct StateTimingExplorerTableView: View {
    public let cycle: CycleExplorerRow
    public let segmentRows: [StateTimingExplorerRow]
    public let scoopRows: [ScoopTimingExplorerRow]
    public let isLoadingDrilldown: Bool

    @State private var sortOrder: [KeyPathComparator<StateTimingExplorerRow>] = [
        .init(\.startS, order: .forward)
    ]
    @State private var scoopSortOrder: [KeyPathComparator<ScoopTimingExplorerRow>] = [
        .init(\.scoopNumber, order: .forward)
    ]

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

    private var sortedSegmentRows: [StateTimingExplorerRow] {
        segmentRows.sorted(using: sortOrder)
    }

    private var sortedScoopRows: [ScoopTimingExplorerRow] {
        scoopRows.sorted(using: scoopSortOrder)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Cycle Macro Phase Summary Strip
            GroupBox {
                HStack(spacing: 18) {
                    phaseStat(title: "Cycle", value: cycle.cycleId)
                    phaseStat(title: "Truck / Excavator", value: "\(cycle.truckLabel) / \(cycle.excavatorId)")
                    phaseStat(title: "Queue", value: OviusFormat.duration(seconds: cycle.queueTimeS))
                    phaseStat(title: "Spot", value: OviusFormat.duration(seconds: cycle.spotDurationS))
                    phaseStat(title: "Load", value: OviusFormat.duration(seconds: cycle.loadDurationS))
                    phaseStat(title: "Depart", value: OviusFormat.duration(seconds: cycle.departureLagS))
                    phaseStat(title: "Total", value: OviusFormat.duration(seconds: cycle.totalCycleDurationS))
                    phaseStat(title: "Payload", value: OviusFormat.volumeM3(cycle.payloadM3))
                    Spacer()
                }
            }

            if isLoadingDrilldown && segmentRows.isEmpty {
                SectionLoadingPlaceholderView(
                    title: "Loading Machine State Timings…",
                    subtitle: "Fetching state segments and embedded bucket scoop passes.",
                    minHeight: 220
                )
            } else {
                // Chronological State Segments Table
                VStack(alignment: .leading, spacing: 6) {
                    Text("Machine State Timings (\(segmentRows.count))")
                        .font(.subheadline.weight(.semibold))

                    if segmentRows.isEmpty {
                        ContentUnavailableView(
                            "No Matching State Intervals",
                            systemImage: "timeline.selection",
                            description: Text("Adjust the Role, State, Confidence, or Search filters above.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        Table(sortedSegmentRows, sortOrder: $sortOrder) {
                            TableColumn("Machine", value: \.machineId) { row in
                                Text(row.machineId).font(.caption.weight(.semibold))
                            }
                            .width(min: 60, ideal: 75)

                            TableColumn("Role", value: \.machineRole) { row in
                                Text(row.machineRole).font(.caption)
                            }
                            .width(min: 65, ideal: 80)

                            TableColumn("State", value: \.state) { row in
                                Text(row.state)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(color(for: row.typedState))
                            }
                            .width(min: 105, ideal: 120)

                            TableColumn("UTC Start", value: \.utcClockStart) { row in
                                Text(row.utcClockStart).font(.caption.monospacedDigit())
                            }
                            .width(min: 85, ideal: 95)

                            TableColumn("Start (s)", value: \.startS) { row in
                                Text(String(format: "%.2f", row.startS)).font(.caption.monospacedDigit())
                            }
                            .width(min: 70, ideal: 80)

                            TableColumn("End (s)", value: \.endS) { row in
                                Text(String(format: "%.2f", row.endS)).font(.caption.monospacedDigit())
                            }
                            .width(min: 70, ideal: 80)

                            TableColumn("Duration", value: \.durationS) { row in
                                Text(OviusFormat.duration(seconds: row.durationS)).font(.caption.monospacedDigit())
                            }
                            .width(min: 70, ideal: 80)

                            TableColumn("Confidence", value: \.confidence) { row in
                                Text(OviusFormat.percentage(row.confidence))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(row.isUncertain ? Color.orange : Color.secondary)
                            }
                            .width(min: 75, ideal: 85)
                        }
                        .frame(minHeight: 240, maxHeight: 340)
                    }
                }

                // Embedded Scoop Pass Timings Table
                if !scoopRows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Embedded Bucket Scoop Passes (\(scoopRows.count))")
                            .font(.subheadline.weight(.semibold))

                        Table(sortedScoopRows, sortOrder: $scoopSortOrder) {
                            TableColumn("Scoop #", value: \.scoopNumber) { row in
                                Text("#\(row.scoopNumber)").font(.caption.monospacedDigit().weight(.medium))
                            }
                            .width(min: 60, ideal: 70)

                            TableColumn("Excavator Segment ID", value: \.excavatorSegmentId) { row in
                                Text(row.excavatorSegmentId).font(.caption.monospaced()).lineLimit(1)
                            }
                            .width(min: 180, ideal: 240)

                            TableColumn("Start (s)", value: \.startS) { row in
                                Text(String(format: "%.2f", row.startS)).font(.caption.monospacedDigit())
                            }
                            .width(min: 75, ideal: 90)

                            TableColumn("Dump (s)", value: \.dumpS) { row in
                                Text(String(format: "%.2f", row.dumpS)).font(.caption.monospacedDigit())
                            }
                            .width(min: 75, ideal: 90)

                            TableColumn("End (s)", value: \.endS) { row in
                                Text(String(format: "%.2f", row.endS)).font(.caption.monospacedDigit())
                            }
                            .width(min: 75, ideal: 90)

                            TableColumn("Pass Duration", value: \.durationS) { row in
                                Text(OviusFormat.duration(seconds: row.durationS)).font(.caption.monospacedDigit())
                            }
                            .width(min: 85, ideal: 95)

                            TableColumn("Inter-Scoop Gap", value: \.interScoopGapSortKey) { row in
                                Text(OviusFormat.duration(seconds: row.interScoopGapS))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .width(min: 95, ideal: 110)
                        }
                        .frame(minHeight: 160, maxHeight: 240)
                    }
                }
            }
        }
    }

    private func phaseStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit()).lineLimit(1)
        }
    }

    private func color(for state: MachineState?) -> Color {
        switch state {
        case .loadingScoop, .beingLoaded: return .blue
        case .facePrep: return .teal
        case .queuingIdle: return .orange
        case .spotting, .departing: return .indigo
        case .idle: return .red
        case .outOfFrame, nil: return .gray
        }
    }
}
