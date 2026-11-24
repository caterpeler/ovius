import AppKit
import SwiftUI

/// What the dashboard's analysis is showing: the recordings applied in the recordings column, the cluster's
/// targets, and how far into the data the supervisor has gone (a time bin, a machine, a recording, a cycle).
@MainActor @Observable
public final class FleetDashboardState {
    public enum QuickFilter: Hashable { case all, flagged, highQueue, uncertain }
    public enum CycleSort: Hashable { case offset, total, queue, scoops }
    public struct MachineFilter: Hashable { let id: String; let isExcavator: Bool }

    /// The applied recordings, oldest first.
    public private(set) var recordings: [FleetRecording] = []
    /// The app's pooled figures for the same recordings, when it has them.
    public private(set) var pooled: DashboardMetricsSummary?
    /// The targets of the cluster being viewed. Read through, so editing a cluster updates the dashboard.
    @ObservationIgnored public var targetsSource: () -> FleetTargets = { FleetTargets() }
    @ObservationIgnored public var clusterNameSource: () -> String? = { nil }

    /// Opens the cluster's page, where its targets are set (none in the offline sample preview).
    @ObservationIgnored public var openClusterTargets: (() -> Void)?
    public var timelineOpen = true
    public var fleetOpen = true

    public var drilledId: String?
    public var binIndex: Int?
    public var machine: MachineFilter?
    public var quick: QuickFilter = .all
    public var excavatorFilter: String?
    public var truckFilter: String?
    public var explorerSearch = ""
    public var sort: CycleSort = .offset
    public var ascending = true
    public var limit = 25
    public var inspected: FleetCycle?

    public init() {}

    public var targets: FleetTargets { targetsSource() }
    public var clusterName: String? { clusterNameSource() }
    public var mode: BenchmarkMode { targets.isEmpty ? .statistical : .targets }

    /// Shows these recordings, keeping where the supervisor was when it still applies.
    public func show(_ recs: [FleetRecording], pooled: DashboardMetricsSummary?) {
        let before = Set(recordings.map(\.id))
        recordings = recs
        self.pooled = pooled
        let ids = Set(recs.map(\.id))
        guard ids != before else {
            if let c = inspected { inspected = recs.first { $0.id == c.recordingId }?.cycles.first { $0.id == c.id } }
            return
        }
        if let d = drilledId, !ids.contains(d) { drilledId = nil }
        if let c = inspected, !ids.contains(c.recordingId) { inspected = nil }
        binIndex = nil
        machine = nil
        clearSubFilters()
        limit = 25
    }

    /// The recording the explorer shows cycle by cycle: the only one applied, or the one opened.
    public var single: FleetRecording? {
        if recordings.count == 1 { return recordings[0] }
        return drilledId.flatMap { id in recordings.first { $0.id == id } }
    }

    public var hasSubFilters: Bool {
        binIndex != nil || machine != nil || excavatorFilter != nil || truckFilter != nil || quick != .all || !explorerSearch.isEmpty
    }

    public func clearSubFilters() {
        binIndex = nil
        machine = nil
        excavatorFilter = nil
        truckFilter = nil
        quick = .all
        explorerSearch = ""
    }

    public func sort(by field: CycleSort) {
        if sort == field {
            ascending.toggle()
        } else {
            sort = field
            ascending = field == .offset
        }
    }

    // MARK: Cycles of the single recording

