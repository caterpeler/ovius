import Charts
import SwiftUI

private struct IdleSpellSegmentBar: Identifiable {
    let id: String
    let spellLabel: String
    let component: String
    let seconds: Double
}

/// Dedicated view for `CARD_IDLE_ALLOWANCE_KPI` (`DIAG_10_IDLE_EXCESS_TIMELINE`).
/// Surfaces Business Rule 4.1 (`T_recorded_idle = T_stationary - idle_threshold_s`) + synced multi-machine halts.
public struct IdleAllowanceKPICardView: View {
    public let snapshot: SectionMetricsSnapshot
    public let baseline: ClusterBaselineStats?
    public let idleThresholdS: Int

    public init(snapshot: SectionMetricsSnapshot, baseline: ClusterBaselineStats?, idleThresholdS: Int) {
        self.snapshot = snapshot
        self.baseline = baseline
        self.idleThresholdS = idleThresholdS
    }

    public var body: some View {
        let maxExcess = snapshot.value(for: .trueIdleExcessS)
        let clusterExcessMu = baseline?.mean(for: .trueIdleExcessS)
        let topSpells = Array(snapshot.topIdleSpells.prefix(5))

        let bars: [IdleSpellSegmentBar] = topSpells.map { spell in
            let label = "\(spell.machineId) @\(Int(spell.startS))s" + (spell.isMultiMachineSynced ? " (×\(spell.syncedMachineCount))" : "")
            return [
                IdleSpellSegmentBar(id: "\(spell.id)-allow", spellLabel: label, component: "\(idleThresholdS)s Allowance", seconds: spell.allowanceS),
                IdleSpellSegmentBar(id: "\(spell.id)-excess", spellLabel: label, component: "Net Excess", seconds: spell.excessS),
            ]
        }.flatMap { $0 }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Max Continuous Net Idle (>\(idleThresholdS)s Allowance)")
                        .font(.subheadline.weight(.medium))
                    Text(OviusFormat.duration(seconds: maxExcess))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(maxExcess > 60 ? Color.orange : Color.primary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Cluster μ: \(OviusFormat.duration(seconds: clusterExcessMu))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("Cumulative Excess: \(OviusFormat.duration(seconds: snapshot.totalPostAllowanceIdleS))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                Label("Synced Halts: \(snapshot.syncedStoppageWindowCount)", systemImage: "exclamationmark.2")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(snapshot.syncedStoppageWindowCount > 0 ? Color.orange : Color.secondary)
                Spacer()
                Text("Excavator Hang Share: \(OviusFormat.percentage(snapshot.value(for: .excavatorHangRatio)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !bars.isEmpty {
                Divider()
                Chart(bars) { bar in
                    BarMark(
                        x: .value("Seconds", bar.seconds),
                        y: .value("Spell", bar.spellLabel)
                    )
                    .foregroundStyle(by: .value("Part", bar.component))
                }
                .chartForegroundStyleScale([
                    "\(idleThresholdS)s Allowance": Color.secondary.opacity(0.35),
                    "Net Excess": Color.orange,
                ])
                .chartXAxisLabel("Top Stationary Spells (Rule 4.1)")
                .frame(height: CGFloat(max(110, topSpells.count * 26 + 32)))
            }
        }
        .padding(.vertical, 4)
    }
}
