import Charts
import SwiftUI

private struct CyclePhaseStackEntry: Identifiable {
    let id: String
    let cohort: String
    let phase: String
    let seconds: Double
}

private struct PhaseAttributionRow: Identifiable {
    var id: String { label }
    let label: String
    let actualS: Double
    let baselineS: Double?
    let deltaRatio: Double?
    let sharePct: Double
}

/// Dedicated view for `CARD_CYCLE_PHASE_STACK` (`DIAG_07_PHASE_BREAKDOWN`).
public struct CyclePhaseStackCardView: View {
    public let snapshot: SectionMetricsSnapshot
    public let baseline: ClusterBaselineStats?

    public init(snapshot: SectionMetricsSnapshot, baseline: ClusterBaselineStats?) {
        self.snapshot = snapshot
        self.baseline = baseline
    }

    private var entries: [CyclePhaseStackEntry] {
        let phases: [(String, MetricKey)] = [
            ("Queue", .avgQueueTimeS),
            ("Spot", .avgSpotTimeS),
            ("Load", .avgLoadDurationS),
            ("Depart", .avgDepartureLagS),
        ]
        var list: [CyclePhaseStackEntry] = []
        for (label, key) in phases {
            list.append(CyclePhaseStackEntry(id: "sel-\(label)", cohort: "Observed", phase: label, seconds: snapshot.value(for: key)))
            list.append(CyclePhaseStackEntry(id: "cls-\(label)", cohort: "Cluster μ", phase: label, seconds: baseline?.mean(for: key) ?? 0))
        }
        return list
    }

    private var attributionRows: [PhaseAttributionRow] {
        let phases: [(String, MetricKey)] = [
            ("Queue", .avgQueueTimeS),
            ("Spot", .avgSpotTimeS),
            ("Load", .avgLoadDurationS),
            ("Depart", .avgDepartureLagS),
        ]
        let totalExcessDelay = phases.reduce(0.0) { acc, item in
            let actual = snapshot.value(for: item.1)
            let mu = baseline?.mean(for: item.1) ?? 0
            return acc + max(0.0, actual - mu)
        }
        let totalObserved = max(1e-6, phases.reduce(0.0) { $0 + snapshot.value(for: $1.1) })

        return phases.map { label, key in
            let actual = snapshot.value(for: key)
            let mu = baseline?.mean(for: key)
            let delta = baseline?.relativeDelta(for: key, value: actual)
            let share: Double
            if totalExcessDelay > 1e-6, let mu {
                share = max(0.0, actual - mu) / totalExcessDelay
            } else {
                share = actual / totalObserved
            }
            return PhaseAttributionRow(label: label, actualS: actual, baselineS: mu, deltaRatio: delta, sharePct: share * 100.0)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart(entries) { entry in
                BarMark(
                    x: .value("Seconds", entry.seconds),
                    y: .value("Cohort", entry.cohort)
                )
                .foregroundStyle(by: .value("Phase", entry.phase))
            }
            .chartForegroundStyleScale([
                "Queue": Color.orange,
                "Spot": Color.indigo,
                "Load": Color.blue,
                "Depart": Color.teal,
            ])
            .chartXAxisLabel("Cumulative Cycle Phase Time (s)")
            .frame(height: 110)

            Divider()

            // Phase Delay Attribution Table
            VStack(spacing: 4) {
                HStack {
                    Text("Phase").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Obs (s)").frame(width: 65, alignment: .trailing)
                    Text("Cluster μ").frame(width: 65, alignment: .trailing)
                    Text("Δ %").frame(width: 60, alignment: .trailing)
                    Text("Delay Share").frame(width: 72, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(attributionRows) { row in
                    HStack {
                        Text(row.label).font(.caption.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(OviusFormat.duration(seconds: row.actualS)).frame(width: 65, alignment: .trailing)
                        Text(OviusFormat.duration(seconds: row.baselineS)).frame(width: 65, alignment: .trailing).foregroundStyle(.secondary)
                        Text(OviusFormat.signedDeltaPercentage(row.deltaRatio))
                            .frame(width: 60, alignment: .trailing)
                            .foregroundStyle((row.deltaRatio ?? 0) >= 0.25 ? Color.orange : Color.secondary)
                        Text(String(format: "%.0f%%", row.sharePct))
                            .frame(width: 72, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }
}
