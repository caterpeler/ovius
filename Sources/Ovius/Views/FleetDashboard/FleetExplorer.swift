import SwiftUI

// MARK: - Explorer

/// Every cycle of one recording (the only one picked, or the one opened), or the picked recordings side by side.
struct FleetExplorerCard: View {
    @Bindable var state: FleetDashboardState
    let timeline: FleetAnalysis.Timeline
    @State private var width: CGFloat = 1200

    /// Below this the tables drop their less important columns.
    private var compact: Bool { width < 980 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                OvBreadcrumb(steps)
                Spacer()
                if state.hasSubFilters, state.single != nil {
                    Button { state.clearSubFilters() } label: { Label("Clear filters", systemImage: "xmark") }
                        .buttonStyle(OvButtonStyle(.quiet, size: .small))
                }
            }
            .padding(Ov.Space.xl)
            if let rec = state.single, let cycles = state.explorerCycles(timeline: timeline) {
                FleetCycleTable(state: state, recording: rec, all: cycles.all, shown: cycles.shown, compact: compact)
            } else {
                FleetComparisonTable(state: state, compact: compact)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, w in width = w }
            }
        }
        .ovCard(.plain, padding: 0)
    }

    private var steps: [OvBreadcrumb.Step] {
        var steps: [OvBreadcrumb.Step] = [.init("Data Explorer")]
        let n = state.recordings.count
        if let id = state.drilledId, let rec = state.single, rec.id == id {
            steps.append(.init("All recordings (\(n))") {
                state.drilledId = nil
                state.clearSubFilters()
            })
            steps.append(.init("\(rec.camera) · \(rec.fileName)"))
        } else if let rec = state.single {
            steps.append(.init("\(rec.camera) · \(rec.fileName)"))
        } else {
            steps.append(.init("All recordings (\(n)) side by side"))
        }
        return steps
    }
}

