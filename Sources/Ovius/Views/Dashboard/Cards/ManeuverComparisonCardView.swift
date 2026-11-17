import Charts
import SwiftUI

private struct ManeuverDeltaBar: Identifiable {
    let id: String
    let label: String
    let deltaPct: Double
}

private struct ManeuverHourlyPoint: Identifiable {
    let id: String
    let hourUTC: Int
    let metric: String
    let seconds: Double
}

/// Dedicated view for `CARD_MANEUVER_COMPARISON` (`DIAG_08_SPOT_DEPART_TREND`).
/// Pairs Spotting vs Departure pull-out deltas around a symmetry check plus hourly co-movement.
public struct ManeuverComparisonCardView: View {
    public let snapshot: SectionMetricsSnapshot
    public let baseline: ClusterBaselineStats?

    public init(snapshot: SectionMetricsSnapshot, baseline: ClusterBaselineStats?) {
        self.snapshot = snapshot
        self.baseline = baseline
    }

    public var body: some View {
        let spotActual = snapshot.value(for: .avgSpotTimeS)
        let depActual = snapshot.value(for: .avgDepartureLagS)
        let spotDelta = (baseline?.relativeDelta(for: .avgSpotTimeS, value: spotActual) ?? 0) * 100.0
        let depDelta = (baseline?.relativeDelta(for: .avgDepartureLagS, value: depActual) ?? 0) * 100.0

        let symmetryVerdict: (label: String, color: Color) = {
            if spotDelta >= 25 && depDelta < 15 {
                return ("Asymmetric Spot-Only Slowdown (Tight Pocket / Geometry)", .orange)
            } else if spotDelta >= 20 && depDelta >= 20 {
                return ("Symmetric Maneuver Drag (Weather / Traction Hazard)", .red)
            } else {
                return ("Symmetric / Within Normal Variance", .green)
            }
        }()

        let deltaBars = [
            ManeuverDeltaBar(id: "spot", label: "Spotting Δ%", deltaPct: spotDelta),
            ManeuverDeltaBar(id: "dep", label: "Departure Δ%", deltaPct: depDelta),
        ]

        let coMovement: [ManeuverHourlyPoint] = snapshot.hourlySeries.flatMap { p -> [ManeuverHourlyPoint] in
            guard (6...18).contains(p.hourUTC), (p.avgSpotDurationS > 0 || p.avgDepartureLagS > 0) else { return [] }
            return [
                ManeuverHourlyPoint(id: "s-\(p.hourUTC)", hourUTC: p.hourUTC, metric: "Spot (s)", seconds: p.avgSpotDurationS),
                ManeuverHourlyPoint(id: "d-\(p.hourUTC)", hourUTC: p.hourUTC, metric: "Depart (s)", seconds: p.avgDepartureLagS),
            ]
        }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(symmetryVerdict.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(symmetryVerdict.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(symmetryVerdict.color.opacity(0.12))
                    .clipShape(.rect(cornerRadius: 4))
                Spacer()
            }

            HStack(spacing: 16) {
                metricRow(title: "Spotting", key: .avgSpotTimeS)
                Divider().frame(height: 34)
                metricRow(title: "Departure", key: .avgDepartureLagS)
            }

            Chart(deltaBars) { bar in
                BarMark(
                    x: .value("Δ %", bar.deltaPct),
                    y: .value("Maneuver", bar.label)
                )
                .foregroundStyle(bar.deltaPct >= 25 ? Color.orange : Color.accentColor)
                .cornerRadius(3)

                RuleMark(x: .value("Zero", 0))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .chartXAxisLabel("Symmetry Check: % Δ vs. Cluster Baseline")
            .frame(height: 76)

            if !coMovement.isEmpty {
                Chart(coMovement) { pt in
                    LineMark(
                        x: .value("Hour (UTC)", pt.hourUTC),
                        y: .value("Seconds", pt.seconds)
                    )
                    .foregroundStyle(by: .value("Metric", pt.metric))
                }
                .chartForegroundStyleScale([
                    "Spot (s)": Color.indigo,
                    "Depart (s)": Color.teal,
                ])
                .frame(height: 95)
            }
        }
    }

    private func metricRow(title: String, key: MetricKey) -> some View {
        let actual = snapshot.value(for: key)
        let delta = baseline?.relativeDelta(for: key, value: actual)
        let z = baseline?.zScore(for: key, value: actual)

        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(OviusFormat.metricValue(actual, key: key))
                    .font(.callout.bold().monospacedDigit())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("Δ \(OviusFormat.signedDeltaPercentage(delta))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle((delta ?? 0) >= 0.30 ? Color.orange : Color.secondary)
                Text("Z \(OviusFormat.zScore(z))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
