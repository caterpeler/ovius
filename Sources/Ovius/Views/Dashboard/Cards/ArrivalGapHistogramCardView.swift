import Charts
import SwiftUI

/// Dedicated view for `CARD_ARRIVAL_GAP_CHART` (`DIAG_09_INTER_ARRIVAL_GAPS`).
public struct ArrivalGapHistogramCardView: View {
    public let snapshot: SectionMetricsSnapshot

    public init(snapshot: SectionMetricsSnapshot) {
        self.snapshot = snapshot
    }

    public var body: some View {
        let samples = snapshot.arrivalHeadwaySamples
        let maxGapMin = samples.map(\.gapMin).max() ?? 0
        let avgHangS = samples.isEmpty ? 0 : samples.reduce(0.0) { $0 + $1.precedentHangS } / Double(samples.count)
        let isBlockagePattern = snapshot.gapCoeffOfVariation >= 0.85 || maxGapMin >= 15.0

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                statPill(title: "Arrival Rate", value: OviusFormat.metricValue(snapshot.value(for: .truckArrivalRateHr), key: .truckArrivalRateHr))
                statPill(title: "Peak Gap", value: String(format: "%.1f min", maxGapMin))
                statPill(title: "Precedent Shovel Hang", value: OviusFormat.duration(seconds: avgHangS))
                Spacer()
                Text(samples.isEmpty ? "No Gaps" : (isBlockagePattern ? "Blockage / Platoon (CV \(String(format: "%.2f", snapshot.gapCoeffOfVariation)))" : "Uniform Shortage (CV \(String(format: "%.2f", snapshot.gapCoeffOfVariation)))"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isBlockagePattern ? Color.orange : Color.teal)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((isBlockagePattern ? Color.orange : Color.teal).opacity(0.12))
                    .clipShape(.rect(cornerRadius: 4))
            }

            if snapshot.interArrivalGapHistogram.isEmpty {
                ContentUnavailableView(
                    "No Inter-Arrival Intervals",
                    systemImage: "truck.box",
                    description: Text("At least two arrivals per recording are required to plot headway gaps.")
                )
                .frame(height: 185)
            } else {
                Chart(snapshot.interArrivalGapHistogram) { bin in
                    BarMark(
                        x: .value("Headway Bucket", bin.label),
                        y: .value("Arrivals", bin.count)
                    )
                    .foregroundStyle(Color.teal.gradient)
                    .cornerRadius(4)
                }
                .chartXAxisLabel("Inter-Arrival Gap (s)")
                .chartYAxisLabel("Count")
                .frame(height: 145)

                if !samples.isEmpty {
                    let topSamples = Array(samples.prefix(15))
                    Chart(topSamples) { sample in
                        PointMark(
                            x: .value("Gap (min)", sample.gapMin),
                            y: .value("Shovel Hang (s)", sample.precedentHangS)
                        )
                        .foregroundStyle(sample.precedentHangS > 60 ? Color.orange : Color.teal)
                    }
                    .chartXAxisLabel("Longest Headway Gaps (min) vs. Precedent Excavator Hang (s)")
                    .frame(height: 95)
                }
            }
        }
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.bold().monospacedDigit())
        }
    }
}
