import Charts
import SwiftUI

/// Dedicated view for `CARD_HOURLY_PRODUCTIVITY_TREND` (`DIAG_13_HOURLY_PRODUCTIVITY`).
public struct HourlyProductivityTrendCardView: View {
    public let snapshot: SectionMetricsSnapshot
    public let baseline: ClusterBaselineStats?
    public let shiftBaseHourUTC: Int

    public init(snapshot: SectionMetricsSnapshot, baseline: ClusterBaselineStats?, shiftBaseHourUTC: Int = 6) {
        self.snapshot = snapshot
        self.baseline = baseline
        self.shiftBaseHourUTC = shiftBaseHourUTC
    }

    private var shiftHours: [Int] {
        (0...11).map { shiftBaseHourUTC + $0 }
    }

    private func hourlyValue(_ series: [HourlyMetricPoint], shiftedHour: Int) -> HourlyMetricPoint? {
        let utcHour = ((shiftedHour % 24) + 24) % 24
        return series.first { $0.hourUTC == utcHour }
    }

    public var body: some View {
        let points: [(hourIndex: Int, selVol: Double, clsVol: Double, isEdge: Bool, isBreak: Bool, arrRate: Double)] = shiftHours.map { hr in
            let s = hourlyValue(snapshot.hourlySeries, shiftedHour: hr)
            let c = baseline.flatMap { hourlyValue($0.hourlyBaselines, shiftedHour: hr) }
            return (
                hourIndex: hr,
                selVol: s?.volumetricRateM3Hr ?? 0,
                clsVol: c?.volumetricRateM3Hr ?? 0,
                isEdge: s?.isShiftEdge ?? false,
                isBreak: s?.isBreakWindow ?? false,
                arrRate: s?.truckArrivalRateHr ?? 0
            )
        }

        let startupVol = points.first?.selVol ?? 0
        let closingVol = points.last?.selVol ?? 0
        let breakOverrun = snapshot.value(for: .breakWindowIdleExcessS)

        VStack(alignment: .leading, spacing: 10) {
            // Shift Window Audit Strip
            HStack(spacing: 14) {
                auditStat(title: "Startup Hr", value: OviusFormat.metricValue(startupVol, key: .volumetricRateM3Hr))
                auditStat(title: "Closing Hr", value: OviusFormat.metricValue(closingVol, key: .volumetricRateM3Hr))
                auditStat(title: "Break Overrun", value: OviusFormat.duration(seconds: breakOverrun), highlight: breakOverrun > 600)
                auditStat(title: "Arrival Rate", value: OviusFormat.metricValue(snapshot.value(for: .truckArrivalRateHr), key: .truckArrivalRateHr))
            }

            Chart {
                ForEach(points, id: \.hourIndex) { item in
                    if item.isBreak {
                        RectangleMark(xStart: .value("Start", item.hourIndex), xEnd: .value("End", item.hourIndex + 1))
                            .foregroundStyle(Color.orange.opacity(0.14))
                    } else if item.isEdge {
                        RectangleMark(xStart: .value("Start", item.hourIndex), xEnd: .value("End", item.hourIndex + 1))
                            .foregroundStyle(Color.indigo.opacity(0.08))
                    }

                    BarMark(
                        x: .value("Hour", item.hourIndex),
                        y: .value("Selection m³/hr", item.selVol),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.80))
                    .cornerRadius(3)
                }

                ForEach(points, id: \.hourIndex) { item in
                    LineMark(
                        x: .value("Hour", item.hourIndex),
                        y: .value("Cluster μ m³/hr", item.clsVol)
                    )
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .symbol(.circle)
                }
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

            Text("Bars: Selection hourly output (m³/hr) • Dashed curve: Cluster hourly μ. Shading highlights 60m Startup/Closing edges & Midday Break.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func auditStat(title: String, value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(highlight ? Color.orange : Color.primary)
        }
    }
}
