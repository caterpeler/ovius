import Charts
import SwiftUI

/// Dedicated view for `CARD_QUEUE_WAIT_HISTOGRAM` (`DIAG_02_QUEUE_DISTRIBUTION`).
public struct QueueWaitHistogramCardView: View {
    public let snapshot: SectionMetricsSnapshot
    public let baseline: ClusterBaselineStats?

    public init(snapshot: SectionMetricsSnapshot, baseline: ClusterBaselineStats?) {
        self.snapshot = snapshot
        self.baseline = baseline
    }

    public var body: some View {
        let loadAvg = snapshot.value(for: .avgLoadDurationS)
        let inflow = snapshot.value(for: .truckArrivalRateHr)
        let shovelMax = snapshot.queueDepthSummary.shovelMaxRateHr
        let depth = snapshot.queueDepthSummary

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                statPill(title: "Mean Queue", value: OviusFormat.duration(seconds: snapshot.value(for: .avgQueueTimeS)))
                statPill(title: "Active Load", value: OviusFormat.duration(seconds: loadAvg))
                statPill(title: "Pocket Service", value: OviusFormat.duration(seconds: snapshot.pocketServiceTimeS))
                statPill(
                    title: "Inflow / Max",
                    value: "\(String(format: "%.1f", inflow)) / \(String(format: "%.1f", shovelMax)) /hr",
                    highlight: shovelMax > 0 && inflow > shovelMax
                )
                statPill(title: "Cluster μ", value: OviusFormat.duration(seconds: baseline?.mean(for: .avgQueueTimeS)))
            }

            if snapshot.queueTimeHistogram.isEmpty {
                ContentUnavailableView(
                    "No Queue Samples",
                    systemImage: "chart.bar",
                    description: Text("No complete cycles in the current filter scope.")
                )
                .frame(height: 185)
            } else {
                let maxUpper = snapshot.queueTimeHistogram.map(\.upperBoundS).max() ?? 300
                let clampedLoad = min(maxUpper, max(0, loadAvg))

                Chart {
                    ForEach(snapshot.queueTimeHistogram) { bin in
                        BarMark(
                            xStart: .value("Wait Start (s)", bin.lowerBoundS),
                            xEnd: .value("Wait End (s)", bin.upperBoundS),
                            y: .value("Cycles", bin.count)
                        )
                        .foregroundStyle((bin.lowerBoundS >= loadAvg && loadAvg > 0) ? Color.orange.gradient : Color.accentColor.gradient)
                        .cornerRadius(3)
                    }

                    if loadAvg > 0 {
                        RuleMark(x: .value("Load Threshold", clampedLoad))
                            .foregroundStyle(.red)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Load \(OviusFormat.duration(seconds: loadAvg))")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 4)
                                    .background(.background.opacity(0.85))
                            }
                    }
                }
                .chartXAxisLabel("Queue Wait (s)")
                .chartYAxisLabel("Cycles")
                .frame(height: 185)
            }

            // Queue Depth (0 / 1 / 2+) Strip
            if depth.totalCycles > 0 {
                HStack(spacing: 10) {
                    Text("Queue Depth:")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    depthChip(label: "0 Waiting", count: depth.zero, total: depth.totalCycles, color: .green)
                    depthChip(label: "1 Waiting", count: depth.one, total: depth.totalCycles, color: .accentColor)
                    depthChip(label: "2+ Stacked", count: depth.twoPlus, total: depth.totalCycles, color: .orange)
                    Spacer()
                    Text("Peak Depth: \(depth.maxConcurrentDepth)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statPill(title: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(highlight ? Color.orange : Color.primary)
        }
    }

    private func depthChip(label: String, count: Int, total: Int, color: Color) -> some View {
        let pct = total > 0 ? (Double(count) / Double(total)) * 100.0 : 0
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label): \(count) (\(String(format: "%.0f%%", pct)))")
                .font(.caption2.monospacedDigit())
        }
    }
}
