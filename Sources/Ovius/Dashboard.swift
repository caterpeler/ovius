import OviusCore
import Charts
import SwiftUI

/// A run's figures, the team's: the eight cards (against the cluster's earlier runs), the Recording Overview (a row
/// per camera and the cluster's total), the excavators' states (with a state model), how the estimated cycles were
/// completed, and each camera's trips. Their explanations show under the pointer.
struct Dashboard: View {
    @Environment(AppModel.self) private var model
    let batch: Batch
    let metrics: ClusterMetrics
    /// Each camera's analysis's start, on the camera's clock.
    let starts: [Int64: String?]
    let comparison: Comparison?

    var body: some View {
        let flags = model.flags(for: batch)
        let cluster = model.clusterTitle(batch.clusterID)
        VStack(alignment: .leading, spacing: 26) {
            FlagList(flags: flags, cluster: cluster)
            StatGrid(stats: Stats.flagged(Stats.cards(Stats.Figures(metrics), against: comparison.map { Stats.Figures(averages: $0) }, countsToo: false,
                                                      m3PerLoad: metrics.summary.m3PerLoad, none: "No earlier run", comparedWith: against),
                                          flags, cluster: cluster))
            RecordingOverview(metrics: metrics, flags: flags)
            ExcavatorStates(metrics: metrics)
            if metrics.total.estimated > 0 {
                Estimation(metrics: metrics)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Trips", help: "Each camera's cycles, truck by truck. Times are on the camera's clock where its video's start is known, else into the video. Arrived: into the loading area; a truck already there when the video began has none.")
                ForEach(metrics.cameras) { camera in
                    Trips(camera: camera, start: starts[camera.analysis] ?? nil)
                }
            }
        }
    }

    /// What the cards' changes are against.
    private var against: String {
        guard let comparison else { return "The first run of this cluster: later ones are compared with it." }
        return "Against the average of the \(comparison.count) earlier \(comparison.count == 1 ? "run" : "runs") of this cluster (\(Format.hours(comparison.hours)) of the cluster's time), each weighted by its hours. Counts are not compared: they follow the hours."
    }

    /// What the figures are estimates from: the run's heading shows it under the pointer.
    static func estimates(_ metrics: ClusterMetrics) -> String {
        let s = metrics.summary
        let cameras = metrics.cameras.count
        return "Estimates from what \(cameras) \(cameras == 1 ? "camera" : "cameras") saw: \(Format.hours(s.cameraH)) of footage"
            + (cameras > 1 ? " in all, over a \(Format.hours(metrics.total.durationH)) period." : ".")
            + " \(Format.cycles(s.cycles, observed: s.observed, estimated: s.estimated)). An estimated cycle is a load the video's start or end cut short, its load time drawn as How estimated cycles are completed sets out. Counts are of the footage, not scaled to a shift. Trucks driving past are not cycles; the pipeline gives no count of them."
    }
}

/// What each excavator was doing, by the state model's states: its time seen in each.
private struct ExcavatorStates: View {
    let metrics: ClusterMetrics

    private struct Part: Identifiable {
        let id = UUID()
        let excavator: String
        let state: String
        let share: Double
    }

    var body: some View {
        let each = metrics.cameras.flatMap { camera in
            camera.excavators.compactMap { e in e.states.map { ("\(camera.name) · \(e.point)", $0) } }
        }
        if !each.isEmpty {
            let all = Dictionary(each.flatMap(\.1).map { ($0.state, $0.s) }, uniquingKeysWith: +)
                .map { Excavator.StateTime(state: $0.key, s: $0.value) }
                .sorted { $0.s > $1.s }
            let rows = (each.count > 1 ? [("All excavators", all)] : []) + each
            let parts = rows.flatMap { name, states in
                let seen = states.reduce(0) { $0 + $1.s }
                return states.map { Part(excavator: name, state: $0.state, share: seen > 0 ? 100 * $0.s / seen : 0) }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Excavator states", help: "From the state model: the share of the time each excavator was seen in each state. Its idle states (Settings) count as idle in the figures above; the others as working.")
                Chart(parts) { part in
                    BarMark(x: .value("Share", part.share), y: .value("Excavator", part.excavator))
                        .foregroundStyle(by: .value("State", part.state))
                }
                .chartXScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                    }
                }
                .frame(height: CGFloat(rows.count) * 34 + 50)
            }
        }
    }
}

