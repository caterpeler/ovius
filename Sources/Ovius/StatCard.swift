import OviusCore
import SwiftUI

/// One figure at the top of a page: what it is (icon, title, a line on what it counts), its value, and how it
/// compares (the change, and what it is against), or a note when it is not compared.
struct Stat: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let value: String
    let unit: String
    var change: Comparison.Change?
    /// What it is compared with, formatted: 17,373 m³.
    var against: String?
    var note: String?
    var help: String?
    /// What the change (or the note) is against, under the pointer.
    var comparedWith: String?
    /// Why the figure is flagged as unusual, when it is.
    var flag: String?
}

/// The eight figures the Dashboard, a cluster's page and a run's page open with, in this order: load cycles, material
/// moved, excavator and dump truck utilisation, cycles and material per hour, load time and idle time. The hours they
/// come from are said in each page's heading.
enum Stats {
    /// What a set of analyses (or one) adds up to.
    struct Figures {
        var cycles: Int
        var observed: Int
        var estimated: Int
        var volumeM3: Double
        /// The periods the clusters' cameras covered, and every camera's footage together.
        var hours: Double
        var cameraH: Double
        /// The figures averaged over the hours.
        var kpi: [Kpi: Double]

        init(_ o: Overview) {
            cycles = o.cycles
            observed = o.observed
            estimated = o.estimated
            volumeM3 = o.volumeM3
            hours = o.hours
            cameraH = o.cameraH
            kpi = o.average?.average ?? [:]
        }

        init(_ m: ClusterMetrics) {
            cycles = m.total.cycles
            observed = m.total.observed
            estimated = m.total.estimated
            volumeM3 = m.total.volumeM3
            hours = m.total.durationH
            cameraH = m.summary.cameraH
            kpi = Dictionary(uniqueKeysWithValues: Kpi.allCases.compactMap { k in k.value(m.total).map { (k, $0) } })
        }

        /// The averages of earlier analyses, without counts: compared figure by figure, not added up.
        init(averages c: Comparison) {
            cycles = 0
            observed = 0
            estimated = 0
            volumeM3 = 0
            hours = c.hours
            cameraH = 0
            kpi = c.average
        }
    }

    /// The eight cards for `now`, against `then` when given. `countsToo` compares the counts (cycles, volume) as well
    /// as the averages: a period against another, not a run against the average of others. `none` is said where there
    /// is nothing to compare with; `comparedWith` says, under the pointer, what the changes are against.
    static func cards(_ now: Figures, against then: Figures?, countsToo: Bool, m3PerLoad: Double, none: String, comparedWith: String? = nil) -> [Stat] {
        func stat(_ id: String, _ icon: String, _ title: String, _ subtitle: String, _ value: (String, String), now: Double?, was: Double?,
                  inPoints: Bool = false, better: Bool?, counted: Bool, format: (Double) -> String, help: String? = nil) -> Stat {
            var s = Stat(id: id, icon: icon, title: title, subtitle: subtitle, value: value.0, unit: value.1, help: help)
            if counted, let now, let was {
                s.change = Comparison.Change.between(now, was, inPoints: inPoints, higherIsBetter: better)
                s.against = format(was)
            }
            if s.change == nil { s.note = counted ? none : nil }
            s.comparedWith = comparedWith
            return s
        }
        let counts = countsToo && then != nil
        let averaged = then != nil
        let idle = now.kpi[.excavatorIdleS]
        let truckIdle = now.kpi[.truckIdleS]
        return [
            stat("cycles", "arrow.triangle.2.circlepath", "Load cycles", "\(now.observed) observed + \(now.estimated) estimated",
                 (Format.number(Double(now.cycles), digits: 0), ""), now: Double(now.cycles), was: then.map { Double($0.cycles) }, better: true,
                 counted: counts, format: { Format.number($0, digits: 0) }, help: "Trucks loaded: seen whole (observed), or cut short by the video's start or end (estimated)."),
            stat("volume", "cube.box", "Material moved", "est. truck load: ~\(Format.number(m3PerLoad)) m³", (Format.number(now.volumeM3, digits: 0), "m³"),
                 now: now.volumeM3, was: then?.volumeM3, better: true, counted: counts, format: { Format.volume($0) },
                 help: "Load cycles × the volume of a load (Settings)."),
            kpi(.excavatorUtilPct, "gauge.with.needle", "Excavator utilisation", "working, of the time each was in view"),
            kpi(.truckUtilPct, "truck.box", "Dump truck utilisation", "spotting and loading, of time at the excavator"),
            kpi(.cyclesPerH, "speedometer", "Load cycles avg", "per hour of the cluster's time"),
            kpi(.volumePerH, "chart.bar", "Material moved avg", "per hour of the cluster's time"),
            kpi(.loadS, "timer", "Load time", "mean, from the first pass to the last"),
            stat("idle", "pause.circle", "Idle time", "excavator mean · dump truck \(Format.s(truckIdle))", seconds(idle), now: idle,
                 was: then?.kpi[.excavatorIdleS], better: false, counted: averaged, format: { Format.s($0) }, help: Kpi.excavatorIdleS.help),
        ]

        func kpi(_ k: Kpi, _ icon: String, _ title: String, _ subtitle: String) -> Stat {
            let value: (String, String)
            switch k {
            case .excavatorUtilPct, .truckUtilPct: value = (now.kpi[k].map { "\(Int($0.rounded()))" } ?? "—", now.kpi[k] == nil ? "" : "%")
            case .cyclesPerH: value = (Format.number(now.kpi[k]), now.kpi[k] == nil ? "" : "/h")
            case .volumePerH: value = (Format.number(now.kpi[k], digits: 0), now.kpi[k] == nil ? "" : "m³/h")
            default: value = seconds(now.kpi[k])
            }
            return stat(k.rawValue, icon, title, subtitle, value, now: now.kpi[k], was: then?.kpi[k], inPoints: k.isPercent, better: k.higherIsBetter,
                        counted: averaged, format: { Format.value(k, $0) }, help: k.help)
        }
    }

