import SwiftUI

/// Displays the 3 equal-height summary metric cards aligned on an adaptive grid:
/// 1) Cycle Counts, Mean Passes, & Cycle Time (Mean / Stdev)
/// 2) Excavator & Truck Idle Time (Mean / Stdev)
/// 3) Excavator & Truck Effective Equipment Utilization (EEU)
public struct DashboardMetricCardsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let summary: DashboardMetricsSummary
    public let isLoading: Bool

    public init(summary: DashboardMetricsSummary, isLoading: Bool) {
        self.summary = summary
        self.isLoading = isLoading
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: OviusDesign.Spacing.section) {
                    cyclesAndPassesCard
                    idleTimeCard
                    utilizationCard
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    Grid(
                        alignment: .topLeading,
                        horizontalSpacing: OviusDesign.Spacing.section,
                        verticalSpacing: OviusDesign.Spacing.section
                    ) {
                        GridRow {
                            cyclesAndPassesCard
                                .frame(minWidth: 195)
                            idleTimeCard
                                .frame(minWidth: 190)
                            utilizationCard
                                .frame(minWidth: 180)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    Grid(
                        alignment: .topLeading,
                        horizontalSpacing: OviusDesign.Spacing.section,
                        verticalSpacing: OviusDesign.Spacing.section
                    ) {
                        GridRow {
                            cyclesAndPassesCard
                                .frame(minWidth: 195)
                            idleTimeCard
                                .frame(minWidth: 190)
                        }
                        GridRow {
                            utilizationCard
                                .gridCellColumns(2)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: OviusDesign.Spacing.section) {
                        cyclesAndPassesCard
                        idleTimeCard
                        utilizationCard
                    }
                }
            }
        }
        .redacted(reason: isLoading ? .placeholder : [])
    }

    private var cyclesAndPassesCard: some View {
        MetricPanelCard(title: "Cycles & Passes", systemImage: "arrow.triangle.2.circlepath", accent: Tokens.primary) {
            MetricValueRow(
                label: "Complete / Mean",
                value: "\(summary.completeCycleCount) (\(OviusFormat.decimal(summary.meanCyclesPerRecording)) / clip)"
            )
            MetricValueRow(
                label: "Mean Passes per Cycle",
                value: summary.completeCycleCount > 0 && summary.meanPassesPerCycle > 0
                    ? OviusFormat.decimal(summary.meanPassesPerCycle)
                    : "—"
            )
            MetricValueRow(
                label: "Mean Cycle Time",
                value: summary.completeCycleCount > 0
                    ? OviusFormat.duration(seconds: summary.meanCycleTimeS)
                    : "—"
            )
            MetricValueRow(
                label: "Cycle Time Stdev",
                value: summary.completeCycleCount >= 2
                    ? OviusFormat.duration(seconds: summary.cycleTimeStdDevS)
                    : "—"
            )
        }
    }

    private var idleTimeCard: some View {
        MetricPanelCard(title: "Idle Time", systemImage: "pause.circle", accent: Tokens.warning) {
            MetricValueRow(
                label: "Excavator Mean Idle",
                value: summary.excavatorIdleSpellCount > 0
                    ? OviusFormat.duration(seconds: summary.excavatorMeanIdleS)
                    : "—"
            )
            MetricValueRow(
                label: "Excavator Idle Stdev",
                value: summary.excavatorIdleSpellCount >= 2
                    ? OviusFormat.duration(seconds: summary.excavatorIdleStdDevS)
                    : "—"
            )
            MetricValueRow(
                label: "Truck Mean Idle",
                value: summary.truckIdleSpellCount > 0
                    ? OviusFormat.duration(seconds: summary.truckMeanIdleS)
                    : "—"
            )
            MetricValueRow(
                label: "Truck Idle Stdev",
                value: summary.truckIdleSpellCount >= 2
                    ? OviusFormat.duration(seconds: summary.truckIdleStdDevS)
                    : "—"
            )
        }
    }

    private var utilizationCard: some View {
        MetricPanelCard(title: "Effective Utilization (EEU)", systemImage: "gauge.with.needle", accent: Tokens.teal) {
            MetricValueRow(
                label: "Excavator EEU",
                value: OviusFormat.percentage(summary.excavatorEEU)
            )
            MetricValueRow(
                label: "Truck EEU",
                value: OviusFormat.percentage(summary.truckEEU)
            )

            Spacer(minLength: OviusDesign.Spacing.tight)

            Text("\(summary.recordingCount) clip\(summary.recordingCount == 1 ? "" : "s") • \(summary.totalCycleCount) total cycles")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Tokens.text3)
        }
    }
}