/// The Recording Overview, laid out as the team's: a row per camera and the cluster's total; load, queue and excavator
/// idle times as mean and standard deviation; excavator and dump truck utilisation; volume moved. It fills the width:
/// each column grows from its least, the header and the rows made of the same parts so their columns line up.
private struct RecordingOverview: View {
    let metrics: ClusterMetrics
    /// Its checks mark the cameras they name.
    var flags: RunFlags = .none

    /// The columns' least widths.
    private let camera: CGFloat = 120
    private let cycles: CGFloat = 84
    private let number: CGFloat = 56
    private let share: CGFloat = 80
    private let volume: CGFloat = 100
    private let rowHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Recording overview", help: "Idle Time is the excavators'; hold the pointer over it for the dump trucks'. Queue Time is of the trucks that queued. Utilization is working, of the time in view (excavators), or spotting and loading, of the time at the excavator (dump trucks). Load Cycles includes the estimated ones, said beside it. Total: cycles and volume added up, the mean load time of the cameras with cycles, the other figures averaged over the cameras, as the team's sheet does.")
            VStack(spacing: 0) {
                header
                ForEach(Array(metrics.cameras.enumerated()), id: \.element.id) { k, camera in
                    Divider()
                    row(camera.name, camera.figures)
                        .background(k % 2 == 1 ? Color.primary.opacity(0.035) : Color.clear)
                }
                Divider()
                row("Total", metrics.total)
                    .fontWeight(.semibold)
                    .background(Color.primary.opacity(0.05))
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Two rows of titles: a group's title over its own columns'.
    private var header: some View {
        HStack(spacing: 0) {
            Text("Camera")
                .padding(.horizontal, 12)
                .frame(minWidth: camera, maxWidth: .infinity, minHeight: 2 * rowHeight, maxHeight: 2 * rowHeight, alignment: .leading)
            title("Load Cycles", least: cycles)
            group("Load Time (s)", ["Mean", "Stdev"], least: number)
            group("Queue Time (s)", ["Mean", "Stdev"], least: number)
            group("Idle Time (s)", ["Mean", "Stdev"], least: number)
            group("Utilization %", ["Excavator", "Dump Truck"], least: share)
            title("Volume Moved (m³)", least: volume)
                .background(.quaternary.opacity(0.6))
        }
        .font(.caption.weight(.semibold))
        .multilineTextAlignment(.center)
        .background(.quaternary.opacity(0.35))
    }

    private func title(_ text: String, least: CGFloat) -> some View {
        Text(text)
            .padding(.horizontal, 4)
            .frame(minWidth: least, maxWidth: .infinity, minHeight: 2 * rowHeight, maxHeight: 2 * rowHeight)
            .overlay(alignment: .leading) { line }
    }

    private func group(_ title: String, _ parts: [String], least: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: rowHeight - 1, maxHeight: rowHeight - 1)
            Rectangle()
                .fill(.separator)
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
            pair(Text(parts[0]), Text(parts[1]), least: least)
        }
        .frame(minWidth: 2 * least, maxWidth: .infinity)
        .overlay(alignment: .leading) { line }
    }

    /// Two columns of a group, sharing its width evenly.
    private func pair(_ first: Text, _ second: Text, least: CGFloat) -> some View {
        HStack(spacing: 0) {
            first
                .frame(minWidth: least, maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
            second
                .frame(minWidth: least, maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                .overlay(alignment: .leading) { line.opacity(0.5) }
        }
        .frame(minWidth: 2 * least, maxWidth: .infinity)
    }

    private func row(_ name: String, _ f: TeamFigures) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(name)
                    .truncationMode(.middle)
                let checks = flags.checks.filter { $0.cameras.contains(name) }
                if !checks.isEmpty {
                    FlagMark(text: checks.map(FlagText.check).joined(separator: "\n"))
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: camera, maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
            HStack(spacing: 4) {
                Text("\(f.cycles)")
                if f.estimated > 0 {
                    Text("\(f.estimated) est.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .frame(minWidth: cycles, maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
            .overlay(alignment: .leading) { line }
            .help("\(f.observed) observed, \(f.estimated) estimated")
            column(pair(Text(Format.number(f.loadSMean)), Text(Format.number(f.loadSStdev)), least: number))
            column(pair(Text(Format.number(f.queueSMean)), Text(Format.number(f.queueSStdev)), least: number))
            column(pair(Text(Format.number(f.excavatorIdleSMean)), Text(Format.number(f.excavatorIdleSStdev)), least: number))
                .help("Dump truck idle: \(Format.spread(f.truckIdleSMean, f.truckIdleSStdev))")
            column(pair(Text(f.excavatorUtilPct.map { "\(Format.number($0))%" } ?? "—"), Text(f.truckUtilPct.map { "\(Format.number($0))%" } ?? "—"),
                        least: share))
            Text(Format.number(f.volumeM3))
                .frame(minWidth: volume, maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight)
                .background(.quaternary.opacity(0.6))
                .overlay(alignment: .leading) { line }
                .help("\(Format.number(f.volumeStruckM3, digits: 0))–\(Format.volume(f.volumeHeapedM3)), struck to heaped")
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    /// A group's two columns in a row, its left edge drawn.
    private func column(_ content: some View) -> some View {
        content.overlay(alignment: .leading) { line }
    }

    private var line: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
    }
}

/// What each camera's estimated load times were drawn from.
private struct Estimation: View {
    let metrics: ClusterMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("How estimated cycles are completed", help: "A cycle the video's start or end cut short counts as one load. Its load time is drawn from a normal distribution of the camera's own complete loads (two or more, not all the same), else the cluster's complete loads, else every load the cluster's cameras saw; kept within ±\(Format.number(metrics.spread, digits: 2)) σ of the mean, and never under what the camera saw of it. The draw is the same each time for the same run. Trucks still waiting when a video ended are not counted: the pipeline does not report them.")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Camera", "Estimated", "Drawn from", "Load time", "Drawn within"], id: \.self) { Text($0).fixedSize() }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(metrics.cameras) { camera in
                    GridRow {
                        Text(camera.name)
                            .fontWeight(.semibold)
                            .fixedSize()
                        Cell("\(camera.figures.estimated)")
                        Cell(basis(camera.prior))
                        Cell(Format.spread(camera.prior?.mean, camera.prior?.stdev))
                        Cell(camera.prior?.low.map { "\(Format.s($0)) to \(Format.s(camera.prior?.high))" } ?? "—")
                    }
                    .monospacedDigit()
                }
            }
        }
    }

    private func basis(_ p: ClusterMetrics.Prior?) -> String {
        guard let p else { return "—" }
        switch p.basis {
        case "camera": return "its \(p.n) complete loads"
        case "cluster": return "the cluster's \(p.n) complete \(p.n == 1 ? "load" : "loads")"
        case "seen": return "the \(p.n) \(p.n == 1 ? "load" : "loads") seen in the cluster"
        default: return "nothing seen: kept as seen"
        }
    }
}