    /// The cards whose figure the run's flags find unusual, marked with what they say.
    static func flagged(_ stats: [Stat], _ flags: RunFlags, cluster: String) -> [Stat] {
        stats.map { stat in
            var stat = stat
            let mine = flags.unusual.filter { u in
                switch u.kpi {
                case .excavatorIdleS, .truckIdleS: stat.id == "idle"
                default: stat.id == u.kpi.rawValue
                }
            }
            if !mine.isEmpty {
                stat.flag = mine.map { "\(FlagText.title($0)). \(FlagText.detail($0, cluster: cluster))." }.joined(separator: "\n")
            }
            return stat
        }
    }

    private static func seconds(_ s: Double?) -> (String, String) {
        guard let s else { return ("—", "") }
        return ("\(Int(s.rounded()))", "s")
    }
}

/// The cards, four to a row.
struct StatGrid: View {
    let stats: [Stat]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 4), alignment: .leading, spacing: 12) {
            ForEach(stats) { StatCard(stat: $0) }
        }
    }
}

struct StatCard: View {
    let stat: Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: stat.icon)
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(stat.title)
                            .font(.headline)
                        if let flag = stat.flag { FlagMark(text: flag) }
                    }
                    Text(stat.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    value
                    Spacer(minLength: 8)
                    comparison
                }
                VStack(alignment: .leading, spacing: 4) {
                    value
                    comparison
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .help(stat.help ?? "")
    }

    private var value: some View {
        (Text(stat.value).font(.system(size: 30, weight: .semibold)) + Text(stat.unit).font(.system(size: 15, weight: .semibold)))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private var comparison: some View {
        if let change = stat.change {
            HStack(spacing: 4) {
                Image(systemName: change.by > 0 ? "arrow.up.right" : change.by < 0 ? "arrow.down.right" : "equal")
                Text(Format.change(change))
                if let against = stat.against {
                    Text("vs \(against)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(color(change.verdict))
            .lineLimit(1)
            .fixedSize()
            .help(stat.comparedWith ?? stat.help ?? "")
        } else if let note = stat.note {
            Text(note)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(stat.comparedWith ?? stat.help ?? "")
        }
    }

    private func color(_ verdict: Comparison.Verdict) -> Color {
        switch verdict {
        case .better: .green
        case .worse: .red
        case .same, .neither: .secondary
        }
    }
}
