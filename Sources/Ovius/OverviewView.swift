import OviusCore
import Charts
import SwiftUI

/// The Dashboard: every finished run together, over a day, a week, a month or all of them: the ten figures against
/// the period before, each figure run by run, each cluster side by side, and the latest runs.
struct OverviewView: View {
    /// Opens a run.
    let open: (Int64) -> Void

    var body: some View {
        ScrollView {
            OverviewContent(open: open)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Dashboard")
    }
}

/// The page itself, without its scrolling (to render it whole).
struct OverviewContent: View {
    @Environment(AppModel.self) private var model
    let open: (Int64) -> Void
    /// Every site's when nil.
    @State private var kind: Period.Kind = .all
    /// The period picked; the latest with runs when nil.
    @State private var picked: Period?

    /// Every finished run, of any time.
    private var scoped: [Batch] {
        model.batches.filter { $0.metrics != nil }
    }

    /// When a run was: its cameras' clock, else when it was added.
    private func when(_ b: Batch) -> Date { Format.date(model.start(of: b)) ?? b.createdAt }

    var body: some View {
        let scoped = scoped
        let periods = kind == .all ? [Period.all] : Period.holding(scoped.map(when), kind)
        let current = picked.flatMap { p in periods.contains(p) ? p : nil } ?? periods.last ?? .all
        let done = scoped.filter { current.contains(when($0)) }
        let previous = kind == .all ? nil : periods.last { $0 < current }
        let before = previous.map { p in scoped.filter { p.contains(when($0)) } }
        let overview = Overview.of(done.compactMap(\.metrics))
        VStack(alignment: .leading, spacing: 26) {
            header(done)
            if !scoped.isEmpty {
                periodBar(periods: periods, current: current, previous: previous)
            }
            if done.isEmpty {
                ContentUnavailableView {
                    Label(model.recalculating ? "Working the Figures Out" : "No Finished Runs Yet", systemImage: "chart.bar.xaxis")
                } description: {
                    Text(model.recalculating
                         ? "The figures of the runs in the library are being worked out with this version's definitions."
                         : "Add a video from each camera of a cluster with New Analysis; once they are analysed, the cluster's figures add up here.")
                } actions: {
                    Button("New Analysis…") { model.showNewAnalysis = true }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                StatGrid(stats: Stats.cards(Stats.Figures(overview), against: before.map { Stats.Figures(Overview.of($0.compactMap(\.metrics))) },
                                            countsToo: true, m3PerLoad: model.settings.m3PerLoad,
                                            none: kind == .all ? "Pick a day, week or month to compare" : "No earlier \(kind.rawValue)",
                                            comparedWith: previous.map { "Against \(label($0)), the last \(kind.rawValue) before with runs: counts as they are, the rest averaged over the hours." }))
                TrendChart(batches: scoped, title: "Run by run")
                clusters(done)
                recent(done)
            }
        }
    }

    // MARK: Parts

    private func header(_ done: [Batch]) -> some View {
        let states = model.batches.map(model.state(of:))
        let running = states.filter { if case .running = $0 { true } else { $0 == .copying || $0 == .figuring } }.count
        let failed = states.filter { if case .partial = $0 { true } else { $0 == .failed } }.count
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard")
                    .font(.largeTitle.bold())
                HStack(spacing: 10) {
                    let o = Overview.of(done.compactMap(\.metrics))
                    Text("\(done.count) finished \(done.count == 1 ? "run" : "runs") of \(Set(done.map(\.clusterID)).count) \(Set(done.map(\.clusterID)).count == 1 ? "cluster" : "clusters")"
                         + (done.isEmpty ? "" : " · \(Format.hours(o.hours)) covered · \(Format.hours(o.cameraH)) of footage"))
                    if !done.isEmpty {
                        Info("Estimates from what the cameras saw: \(Format.hours(o.cameraH)) of footage from every camera together, covering \(Format.hours(o.hours)) of the clusters' time. Counts are of the footage, not scaled to a shift; rates and shares are averaged over the runs, each by its hours.")
                    }
                    let flagged = done.filter { !model.flags(for: $0).isEmpty }.count
                    if flagged > 0 { Pill(text: "\(flagged) \(flagged == 1 ? "run" : "runs") flagged", color: .orange) }
                    if running > 0 { Pill(text: "\(running) in progress", color: .blue) }
                    if failed > 0 { Pill(text: "\(failed) with failed cameras", color: .orange) }
                    if model.recalculating { Pill(text: "Working the figures out again", color: .blue) }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Day, week, month or all; the period shown, a step back or on; and what it is compared with.
    private func periodBar(periods: [Period], current: Period, previous: Period?) -> some View {
        let k = periods.firstIndex(of: current)
        return HStack(spacing: 12) {
            Picker("Period", selection: $kind) {
                Text("Day").tag(Period.Kind.day)
                Text("Week").tag(Period.Kind.week)
                Text("Month").tag(Period.Kind.month)
                Text("All").tag(Period.Kind.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            if kind != .all {
                Button { picked = k.map { periods[max(0, $0 - 1)] } } label: { Image(systemName: "chevron.left") }
                    .disabled(k == nil || k == 0)
                Text(label(current))
                    .font(.headline)
                    .monospacedDigit()
                Button { picked = k.map { periods[min(periods.count - 1, $0 + 1)] } } label: { Image(systemName: "chevron.right") }
                    .disabled(k == nil || k == periods.count - 1)
            }
            Spacer()
            Text(previous.map { "Compared with \(label($0)), the last \(kind.rawValue) before with runs" }
                 ?? (kind == .all ? "Every run: nothing to compare with" : "No earlier \(kind.rawValue) with runs"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .onChange(of: kind) { picked = nil }
    }

    /// 2 Feb 2024, the week of 29 Jan 2024, February 2024.
    private func label(_ p: Period) -> String {
        switch p.kind {
        case .day: p.start.formatted(date: .abbreviated, time: .omitted)
        case .week: "Week of \(p.start.formatted(date: .abbreviated, time: .omitted))"
        case .month: p.start.formatted(.dateTime.month(.wide).year())
        case .all: "All"
        }
    }

    /// Each cluster side by side.
    private func clusters(_ done: [Batch]) -> some View {
        let groups = Dictionary(grouping: done, by: \.clusterID)
            .map { id, list in (id: id, overview: Overview.of(list.compactMap(\.metrics)), latest: list.map { Format.date(model.start(of: $0)) ?? $0.createdAt }.max()) }
            .sorted { model.clusterTitle($0.id) < model.clusterTitle($1.id) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Clusters")
                .font(.headline)
            Wide {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        ForEach(["Cluster", "Runs", "Footage", "Cycles", "Estimated", "Per hour", "Load time", "Queue time", "Excavator use",
                                 "Truck use", "Latest"], id: \.self) {
                            Text($0).fixedSize()
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(groups, id: \.id) { g in
                        let avg = g.overview.average?.average ?? [:]
                        GridRow {
                            Text(model.clusterTitle(g.id))
                                .font(.body.weight(.semibold))
                                .fixedSize()
                            Cell("\(g.overview.analyses)")
                            Cell(Format.hours(g.overview.cameraH))
                            Cell("\(g.overview.cycles)")
                            Cell("\(g.overview.estimated)")
                            Cell(Format.value(.cyclesPerH, avg[.cyclesPerH]))
                            Cell(Format.value(.loadS, avg[.loadS]))
                            Cell(Format.value(.queueS, avg[.queueS]))
                            Cell(Format.percent(avg[.excavatorUtilPct]))
                            Cell(Format.percent(avg[.truckUtilPct]))
                            Cell(g.latest.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                        }
                        .monospacedDigit()
                    }
                }
            }
        }
    }

    /// The latest finished runs, each against the average of its cluster's earlier ones.
    private func recent(_ done: [Batch]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Latest runs")
                .font(.headline)
            RunColumns(first: "Cluster, and the run")
            RunList {
                ForEach(done.prefix(6)) { b in
                    Button { open(b.id) } label: {
                        RunRow(title: model.clusterTitle(b.clusterID), subtitle: "\(model.when(b)) · \(model.summary(of: b))", batch: b)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}
