import Charts
import SwiftUI

private struct ExcavatorAllocRow: Identifiable {
    let id: String
    let cohort: String
    let stateLabel: String
    let sharePct: Double
}

/// Dedicated view for `CARD_EXCAVATOR_STATE_BAR` (`DIAG_03_EXCAVATOR_STATES`).
public struct ExcavatorStateBarCardView: View {
    public let snapshot: SectionMetricsSnapshot
    public let baseline: ClusterBaselineStats?

    public init(snapshot: SectionMetricsSnapshot, baseline: ClusterBaselineStats?) {
        self.snapshot = snapshot
        self.baseline = baseline
    }

    private var entries: [ExcavatorAllocRow] {
        let secHang = snapshot.value(for: .excavatorHangRatio) * 100.0
        let secActive = max(0, 100.0 - secHang)
        let clsHang = (baseline?.mean(for: .excavatorHangRatio) ?? 0) * 100.0
        let clsActive = max(0, 100.0 - clsHang)

        let split = snapshot.excavatorPocketSplit
        let emptyTotal = split.emptyPocketActiveS + split.emptyPocketIdleS
        let emptyIdlePct = emptyTotal > 0 ? (split.emptyPocketIdleS / emptyTotal) * 100.0 : 0
        let emptyActivePct = emptyTotal > 0 ? 100.0 - emptyIdlePct : 0

        let spotTotal = split.spottedActiveS + split.spottedIdleS
        let spotIdlePct = spotTotal > 0 ? (split.spottedIdleS / spotTotal) * 100.0 : 0
        let spotActivePct = spotTotal > 0 ? 100.0 - spotIdlePct : 0

        var rows = [
            ExcavatorAllocRow(id: "sel-a", cohort: "Overall Selection", stateLabel: "Active Loading / Prep", sharePct: secActive),
            ExcavatorAllocRow(id: "sel-i", cohort: "Overall Selection", stateLabel: "Idle Hang", sharePct: secHang),
            ExcavatorAllocRow(id: "cls-a", cohort: "Cluster μ", stateLabel: "Active Loading / Prep", sharePct: clsActive),
            ExcavatorAllocRow(id: "cls-i", cohort: "Cluster μ", stateLabel: "Idle Hang", sharePct: clsHang),
        ]
        if emptyTotal > 0 {
            rows.append(ExcavatorAllocRow(id: "emp-a", cohort: "No Truck in Pocket", stateLabel: "Active Loading / Prep", sharePct: emptyActivePct))
            rows.append(ExcavatorAllocRow(id: "emp-i", cohort: "No Truck in Pocket", stateLabel: "Idle Hang", sharePct: emptyIdlePct))
        }
        if spotTotal > 0 {
            rows.append(ExcavatorAllocRow(id: "spt-a", cohort: "Truck Spotted", stateLabel: "Active Loading / Prep", sharePct: spotActivePct))
            rows.append(ExcavatorAllocRow(id: "spt-i", cohort: "Truck Spotted", stateLabel: "Idle Hang", sharePct: spotIdlePct))
        }
        return rows
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.totalSegmentCount == 0 {
                ContentUnavailableView(
                    "No State Segments Cached",
                    systemImage: "pause.circle",
                    description: Text("Narrow filters or open a recording in Data Explorer to inspect state shares.")
                )
                .frame(height: 190)
            } else {
                Chart(entries) { entry in
                    BarMark(
                        x: .value("Share (%)", entry.sharePct),
                        y: .value("Cohort", entry.cohort)
                    )
                    .foregroundStyle(by: .value("State", entry.stateLabel))
                }
                .chartForegroundStyleScale([
                    "Active Loading / Prep": Color.blue.opacity(0.85),
                    "Idle Hang": Color.orange.opacity(0.9),
                ])
                .chartXScale(domain: 0...100)
                .frame(height: 185)

                let split = snapshot.excavatorPocketSplit
                HStack(spacing: 12) {
                    Text("Hang: \(OviusFormat.percentage(snapshot.value(for: .excavatorHangRatio))) vs Cluster μ \(OviusFormat.percentage(baseline?.mean(for: .excavatorHangRatio)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Empty Idle: \(OviusFormat.duration(seconds: split.emptyPocketIdleS)) • Spotted Idle: \(OviusFormat.duration(seconds: split.spottedIdleS))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