/// A filter as a pill with its count; filled when on.
struct FleetFilterChip: View {
    let title: String
    let count: Int
    let icon: String?
    let isOn: Bool
    var onFill: Color = Ov.inverse
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title)
                Text("\(count)").monospacedDigit().opacity(0.6)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isOn ? Ov.onInverse : Ov.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(isOn ? onFill : Ov.sunken, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One recording's cycles: quick filters, machine filters and search; then a row per cycle with its phases as a bar.
struct FleetCycleTable: View {
    @Bindable var state: FleetDashboardState
    let recording: FleetRecording
    let all: [FleetAnalysis.JudgedCycle]
    let shown: [FleetAnalysis.JudgedCycle]
    var compact = false
    @State private var hovered: String?

    private enum W {
        static let offset: CGFloat = 132, pair: CGFloat = 104, flag: CGFloat = 112, flagIcon: CGFloat = 16, figure: CGFloat = 62, conf: CGFloat = 52
    }

    var body: some View {
        let targets = state.targets.judgesCycles
        let maxBar = max((state.targets.maxCycleS ?? 155) * 1.15, all.prefix(120).map(\.cycle.totalS).max() ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            let chips = HStack(spacing: Ov.Space.s) {
                FleetFilterChip(title: "All", count: all.count, icon: nil, isOn: state.quick == .all) { state.quick = .all }
                FleetFilterChip(title: targets ? "Over target" : "Outliers > 1.5σ", count: all.filter(\.isFlagged).count,
                                icon: targets ? "exclamationmark.triangle.fill" : "sparkles", isOn: state.quick == .flagged,
                                onFill: targets ? Ov.negativeInk : Ov.inverse) { state.quick = .flagged }
                FleetFilterChip(title: "Long queue", count: all.filter(\.isHighQueue).count, icon: nil, isOn: state.quick == .highQueue,
                                onFill: FleetPalette.queue) { state.quick = .highQueue }
                FleetFilterChip(title: "Unsure < 0.70", count: all.filter(\.cycle.isUncertain).count, icon: nil,
                                isOn: state.quick == .uncertain) { state.quick = .uncertain }
            }
            .fixedSize()
            let machines = HStack(spacing: Ov.Space.s) {
                OvPillMenu(state.excavatorFilter.map { "Excavator \($0)" } ?? "All excavators") {
                    Button("All excavators") { state.excavatorFilter = nil }
                    ForEach(recording.excavators) { m in Button("Excavator \(m.id)") { state.excavatorFilter = m.id } }
                }
                OvPillMenu(state.truckFilter.map { "Truck \($0)" } ?? "All trucks") {
                    Button("All trucks") { state.truckFilter = nil }
                    ForEach(recording.trucks) { m in Button("Truck \(m.id)") { state.truckFilter = m.id } }
                }
                OvSearchField(text: $state.explorerSearch, prompt: "Time, truck, excavator…")
                    .frame(width: 210)
            }
            .fixedSize()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Ov.Space.s) {
                    chips
                    Spacer(minLength: Ov.Space.s)
                    machines
                }
                VStack(alignment: .leading, spacing: Ov.Space.s) {
                    chips
                    machines
                }
            }
            .padding(.horizontal, Ov.Space.xl)
            .padding(.bottom, Ov.Space.m)

            HStack(spacing: Ov.Space.l) {
                OvLegend([(FleetPalette.queue, "Queue"), (FleetPalette.load, "Loading"), (FleetPalette.spot, "Spot")]
                         + (all.contains { $0.cycle.departS > 0 } ? [(FleetPalette.depart, "Depart")] : []))
                Spacer()
                Text("\(min(state.limit, shown.count)) of \(shown.count) cycles")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Ov.ink2)
            }
            .padding(.horizontal, Ov.Space.xl)
            .padding(.bottom, Ov.Space.m)

            header
            LazyVStack(spacing: 0) {
                ForEach(shown.prefix(state.limit)) { j in
                    row(j, maxBar: maxBar)
                }
            }
            if shown.isEmpty {
                OvEmptyState(systemImage: "line.3.horizontal.decrease", title: "No cycles match", message: "Clear the filters to see every cycle.")
            }
            if shown.count > state.limit {
                HStack {
                    Spacer()
                    Button("Load 50 more (\(shown.count - state.limit) left)") { state.limit += 50 }
                        .buttonStyle(OvButtonStyle(.secondary, size: .small))
                    Spacer()
                }
                .padding(Ov.Space.l)
            }
        }
        .padding(.bottom, Ov.Space.s)
    }

    private var header: some View {
        HStack(spacing: Ov.Space.m) {
            sortable("Time · cycle", .offset).frame(width: W.offset, alignment: .leading)
            Text("Truck → exc").frame(width: W.pair, alignment: .leading)
            Text(compact ? "" : "Flag").frame(width: compact ? W.flagIcon : W.flag, alignment: .leading)
            sortable(compact ? "Phases" : "Queue · load · spot", .total).frame(maxWidth: .infinity, alignment: .leading)
            sortable("Queue", .queue).frame(width: W.figure, alignment: .trailing)
            if !compact { Text("Load").frame(width: W.figure, alignment: .trailing) }
            sortable("Passes", .scoops).frame(width: W.figure - 8, alignment: .trailing)
            Text("Total").frame(width: W.figure, alignment: .trailing)
            if !compact { Text("Conf.").frame(width: W.conf, alignment: .trailing) }
            Spacer().frame(width: 14)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Ov.ink3)
        .padding(.horizontal, Ov.Space.xl)
        .padding(.vertical, Ov.Space.s)
        .background(Ov.sunken.opacity(0.7))
    }

    private func sortable(_ title: String, _ field: FleetDashboardState.CycleSort) -> some View {
        Button { state.sort(by: field) } label: {
            HStack(spacing: 3) {
                Text(title)
                if state.sort == field {
                    Image(systemName: state.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func row(_ j: FleetAnalysis.JudgedCycle, maxBar: Double) -> some View {
        let c = j.cycle
        let targets = state.targets.judgesCycles
        return Button { state.inspected = c } label: {
            HStack(spacing: Ov.Space.m) {
                HStack(spacing: 6) {
                    Text(FleetAnalysis.offset(c.offsetMin)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text(c.shortCode).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ov.ink3)
                }
                .frame(width: W.offset, alignment: .leading)
                HStack(spacing: 4) {
                    Text(c.truck).fontWeight(.semibold)
                    Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Ov.ink3)
                    Text(c.excavator).fontWeight(.semibold).foregroundStyle(Ov.sageInk)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Ov.sunken, in: Capsule())
                .frame(width: W.pair, alignment: .leading)
                Group {
                    if !c.isComplete {
                        Text(compact ? "–" : "Incomplete")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Ov.ink3)
                            .help("The truck wasn't seen from arrival to departure, so this visit isn't judged.")
                    } else if compact {
                        Image(systemName: j.isFlagged ? (targets ? "exclamationmark.triangle.fill" : "sparkles") : "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(j.isFlagged ? (targets ? Ov.negativeInk : Ov.ink) : Ov.positiveInk)
                            .help(j.isFlagged ? (targets ? "Over target" : "Unusual") : "Normal")
                    } else if j.isFlagged {
                        FleetStatusTag(status: targets ? .breach : .outlier, forCycle: true)
                    } else {
                        Label("Normal", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Ov.positiveInk)
                    }
                }
                .frame(width: compact ? W.flagIcon : W.flag, alignment: .leading)
                GeometryReader { proxy in
                    let w = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Ov.sunken)
                        HStack(spacing: 1.5) {
                            Capsule().fill(FleetPalette.queue).frame(width: w * c.queueS / maxBar)
                            Capsule().fill(FleetPalette.load).frame(width: w * c.loadS / maxBar)
                            Capsule().fill(FleetPalette.spot).frame(width: w * c.spotS / maxBar)
                            if c.departS > 0 { Capsule().fill(FleetPalette.depart).frame(width: w * c.departS / maxBar) }
                        }
                        if let limit = state.targets.maxCycleS {
                            Rectangle().fill(Ov.ink).frame(width: 2, height: 14).offset(x: w * min(0.98, limit / maxBar))
                        }
                    }
                }
                .frame(height: 10)
                .frame(maxWidth: .infinity)
                Text(FleetAnalysis.dur(c.queueS))
                    .fontWeight(j.isHighQueue ? .bold : .regular)
                    .foregroundStyle(j.isHighQueue ? Ov.warningInk : Ov.ink2)
                    .frame(width: W.figure, alignment: .trailing)
                if !compact {
                    Text(FleetAnalysis.dur(c.loadS)).foregroundStyle(Ov.ink2).frame(width: W.figure, alignment: .trailing)
                }
                Text("\(c.passes.count)").fontWeight(.semibold).frame(width: W.figure - 8, alignment: .trailing)
                Text(c.isComplete ? FleetAnalysis.dur(c.totalS) : "—")
                    .fontWeight(.bold)
                    .foregroundStyle(j.isFlagged && targets ? Ov.negativeInk : Ov.ink)
                    .frame(width: W.figure, alignment: .trailing)
                if !compact { confidence(c) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovered == c.id ? Ov.ink : Ov.ink3)
                    .frame(width: 14)
            }
            .font(.system(size: 12.5).monospacedDigit())
            .padding(.horizontal, Ov.Space.xl)
            .padding(.vertical, 9)
            .background(rowFill(j, hovered: hovered == c.id))
            .overlay(alignment: .bottom) { Rectangle().fill(Ov.hairline).frame(height: 1).padding(.horizontal, Ov.Space.xl) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? c.id : (hovered == c.id ? nil : hovered) }
    }

    private func confidence(_ c: FleetCycle) -> some View {
        Group {
            if let conf = c.confidence {
                Text(conf.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(c.isUncertain ? Ov.warningInk : Ov.ink3)
                    .fontWeight(c.isUncertain ? .semibold : .regular)
                    .padding(.horizontal, c.isUncertain ? 6 : 0)
                    .background(c.isUncertain ? Ov.warningBg : .clear, in: Capsule())
            } else {
                Text("—").foregroundStyle(Ov.ink3)
            }
        }
        .frame(width: W.conf, alignment: .trailing)
    }

    private func rowFill(_ j: FleetAnalysis.JudgedCycle, hovered: Bool) -> Color {
        if j.isFlagged { return (state.targets.judgesCycles ? Ov.negativeBg : Ov.sage).opacity(hovered ? 0.9 : 0.5) }
        return hovered ? Ov.sunken.opacity(0.7) : .clear
    }
}

/// The picked recordings side by side, a row each; a row opens its cycles.
struct FleetComparisonTable: View {
    @Bindable var state: FleetDashboardState
    var compact = false
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(state.recordings.count) recordings, each by its own length. Open one for its cycles.")
                .font(.system(size: 12.5))
                .foregroundStyle(Ov.ink2)
                .padding(.horizontal, Ov.Space.xl)
                .padding(.bottom, Ov.Space.m)
            HStack(spacing: Ov.Space.m) {
                Text("Camera and location").lineLimit(1).frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                if !compact { Text("Length").frame(width: 76, alignment: .leading) }
                Text("Cycles · rate").frame(width: 96, alignment: .trailing)
                Text("Excavator · truck EEU").frame(width: compact ? 150 : 200, alignment: .leading)
                if !compact { Text("Passes").frame(width: 54, alignment: .trailing) }
                Text("Queue").frame(width: 62, alignment: .trailing)
                if !compact { Text("Load").frame(width: 62, alignment: .trailing) }
                Spacer().frame(width: 70)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Ov.ink3)
            .padding(.horizontal, Ov.Space.xl)
            .padding(.vertical, Ov.Space.s)
            .background(Ov.sunken.opacity(0.7))
            ForEach(state.recordings) { row($0) }
        }
        .padding(.bottom, Ov.Space.s)
    }

    private func row(_ r: FleetRecording) -> some View {
        let highQueue = state.targets.maxQueueS.map { r.meanQueueS > $0 } ?? (r.meanQueueS > 60)
        let target = state.targets.excEEU
        return Button {
            state.drilledId = r.id
            state.clearSubFilters()
        } label: {
            HStack(spacing: Ov.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.camera).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if !compact { FleetChip(text: r.section) }
                    }
                    Text(r.location).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(compact ? "\(r.section) · \(FleetAnalysis.hm(r.durationMin))" : r.fileName)
                        .font(.system(size: 11))
                        .foregroundStyle(Ov.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                if !compact {
                    FleetChip(text: FleetAnalysis.hm(r.durationMin), ink: r.durationMin < 720 ? Ov.sageInk : Ov.ink2, fill: r.durationMin < 720 ? Ov.sage : Ov.sunken)
                        .frame(width: 76, alignment: .leading)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(r.completeCycles)/\(r.totalCycles)").font(.system(size: 13, weight: .semibold))
                    Text("\(r.cyclesPerHour.formatted(.number.precision(.fractionLength(1)))) / h").font(.system(size: 11.5)).foregroundStyle(Ov.sageInk)
                }
                .frame(width: 96, alignment: .trailing)
                VStack(spacing: 5) {
                    FleetEEUBar(label: "Exc", value: r.excEEU, color: target.map { r.excEEU < $0 ? Ov.negativeInk : FleetPalette.load } ?? FleetPalette.load,
                                target: target)
                    FleetEEUBar(label: "Trk", value: r.truckEEU, color: Ov.ink2)
                }
                .frame(width: compact ? 150 : 200)
                if !compact {
                    Text(r.meanPasses.formatted(.number.precision(.fractionLength(1)))).fontWeight(.semibold).frame(width: 54, alignment: .trailing)
                }
                Text(FleetAnalysis.dur(r.meanQueueS))
                    .fontWeight(highQueue ? .bold : .regular)
                    .foregroundStyle(highQueue ? Ov.warningInk : Ov.ink2)
                    .frame(width: 62, alignment: .trailing)
                if !compact {
                    Text(FleetAnalysis.dur(r.meanLoadS)).foregroundStyle(Ov.ink2).frame(width: 62, alignment: .trailing)
                }
                HStack(spacing: 3) {
                    Text("Cycles")
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovered == r.id ? Ov.ink : Ov.ink2)
                .frame(width: 70, alignment: .trailing)
            }
            .font(.system(size: 12.5).monospacedDigit())
            .padding(.horizontal, Ov.Space.xl)
            .padding(.vertical, Ov.Space.m)
            .background(hovered == r.id ? Ov.sunken.opacity(0.7) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Ov.hairline).frame(height: 1).padding(.horizontal, Ov.Space.xl) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? r.id : (hovered == r.id ? nil : hovered) }
    }
}