    /// The single recording's cycles, judged, then filtered and sorted as the explorer is set.
    public func explorerCycles(timeline: FleetAnalysis.Timeline) -> (all: [FleetAnalysis.JudgedCycle], shown: [FleetAnalysis.JudgedCycle])? {
        guard let rec = single else { return nil }
        let all = FleetAnalysis.judge(rec.cycles, targets: targets)
        let bin = binIndex.flatMap { i in timeline.bins.indices.contains(i) ? timeline.bins[i] : nil }
        let q = explorerSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = all.filter { j in
            let c = j.cycle
            if let bin, c.offsetMin < bin.startMin || c.offsetMin >= bin.endMin { return false }
            if let machine, (machine.isExcavator ? c.excavator : c.truck) != machine.id { return false }
            if let excavatorFilter, c.excavator != excavatorFilter { return false }
            if let truckFilter, c.truck != truckFilter { return false }
            switch quick {
            case .all: break
            case .flagged: if !j.isFlagged { return false }
            case .highQueue: if !j.isHighQueue { return false }
            case .uncertain: if !c.isUncertain { return false }
            }
            if !q.isEmpty, !"\(c.shortCode) \(FleetAnalysis.offset(c.offsetMin)) \(c.truck) \(c.excavator)".lowercased().contains(q) { return false }
            return true
        }
        .sorted { a, b in
            let x = a.cycle, y = b.cycle
            let before: Bool = switch sort {
            case .offset: (x.offsetS, x.seq) < (y.offsetS, y.seq)
            case .total: x.totalS < y.totalS
            case .queue: x.queueS < y.queueS
            case .scoops: x.passes.count < y.passes.count
            }
            return ascending ? before : !before
        }
        return (all, shown)
    }
}

// MARK: - Cycle modal

extension View {
    /// Opens a clicked cycle in a modal over the whole window: the window dims and the cycle sits on top. A click on
    /// the dimmed window, Esc, or the close button shuts it.
    func fleetCycleModal(_ state: FleetDashboardState) -> some View {
        overlay { FleetCycleModal(state: state) }
    }
}

struct FleetCycleModal: View {
    let state: FleetDashboardState
    /// The cycle's full height: the panel is that tall, scrolling only when the window is shorter.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let cycle = state.inspected, let rec = state.recordings.first(where: { $0.id == cycle.recordingId }) {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { state.inspected = nil }
                        .transition(.opacity)
                    ScrollView {
                        FleetCycleInspector(cycle: cycle, recording: rec, state: state, sizing: .whole)
                            .background {
                                GeometryReader { inner in
                                    Color.clear
                                        .onAppear { contentHeight = inner.size.height }
                                        .onChange(of: inner.size.height) { _, h in contentHeight = h }
                                }
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: min(560, proxy.size.width - 48),
                           height: min(max(contentHeight, 200), proxy.size.height * 0.88))
                    .background(Ov.canvas)
                    .clipShape(RoundedRectangle(cornerRadius: Ov.Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Ov.Radius.card, style: .continuous).strokeBorder(Ov.hairline))
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    Button("Close") { state.inspected = nil }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(.easeOut(duration: 0.16), value: state.inspected?.id)
    }
}

// MARK: - Sample preview

/// The analysis on the prototype's sample recordings, for reviewing the design without the cloud (`Ovius --fleet`).
public struct FleetSamplePreview: View {
    @State private var state: FleetDashboardState
    let scrolls: Bool

    public init(recordings: Int = 1, targets: FleetTargets = FleetTargets(), scrolls: Bool = true) {
        let state = FleetDashboardState()
        state.targetsSource = { targets }
        state.clusterNameSource = { "Open-Pit Site" }
        state.show(Array(FleetSampleData.recordings.prefix(max(1, recordings))), pooled: nil)
        _state = State(initialValue: state)
        self.scrolls = scrolls
    }

    init(state: FleetDashboardState, scrolls: Bool) {
        _state = State(initialValue: state)
        self.scrolls = scrolls
    }

    public var body: some View {
        Group {
            if scrolls {
                ScrollView { page }
                    .fleetCycleModal(state)
            } else {
                page
            }
        }
        .background(Ov.canvas)
        .foregroundStyle(Ov.ink)
    }

