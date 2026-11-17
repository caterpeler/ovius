import Charts
import SwiftUI

private enum CycleMetricTrack: String, CaseIterable, Identifiable {
    case loadS = "Load (s)"
    case queueS = "Queue (s)"
    case hangPct = "Hang (%)"

    var id: String { rawValue }
}

private struct HourlyBandPoint: Identifiable {
    let id: Int
    let hourIndex: Int
    let actual: Double
    let mean: Double
    let bandLow: Double
    let bandHigh: Double
}

/// Dedicated view for `CARD_HOURLY_CYCLE_METRIC_TREND` (`DIAG_14_HOURLY_CYCLE_METRICS`).
/// Plots Load, Queue, and Excavator Hang % against Cluster hourly `μ ± 1σ` bands.
public struct HourlyCycleMetricTrendCardView: View {
    public let snapshot: SectionMetricsSnapshot
    public let baseline: ClusterBaselineStats?
    public let shiftBaseHourUTC: Int

    @State private var selectedTrack: CycleMetricTrack = .loadS

    public init(snapshot: SectionMetricsSnapshot, baseline: ClusterBaselineStats?, shiftBaseHourUTC: Int = 6) {
        self.snapshot = snapshot
        self.baseline = baseline
        self.shiftBaseHourUTC = shiftBaseHourUTC
    }

    private func hourlyValue(_ series: [HourlyMetricPoint], shiftedHour: Int) -> HourlyMetricPoint? {
        let utcHour = ((shiftedHour % 24) + 24) % 24
        return series.first { $0.hourUTC == utcHour }
    }

    private var bandPoints: [HourlyBandPoint] {
        (0...11).map { offset in
            let hr = shiftBaseHourUTC + offset
            let sel = hourlyValue(snapshot.hourlySeries, shiftedHour: hr)
            let cls = baseline.flatMap { hourlyValue($0.hourlyBaselines, shiftedHour: hr) }

            let actual: Double
            let mu: Double
            let sigma: Double
            switch selectedTrack {
            case .loadS:
                actual = sel?.avgLoadDurationS ?? 0
                mu = cls?.avgLoadDurationS ?? 0
                sigma = cls?.avgLoadStdDevS ?? 0
            case .queueS:
                actual = sel?.avgQueueTimeS ?? 0
                mu = cls?.avgQueueTimeS ?? 0
                sigma = cls?.avgQueueStdDevS ?? 0
            case .hangPct:
                actual = (sel?.excavatorHangRatio ?? 0) * 100.0
                mu = (cls?.excavatorHangRatio ?? 0) * 100.0
                sigma = (cls?.excavatorHangStdDev ?? 0) * 100.0
            }
            return HourlyBandPoint(
                id: hr,
                hourIndex: hr,
                actual: actual,
                mean: mu,
                bandLow: max(0, mu - sigma),
                bandHigh: mu + sigma
            )
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Metric", selection: $selectedTrack) {
                    ForEach(CycleMetricTrack.allCases) { track in
                        Text(track.rawValue).tag(track)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)

                Spacer()

                HStack(spacing: 10) {
                    Text("Load \(OviusFormat.duration(seconds: snapshot.value(for: .avgLoadDurationS)))")
                    Text("Queue \(OviusFormat.duration(seconds: snapshot.value(for: .avgQueueTimeS)))")
                    Text("Hang \(OviusFormat.percentage(snapshot.value(for: .excavatorHangRatio)))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Chart(bandPoints) { pt in
                AreaMark(
                    x: .value("Hour", pt.hourIndex),
                    yStart: .value("μ - 1σ", pt.bandLow),
                    yEnd: .value("μ + 1σ", pt.bandHigh)
                )
                .foregroundStyle(Color.secondary.opacity(0.16))

                LineMark(
                    x: .value("Hour", pt.hourIndex),
                    y: .value("Cluster μ", pt.mean),
                    series: .value("Series", "Cluster μ")
                )
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))

                LineMark(
                    x: .value("Hour", pt.hourIndex),
                    y: .value("Selection", pt.actual),
                    series: .value("Series", "Selection")
                )
                .foregroundStyle(trackColor)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
                .symbol(.circle)
            }
            .chartXScale(domain: shiftBaseHourUTC...(shiftBaseHourUTC + 12))
            .chartXAxis {
                let tickValues = [0, 3, 6, 9, 12].map { shiftBaseHourUTC + $0 }
                AxisMarks(values: tickValues) { val in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hr = val.as(Int.self) {
                            Text(String(format: "%02d:00", ((hr % 24) + 24) % 24))
                        }
                    }
                }
            }
            .frame(height: 195)

            Text("Solid curve: Selection \(selectedTrack.rawValue) • Dashed curve & shaded band: Cluster hourly μ ± 1σ.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var trackColor: Color {
        switch selectedTrack {
        case .loadS: return .indigo
        case .queueS: return .orange
        case .hangPct: return .teal
        }
    }
}
