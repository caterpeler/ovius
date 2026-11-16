import OviusCore
import Charts
import SwiftUI

/// Where the Clusters page has got to: a cluster's overview, then one of its runs.
enum ClusterRoute: Hashable {
    case cluster(Int64)
    case run(Int64)
}

// MARK: Rows

/// The figures a run's row shows, as the columns' widths line up with the header's.
private let figureWidth: CGFloat = 108

/// The header over rows of runs: what the first column is, then the figures.
struct RunColumns: View {
    let first: String

    var body: some View {
        HStack(spacing: 16) {
            Text(first)
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            ForEach(["Load cycles", "Material moved", "Excavator use", "Cycles per hour"], id: \.self) { title in
                Text(title)
                    .frame(width: figureWidth, alignment: .trailing)
            }
            Image(systemName: "chevron.right")
                .hidden()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
    }
}

/// A run (or a cluster, by its latest run) on one line: what it is, then its figures, the shares and rates against
/// the cluster's earlier runs; or where it is while it runs.
struct RunRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String
    /// The run whose figures show; nil when there is none.
    let batch: Batch?

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if let batch, case .partial(let missing) = model.state(of: batch) {
                        Pill(text: "\(missing) failed", color: .orange)
                    }
                    if let batch {
                        FlagCount(flags: model.flags(for: batch))
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            if let batch, let t = batch.metrics?.total {
                let c = model.comparison(for: batch)
                figure("\(t.cycles)", below: "\(t.observed) + \(t.estimated) est.")
                figure(Format.volume(t.volumeM3), below: nil)
                figure(Format.percent(t.excavatorUtilPct), change: c?.change(.excavatorUtilPct, t))
                figure(Format.value(.cyclesPerH, Kpi.cyclesPerH.value(t)), change: c?.change(.cyclesPerH, t))
            } else if let batch {
                BatchStatus(batch: batch)
                    .frame(width: 4 * figureWidth + 48, alignment: .trailing)
            } else {
                Text("No runs yet")
                    .foregroundStyle(.tertiary)
                    .frame(width: 4 * figureWidth + 48, alignment: .trailing)
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
    }

    private func figure(_ value: String, below: String?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
            Text(below ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(width: figureWidth, alignment: .trailing)
    }

    private func figure(_ value: String, change: Comparison.Change?) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
            Group {
                if let change {
                    Text(Format.change(change))
                        .foregroundStyle(change.verdict == .better ? .green : change.verdict == .worse ? .red : .secondary)
                } else {
                    Text(" ")
                }
            }
            .font(.caption.monospacedDigit())
            .help("Against the average of the cluster's earlier runs")
        }
        .lineLimit(1)
        .frame(width: figureWidth, alignment: .trailing)
    }
}

/// Rows, one under another, in a box.
struct RunList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension AppModel {
    /// When a run was: its cameras' clock (2 Feb 2024, 16:00), else when it was added.
    func when(_ batch: Batch) -> String {
        start(of: batch) == nil ? "Added \(batch.createdAt.formatted(date: .abbreviated, time: .shortened))" : Format.clock(start(of: batch))
    }

    /// "1 camera · 3 min of footage", "3 cameras · 15 min covered · 22 min of footage".
    func summary(of batch: Batch) -> String {
        let cameras = analyses(of: batch).count
        var parts = ["\(cameras) \(cameras == 1 ? "camera" : "cameras")"]
        if let m = batch.metrics {
            if cameras > 1 { parts.append("\(Format.hours(m.total.durationH)) covered") }
            parts.append("\(Format.hours(m.summary.cameraH)) of footage")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: Clusters

/// Every cluster, each with its latest run.
struct ClustersHome: View {
    @Environment(AppModel.self) private var model
    let open: (Int64) -> Void

    var body: some View {
        ScrollView {
            ClustersContent(open: open)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Clusters")
    }
}

/// New Analysis and Import Results, as a page's actions.
struct AddRunButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.showImportResults = true } label: { Label("Import Results", systemImage: "square.and.arrow.down") }
            .buttonStyle(.page)
            .help("Results a pipeline wrote elsewhere, a folder per camera (⇧⌘R)")
        Button { model.showNewAnalysis = true } label: { Label("New Analysis", systemImage: "plus") }
            .buttonStyle(.page)
            .help("Analyse a cluster's footage (⌘N)")
    }
}

/// The page itself, without its scrolling (to render it whole).
struct ClustersContent: View {
    @Environment(AppModel.self) private var model
    let open: (Int64) -> Void