    private var page: some View {
        FleetAnalysisPage(state: state)
            .padding(Ov.Space.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Small parts
/// How a recording looks, in a small tag: over target, unusual, worth watching, or balanced.
struct FleetStatusTag: View {
    let status: FleetAnalysis.RecordingStatus
    /// For a cycle, a breach is going over a target (a recording falls below one).
    var forCycle = false

    var body: some View {
        switch status {
        case .breach: tag(forCycle ? "Over target" : "Below target", icon: "exclamationmark.triangle.fill", ink: Ov.negativeInk, fill: Ov.negativeBg)
        case .outlier: tag("Unusual", icon: "sparkles", ink: Ov.onInverse, fill: Ov.inverse)
        case .watch: tag("Watch", icon: nil, ink: Ov.warningInk, fill: Ov.warningBg)
        case .balanced: tag("Balanced", icon: nil, ink: Ov.positiveInk, fill: .clear)
        }
    }

    private func tag(_ text: String, icon: String?, ink: Color, fill: Color) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8.5, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(ink)
        .padding(.horizontal, fill == .clear ? 0 : 7)
        .padding(.vertical, 2.5)
        .background(fill, in: Capsule())
    }
}

/// A small labelled utilisation bar.
struct FleetEEUBar: View {
    let label: String
    let value: Double
    let color: Color
    var target: Double?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(Ov.ink3)
                .frame(width: 24, alignment: .leading)
            FleetMeter(fraction: value / 100, color: color, target: target.map { $0 / 100 }, height: 5)
            Text("\(Int(value.rounded()))%")
                .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
    }
}

/// A share as a rounded bar, with a target's tick on it when there is one.
struct FleetMeter: View {
    let fraction: Double
    let color: Color
    var shade: Double?
    var target: Double?
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Ov.sunken)
                if let shade {
                    Capsule().fill(color.opacity(0.3)).frame(width: w * min(1, max(0, shade)))
                }
                Capsule().fill(color).frame(width: w * min(1, max(0, fraction)))
                if let target {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Ov.ink)
                        .frame(width: 2, height: height + 6)
                        .offset(x: w * min(1, max(0, target)) - 1)
                }
            }
        }
        .frame(height: height)
    }
}


// MARK: - Snapshot

/// `Ovius --fleet --snapshot OUT.png [--width W] [--dark] [--multi] [--targets] [--outliers] [--open] [--bin N] [--inspector]`
/// renders the sample analysis whole to a PNG and quits, for reviewing without a window.
enum FleetSnapshot {
    /// Sample targets for `--targets`, as a cluster might set them.
    static let sampleTargets = FleetTargets(excEEU: 65, truckEEU: 75, maxQueueS: 35, maxCycleS: 180)

    @MainActor
    static func run(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let out = value("--snapshot") else { exit(2) }
        let targets = args.contains("--targets") ? sampleTargets : FleetTargets()
        let state = FleetDashboardState()
        state.targetsSource = { targets }
        state.clusterNameSource = { "Open-Pit Site" }
        state.show(Array(FleetSampleData.recordings.prefix(args.contains("--multi") ? 4 : 1)), pooled: nil)
        if args.contains("--outliers") { state.quick = .flagged }
        if args.contains("--open") { state.drilledId = state.recordings.last?.id }
        if let bin = value("--bin").flatMap(Int.init) { state.binIndex = bin }
        let scheme: ColorScheme = args.contains("--dark") ? .dark : .light
        if args.contains("--inspector"), let rec = state.single,
           let cycle = FleetAnalysis.judge(rec.cycles, targets: targets).first(where: \.isFlagged)?.cycle {
            render(FleetCycleInspector(cycle: cycle, recording: rec, state: state, scrolls: false).frame(width: 460)
                .environment(\.colorScheme, scheme), to: out)
        }
        render(FleetSamplePreview(state: state, scrolls: false)
            .frame(width: value("--width").flatMap(Double.init) ?? 1200)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme), to: out)
    }

    @MainActor
    private static func render(_ view: some View, to out: String) -> Never {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Could not render the fleet dashboard.\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: out))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("Wrote \(out)")
        exit(0)
    }
}