// MARK: - Cycle inspector

/// One cycle opened: its phases, every bucket pass, and why it is (or is not) flagged.
struct FleetCycleInspector: View {
    let cycle: FleetCycle
    let recording: FleetRecording
    let state: FleetDashboardState
    var sizing: Sizing = .scrolls

    enum Sizing {
        /// Always in a scroll view.
        case scrolls
        /// Its whole height, for rendering to an image.
        case whole
    }

    init(cycle: FleetCycle, recording: FleetRecording, state: FleetDashboardState, sizing: Sizing = .scrolls) {
        self.cycle = cycle
        self.recording = recording
        self.state = state
        self.sizing = sizing
    }

    init(cycle: FleetCycle, recording: FleetRecording, state: FleetDashboardState, scrolls: Bool) {
        self.init(cycle: cycle, recording: recording, state: state, sizing: scrolls ? .scrolls : .whole)
    }

    var body: some View {
        Group {
            switch sizing {
            case .scrolls:
                ScrollView { content }
            case .whole:
                content
            }
        }
        .background(Ov.canvas)
    }

    private var content: some View {
        let judged = FleetAnalysis.judge(recording.cycles, targets: state.targets).first { $0.id == cycle.id }
        return VStack(alignment: .leading, spacing: Ov.Space.xl) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        FleetChip(text: recording.camera, ink: Ov.sageInk, fill: Ov.sage)
                        Text("Cycle \(cycle.shortCode) · \(FleetAnalysis.offset(cycle.offsetMin))")
                            .font(.system(size: 20, weight: .semibold))
                            .tracking(-0.3)
                        Text(recording.place)
                            .font(.system(size: 13))
                            .foregroundStyle(Ov.ink2)
                    }
                    Spacer()
                    OvIconButton("xmark", shape: .square, help: "Close") { state.inspected = nil }
                }

                ActivityPlayer(cycle: cycle)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Ov.Space.s), count: cycle.departS > 0 ? 5 : 4), spacing: Ov.Space.s) {
                    phase("Queue", cycle.queueS, FleetPalette.queue, style: .sunken)
                    phase("Load · \(cycle.passes.count)×", cycle.loadS, FleetPalette.load, style: .sunken)
                    phase("Spot", cycle.spotS, FleetPalette.spot, style: .sunken)
                    if cycle.departS > 0 { phase("Depart", cycle.departS, FleetPalette.depart, style: .sunken) }
                    phase("Total", cycle.isComplete ? cycle.totalS : nil, Ov.onInverse2, style: .inverse)
                }

                VStack(alignment: .leading, spacing: Ov.Space.s) {
                    Text("Pass by pass").font(.system(size: 15, weight: .semibold))
                    HStack {
                        Text("Pass").frame(width: 56, alignment: .leading)
                        Text("Took").frame(maxWidth: .infinity, alignment: .leading)
                        Text("So far").frame(width: 64, alignment: .trailing)
                        Text("Passes done").frame(width: 110, alignment: .leading).padding(.leading, Ov.Space.m)
                        Text("Conf.").frame(width: 40, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ov.ink3)
                    ForEach(cycle.passes) { p in
                        HStack {
                            Text("#\(p.number)").fontWeight(.semibold).frame(width: 56, alignment: .leading)
                            Text(FleetAnalysis.dur(p.durationS)).foregroundStyle(Ov.sageInk).frame(maxWidth: .infinity, alignment: .leading)
                            Text(FleetAnalysis.dur(p.cumulativeS)).foregroundStyle(Ov.ink2).frame(width: 64, alignment: .trailing)
                            HStack(spacing: 6) {
                                FleetMeter(fraction: Double(p.fillPct) / 100, color: FleetPalette.load, height: 5)
                                Text("\(p.fillPct)%").foregroundStyle(Ov.ink2).fixedSize().frame(width: 40, alignment: .trailing)
                            }
                            .frame(width: 110)
                            .padding(.leading, Ov.Space.m)
                            Text(p.confidence.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—")
                                .foregroundStyle(Ov.ink3)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .font(.system(size: 12.5).monospacedDigit())
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Rectangle().fill(Ov.hairline).frame(height: 1) }
                    }
                }
                .ovCard(.plain, padding: Ov.Space.l, radius: Ov.Radius.inner)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Assessment").font(.system(size: 15, weight: .semibold))
                    Text(assessment(judged))
                        .font(.system(size: 13))
                        .foregroundStyle(Ov.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .ovCard(.sunken, padding: Ov.Space.l, radius: Ov.Radius.inner)
            }
            .padding(Ov.Space.xl)
    }

    private func phase(_ title: String, _ seconds: Double?, _ color: Color, style: OvCardStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(title).font(.system(size: 11.5)).foregroundStyle(style == .inverse ? Ov.onInverse2 : Ov.ink2).lineLimit(1)
            }
            Text(seconds.map(FleetAnalysis.dur) ?? "—").font(.system(size: 17, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ovCard(style, padding: Ov.Space.m, radius: 12)
    }

    private func assessment(_ j: FleetAnalysis.JudgedCycle?) -> String {
        guard cycle.isComplete else {
            return "Incomplete: the truck wasn't seen from arrival to departure, so this visit isn't judged."
        }
        guard let j, j.isFlagged else {
            return "Within this recording's usual spread. Truck \(cycle.truck) spotted under excavator \(cycle.excavator) and was loaded in \(cycle.passes.count) passes."
        }
        let t = state.targets
        if t.judgesCycles {
            var over: [String] = []
            if let q = t.maxQueueS, cycle.queueS > q { over.append("queued \(FleetAnalysis.dur(cycle.queueS)) against \(FleetAnalysis.dur(q))") }
            if let m = t.maxCycleS, cycle.totalS > m { over.append("took \(FleetAnalysis.dur(cycle.totalS)) against \(FleetAnalysis.dur(m))") }
            return "Over the cluster's target: " + over.joined(separator: ", and ") + "."
        }
        let cause = cycle.queueS > cycle.loadS * 0.6 ? "queueing at the approach" : "extra passes while loading"
        return "An outlier: at \(FleetAnalysis.dur(cycle.totalS)), more than 1.5σ above this recording's usual cycle, mostly from \(cause)."
    }
}