    var body: some View {
        let clusters = model.clusters.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Clusters",
                       subtitle: "\(clusters.count) \(clusters.count == 1 ? "cluster" : "clusters") · \(model.batches.count) \(model.batches.count == 1 ? "run" : "runs")") {
                AddRunButtons()
            }
            if clusters.isEmpty {
                ContentUnavailableView {
                    Label("No Clusters Yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("A cluster is a section of the mine; each of its cameras watches a different part of it. Clusters are made with their first footage.")
                } actions: {
                    Button("New Analysis…") { model.showNewAnalysis = true }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    RunColumns(first: "Cluster, and its latest run")
                    RunList {
                        ForEach(clusters) { cluster in
                            Button { open(cluster.id) } label: {
                                RunRow(title: cluster.name, subtitle: subtitle(cluster), batch: model.latestFinished(of: cluster.id) ?? model.runs(of: cluster.id).first)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// "3 cameras · 2 runs · latest: 2 Feb 2024, 16:00", and a run in progress.
    private func subtitle(_ cluster: Cluster) -> String {
        let cameras = model.cameras.filter { $0.clusterID == cluster.id }.count
        let runs = model.runs(of: cluster.id)
        var parts = ["\(cameras) \(cameras == 1 ? "camera" : "cameras")", "\(runs.count) \(runs.count == 1 ? "run" : "runs")"]
        if let latest = model.latestFinished(of: cluster.id) { parts.append("latest: \(model.when(latest))") }
        if let newest = runs.first, newest.metrics == nil, newest.id != model.latestFinished(of: cluster.id)?.id {
            switch model.state(of: newest) {
            case .failed, .stopped: break
            default: parts.append("a run in progress")
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: A cluster

/// A cluster: its runs together, each of them, run by run, and its cameras.
struct ClusterPage: View {
    @Environment(AppModel.self) private var model
    let cluster: Cluster
    /// Opens a run.
    let open: (Int64) -> Void
    /// Back to the clusters; also once the cluster is deleted.
    let close: () -> Void
    @State private var renaming = false
    @State private var deleting = false

    var body: some View {
        ScrollView {
            ClusterContent(cluster: cluster, open: open, back: PageBack(to: "Clusters", action: close), renaming: $renaming, deleting: $deleting)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(cluster.name)
        .sheet(isPresented: $renaming) { RenameCluster(cluster: cluster) }
        .confirmationDialog("Delete \(cluster.name) and its cameras?", isPresented: $deleting) {
            Button("Delete", role: .destructive) {
                close()
                model.delete(cluster)
            }
        }
    }
}

/// The page itself, without its scrolling (to render it whole).
struct ClusterContent: View {
    @Environment(AppModel.self) private var model
    let cluster: Cluster
    let open: (Int64) -> Void
    var back: PageBack?
    /// Asks for the cluster's renaming and deleting, which the page around it does.
    var renaming: Binding<Bool> = .constant(false)
    var deleting: Binding<Bool> = .constant(false)
    @State private var renamingCamera: Camera?
    /// The runs as a calendar, or as a list.
    @State private var asCalendar = true
    @State private var newName = ""

    var body: some View {
        let cameras = model.cameras.filter { $0.clusterID == cluster.id }
        let runs = model.runs(of: cluster.id)
        let finished = runs.filter { $0.metrics != nil }
        let together = Overview.of(finished.compactMap(\.metrics))
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(back: back, title: cluster.name,
                       subtitle: ([("\(cameras.count) \(cameras.count == 1 ? "camera" : "cameras")"), "\(runs.count) \(runs.count == 1 ? "run" : "runs")"]
                                  + (finished.isEmpty ? [] : ["\(Format.hours(together.hours)) covered", "\(Format.hours(together.cameraH)) of footage"])).joined(separator: " · "),
                       info: finished.isEmpty ? nil : finished.count == 1
                           ? "The figures are of its one finished run. Later runs are compared with the runs before them, on their pages."
                           : "The figures are of its \(finished.count) finished runs together: counts added up, the rest averaged over the runs, each by its hours. Each run's page compares it with the runs before it. Counts are of the footage, not scaled to a shift.") {
                AddRunButtons()
                Button { renaming.wrappedValue = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.page)
                    .help("Rename the cluster…")
                Button(role: .destructive) { deleting.wrappedValue = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.page)
                    .disabled(!runs.isEmpty)
                    .help(runs.isEmpty ? "Delete the cluster and its cameras…" : "A cluster with runs cannot be deleted: delete its runs first.")
            }
            if !finished.isEmpty {
                StatGrid(stats: Stats.cards(Stats.Figures(together), against: nil, countsToo: false, m3PerLoad: model.settings.m3PerLoad, none: ""))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Runs")
                        .font(.headline)
                    Spacer()
                    if !runs.isEmpty {
                        ModeSwitch(mode: $asCalendar, modes: [(true, "Calendar", "calendar"), (false, "List", "list.bullet")])
                    }
                }
                if runs.isEmpty {
                    Text("None yet: add a video from each camera, covering the same period, with New Analysis (⌘N).")
                        .foregroundStyle(.secondary)
                } else if asCalendar {
                    RunCalendar(runs: runs, open: open)
                } else {
                    RunColumns(first: "Run")
                    RunList {
                        ForEach(runs) { batch in
                            Button { open(batch.id) } label: {
                                RunRow(title: model.when(batch), subtitle: model.summary(of: batch), batch: batch)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { BatchActions(batch: batch) }
                            Divider()
                        }
                    }
                }
            }
            if finished.count > 1 {
                TrendChart(batches: finished, title: "Run by run")
            }
            cameraList(cameras)
        }
        .alert("Rename Camera", isPresented: Binding(get: { renamingCamera != nil }, set: { if !$0 { renamingCamera = nil } })) {
            TextField("Camera", text: $newName)
            Button("Rename") { if let camera = renamingCamera { model.rename(camera, name: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func cameraList(_ cameras: [Camera]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cameras")
                .font(.headline)
            if cameras.isEmpty {
                Text("None yet: cameras are made with their footage.")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 10) {
                ForEach(cameras) { camera in
                    let used = model.analyses.filter { $0.cameraID == camera.id }.count
                    HStack(spacing: 10) {
                        Image(systemName: "video")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(camera.name)
                                .font(.body.weight(.medium))
                            Text("\(used) \(used == 1 ? "video" : "videos") analysed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button("Rename…") {
                                newName = camera.name
                                renamingCamera = camera
                            }
                            Button("Delete", role: .destructive) { model.delete(camera) }
                                .disabled(used > 0)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct RenameCluster: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let cluster: Cluster
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Cluster", text: $name)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.rename(cluster, name: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 380)
        .onAppear { name = cluster.name }
    }
}

// MARK: Run by run

/// One figure (picked), run by run, on the cameras' clock (or in the order added, without one), a line per cluster,
/// with their average.
struct TrendChart: View {
    @Environment(AppModel.self) private var model
    let batches: [Batch]
    let title: String
    @State private var trend: Kpi = .cyclesPerH

    private struct Point: Identifiable {
        let id: Int64
        let order: Int
        let when: Date
        let value: Double
        let cluster: String
    }

    var body: some View {
        let byClock = batches.allSatisfy { Format.date(model.start(of: $0)) != nil }
        let points = batches
            .sorted { byClock ? Format.date(model.start(of: $0))! < Format.date(model.start(of: $1))! : $0.id < $1.id }
            .enumerated()
            .compactMap { k, b -> Point? in
                guard let value = b.metrics.flatMap({ trend.value($0.total) }) else { return nil }
                return Point(id: b.id, order: k + 1, when: Format.date(model.start(of: b)) ?? b.createdAt, value: value, cluster: model.clusterTitle(b.clusterID))
            }
        let average = Comparison.of(batches.compactMap { $0.metrics?.total })?.average[trend]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Picker("Figure", selection: $trend) {
                    ForEach(Kpi.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 230)
            }
            Chart {
                ForEach(points) { p in
                    if byClock {
                        LineMark(x: .value("When", p.when), y: .value(trend.title, p.value), series: .value("Cluster", p.cluster))
                            .foregroundStyle(by: .value("Cluster", p.cluster))
                            .opacity(0.5)
                        PointMark(x: .value("When", p.when), y: .value(trend.title, p.value))
                            .foregroundStyle(by: .value("Cluster", p.cluster))
                    } else {
                        LineMark(x: .value("Run", p.order), y: .value(trend.title, p.value), series: .value("Cluster", p.cluster))
                            .foregroundStyle(by: .value("Cluster", p.cluster))
                            .opacity(0.5)
                        PointMark(x: .value("Run", p.order), y: .value(trend.title, p.value))
                            .foregroundStyle(by: .value("Cluster", p.cluster))
                    }
                }
                if let average {
                    RuleMark(y: .value("Average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("average \(Format.value(trend, average))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text(value.as(Double.self).map { Format.value(trend, $0) } ?? "") }
                }
            }
            .chartXAxisLabel(byClock ? "" : "Runs, in the order added (their times are unknown)")
            .frame(height: 220)
        }
    }
}
