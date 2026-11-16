import OviusCore
import SwiftUI

extension AppModel {
    /// The run's flags: against its cluster's other finished runs, and every other finished run.
    func flags(for batch: Batch) -> RunFlags {
        guard let m = batch.metrics else { return .none }
        let others = batches.filter { $0.id != batch.id && $0.metrics != nil }
        let missing: Int
        if case .partial(let n) = state(of: batch) { missing = n } else { missing = 0 }
        return RunFlags.of(total: m.total, cameras: m.cameras.map { ($0.name, $0.figures) }, missing: missing,
                           cluster: others.filter { $0.clusterID == batch.clusterID }.compactMap { $0.metrics?.total },
                           overall: others.compactMap { $0.metrics?.total })
    }
}

/// Flags in words.
enum FlagText {
    /// "Load time is higher than usual: 197 s".
    static func title(_ u: RunFlags.Unusual) -> String {
        "\(u.kpi.title) is \(u.higher ? "higher" : "lower") than usual: \(Format.value(u.kpi, u.value))"
    }

    /// "Usually 75–110 s in Section Beta (10 other runs), 60–120 s across all clusters (29 other runs)".
    static func detail(_ u: RunFlags.Unusual, cluster: String) -> String {
        "Usually " + u.against.map { usual in
            let range = Format.range(u.kpi, max(0, usual.low), usual.high)
            let runs = "\(usual.runs) other \(usual.runs == 1 ? "run" : "runs")"
            switch usual.scope {
            case .cluster: return "\(range) in \(cluster) (\(runs))"
            case .overall: return "\(range) across all clusters (\(runs))"
            }
        }.joined(separator: ", ")
    }

    static func check(_ c: RunFlags.Check) -> String {
        func names(_ list: [String]) -> String {
            list.count <= 2 ? list.joined(separator: " and ") : list.dropLast().joined(separator: ", ") + " and " + list.last!
        }
        switch c {
        case .camerasMissing(let n):
            return "\(n) \(n == 1 ? "camera" : "cameras") failed or \(n == 1 ? "was" : "were") stopped: the figures are of the others."
        case .noExcavator(let list):
            return "\(names(list)) saw no excavator."
        case .noCycles(let list):
            return "\(names(list)) saw excavators but no load cycles."
        case .mostlyEstimated(let estimated, let of):
            return "\(estimated) of \(of) cycles are estimated: their load times are drawn, not seen."
        case .shortFootage(let list):
            return "\(names(list))'s footage is under half the longest camera's: the cameras do not cover the same period."
        }
    }

    /// Every flag on a line of its own, for a tooltip.
    static func all(_ flags: RunFlags) -> String {
        (flags.unusual.map(title) + flags.checks.map(check)).joined(separator: "\n")
    }
}

/// A run's flags, at the top of its page: each unusual figure and what is usual, then what to check.
struct FlagList: View {
    let flags: RunFlags
    let cluster: String

    var body: some View {
        if !flags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.orange)
                    Text("\(flags.count) \(flags.count == 1 ? "thing" : "things") to look at")
                        .font(.headline)
                    Info("A figure is unusual outside the range a cluster's other runs (or every other run) usually fall in: their quartiles widened by \(Format.number(RunFlags.fence)) times the spread between them, and at least \(Int(RunFlags.leastChange * 100))% (\(Int(RunFlags.leastPoints)) points for a share) from their median. It takes \(RunFlags.leastRuns) other runs to know what is usual. Flags change as runs are added.")
                }
                ForEach(Array(flags.unusual.enumerated()), id: \.offset) { _, u in
                    line(icon: u.higher ? "arrow.up.right" : "arrow.down.right", color: color(u.verdict), title: FlagText.title(u),
                         detail: FlagText.detail(u, cluster: cluster))
                }
                ForEach(Array(flags.checks.enumerated()), id: \.offset) { _, c in
                    line(icon: "exclamationmark.triangle", color: .orange, title: FlagText.check(c), detail: nil)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
        }
    }

    private func line(icon: String, color: Color, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func color(_ verdict: Comparison.Verdict) -> Color {
        switch verdict {
        case .better: .green
        case .worse: .red
        case .same, .neither: .orange
        }
    }
}

/// A run's flags on its row: how many, and what, under the pointer.
struct FlagCount: View {
    let flags: RunFlags

    var body: some View {
        if !flags.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "flag.fill")
                Text("\(flags.count)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.15), in: Capsule())
            .help(FlagText.all(flags))
        }
    }
}

/// A flag's mark beside what it is about (a card's title, a camera's name), what it says under the pointer.
struct FlagMark: View {
    let text: String

    var body: some View {
        Image(systemName: "flag.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .help(text)
    }
}