/// One camera's cycles, truck by truck.
private struct Trips: View {
    let camera: ClusterMetrics.CameraRow
    /// The camera's clock at its video's start.
    let start: String?
    @State private var open = false

    var body: some View {
        let f = camera.figures
        DisclosureGroup(isExpanded: $open) {
            Wide {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["Truck", "Excavator", "Arrived", "Spotting", "Loading", "Queue", "Spot", "Load", ""], id: \.self) { Text($0).fixedSize() }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(Array(camera.cycles.enumerated()), id: \.offset) { _, c in
                        GridRow {
                            Cell(c.truck)
                            Cell(c.point)
                            Cell(Format.at(c.arriveS, start: start))
                            Cell(Format.at(c.spotAtS, start: start))
                            Cell("\(Format.at(c.loadStartS, start: start))–\(Format.at(c.loadEndS, start: start))")
                            Cell(c.arriveS == nil ? "—" : Format.s(c.waitS))
                            Cell(c.arriveS == nil ? "—" : Format.s(c.spotS))
                            Cell(Format.s(c.loadS))
                            if c.isEstimated {
                                Pill(text: "Estimated · \(Format.s(c.seenLoadS)) seen", color: .orange)
                                    .fixedSize()
                            } else {
                                Pill(text: "Observed", color: .secondary)
                                    .fixedSize()
                            }
                        }
                        .monospacedDigit()
                    }
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack {
                Text(camera.name)
                    .font(.body.weight(.medium))
                Text(Format.cycles(f.cycles, observed: f.observed, estimated: f.estimated))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
