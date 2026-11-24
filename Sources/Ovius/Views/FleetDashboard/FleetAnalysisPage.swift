import SwiftUI

/// The analysis of the picked recordings, top to bottom: what they are, what stands out, the three figure cards, the
/// shift timeline, each machine, and the explorer.
struct FleetAnalysisPage: View {
    @Bindable var state: FleetDashboardState

    var body: some View {
        let recs = state.recordings
        let s = state.pooled.map { FleetAnalysis.aggregate(recs, pooled: $0) } ?? FleetAnalysis.aggregate(recs)
        // The timeline, machines and cycles are one recording's: the only one picked, or the one opened. With several
        // and none opened, each recording gets its own row, since they can't be lined up in time.
        let focus = state.single
        let timeline = FleetAnalysis.timeline(focus.map { [$0] } ?? [], targets: state.targets)
        let bin = state.binIndex.flatMap { i in timeline.bins.indices.contains(i) ? timeline.bins[i] : nil }
        VStack(alignment: .leading, spacing: Ov.Space.xl) {
            header(recs, s)
            FleetDiagnosisBanner(diagnosis: FleetAnalysis.diagnosis(s, recordings: recs, targets: state.targets),
                                 mode: state.mode)
            ViewThatFits(in: .horizontal) {
                // Side by side, the three cards share the tallest one's height.
                HStack(alignment: .top, spacing: Ov.Space.l) { kpis(s) }
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: Ov.Space.l) { kpis(s) }
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let focus {
                FleetTimelineCard(state: state, timeline: timeline, recording: focus, canGoBack: recs.count > 1)
                FleetMachinesCard(state: state, recording: focus, fleet: FleetAnalysis.fleet(focus, within: bin))
            } else {
                FleetTimelineRowsCard(state: state)
                FleetMachinesByRecordingCard(state: state)
            }
            FleetExplorerCard(state: state, timeline: timeline)
        }
    }

    private func header(_ recs: [FleetRecording], _ s: FleetAnalysis.Aggregate) -> some View {
        let one = recs.count == 1 ? recs[0] : nil
        let title = VStack(alignment: .leading, spacing: Ov.Space.s) {
                HStack(spacing: Ov.Space.s) {
                    Text(one?.camera ?? "\(recs.count) recordings")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Ov.sage, in: Capsule())
                        .foregroundStyle(Ov.sageInk)
                    Text("\(FleetAnalysis.hm(s.totalDurationMin)) of footage" + (s.hasMixedDurations ? " · clips of different lengths" : ""))
                        .font(.system(size: 13))
                        .foregroundStyle(Ov.ink2)
                }
                Text(one?.place ?? "Recordings side by side")
                    .font(.system(size: 30, weight: .medium))
                    .tracking(-0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
        }
        let controls = HStack(spacing: Ov.Space.s) {
            FleetTargetsSummary(targets: state.targets, clusterName: state.clusterName,
                                checks: recs.count > 1 ? FleetAnalysis.targetChecks(recs, targets: state.targets) : nil)
            if let open = state.openClusterTargets {
                Button(action: open) {
                    HStack(spacing: 4) {
                        Text(state.targets.isEmpty ? "Set in Clusters" : "Edit in Clusters")
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                    }
                }
                .buttonStyle(OvButtonStyle(.quiet, size: .small))
                .help("Targets belong to the cluster; this opens its page in Clusters & Sections")
            }
        }
        .fixedSize()
        // Side by side when there is room; otherwise the switch goes under the title.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Ov.Space.l) {
                title.fixedSize()
                Spacer(minLength: Ov.Space.l)
                controls
            }
            VStack(alignment: .leading, spacing: Ov.Space.l) {
                title
                controls
            }
        }
    }

    @ViewBuilder private func kpis(_ s: FleetAnalysis.Aggregate) -> some View {
        // With several recordings each is judged on its own; the cards' pooled figures then show how many meet a
        // target, never the pooled figure against it.
        let checks = state.recordings.count > 1 ? FleetAnalysis.targetChecks(state.recordings, targets: state.targets) : nil
        FleetThroughputCard(s: s, cycleCheck: checks?.first { $0.phrase.hasPrefix("Cycle") })
        FleetIdleCard(s: s, targets: state.targets, queueCheck: checks?.first { $0.phrase.hasPrefix("Queue") })
        FleetEEUCard(s: s, targets: state.targets, checks: checks?.filter { $0.phrase.contains("EEU") })
    }
}

// MARK: - Targets

/// The cluster's targets at a glance.
struct FleetTargetsSummary: View {
    let targets: FleetTargets
    let clusterName: String?
    /// With several recordings: how many meet each target, shown on its chip.
    var checks: [FleetAnalysis.TargetCheck]?

    var body: some View {
        let phrases = targets.phrases
        HStack(spacing: Ov.Space.s) {
            Image(systemName: "scope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(phrases.isEmpty ? Ov.ink3 : Ov.ink)
            if phrases.isEmpty {
                Text("No targets set")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Ov.ink2)
            } else {
                if let checks {
                    ForEach(checks) { c in
                        FleetChip(text: "\(c.phrase) · \(c.met)/\(c.judged)",
                                  ink: c.allMet ? Ov.positiveInk : (c.met == 0 ? Ov.negativeInk : Ov.warningInk),
                                  fill: c.allMet ? Ov.positiveBg : (c.met == 0 ? Ov.negativeBg : Ov.warningBg))
                            .help("\(c.met) of \(c.judged) recordings meet this, each by its own figures"
                                  + (c.misses.isEmpty ? "" : ". Missing: " + c.misses.map(\.camera).joined(separator: ", ")))
                    }
                } else {
                    ForEach(phrases, id: \.self) { FleetChip(text: $0, ink: Ov.ink, fill: Ov.sunken) }
                }
            }
        }
        .padding(.leading, Ov.Space.m)
        .padding(.trailing, phrases.isEmpty ? Ov.Space.m : 6)
        .frame(height: 36)
        .background(Ov.card, in: Capsule())
        .help(phrases.isEmpty
              ? "\(clusterName ?? "This cluster") has no targets, so figures are judged by their own spread."
              : "\(clusterName ?? "This cluster")'s targets.")
    }
}

// MARK: - Diagnosis

/// What most stands out, in a banner whose tone says how much it matters, with the mode it was judged by.
struct FleetDiagnosisBanner: View {
    let diagnosis: FleetAnalysis.Diagnosis
    let mode: BenchmarkMode

    var body: some View {
        let inverse = diagnosis.severity == .insight
        HStack(alignment: .top, spacing: Ov.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(inverse ? Ov.onInverse : ink)
                .frame(width: 34, height: 34)
                .background((inverse ? Ov.onInverse.opacity(0.12) : Ov.card.opacity(0.75)), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(diagnosis.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(diagnosis.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(inverse ? Ov.onInverse2 : Ov.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Ov.Space.m)
            Text(mode == .targets ? "Against cluster targets" : "By spread · no targets")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(inverse ? Ov.onInverse2 : Ov.ink2)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(inverse ? Ov.onInverse.opacity(0.1) : Ov.card.opacity(0.7), in: Capsule())
        }
        .padding(Ov.Space.l)
        .foregroundStyle(inverse ? Ov.onInverse : Ov.ink)
        .background(fill, in: RoundedRectangle(cornerRadius: Ov.Radius.card, style: .continuous))
    }

    private var icon: String {
        switch diagnosis.severity {
        case .critical: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark"
        case .insight: "sparkles"
        case .healthy: "checkmark"
        }
    }

    private var ink: Color {
        switch diagnosis.severity {
        case .critical: Ov.negativeInk
        case .warning: Ov.warningInk
        case .insight: Ov.onInverse
        case .healthy: Ov.sageInk
        }
    }

    private var fill: Color {
        switch diagnosis.severity {
        case .critical: Ov.negativeBg
        case .warning: Ov.warningBg
        case .insight: Ov.inverse
        case .healthy: Ov.sage
        }
    }
}

// MARK: - Figure cards

/// A figure card's header: its icon and title, and a tag on the trailing side.
struct FleetCardTitle<Tag: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let tag: () -> Tag

    var body: some View {
        HStack(spacing: Ov.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Ov.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: Ov.Space.s)
            tag()
        }
    }
}

/// A short figure in a pill, for a card's header.
struct FleetChip: View {
    let text: String
    var ink: Color = Ov.ink2
    var fill: Color = Ov.sunken

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(fill, in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}

/// Cycles, passes, cycle time and how a cycle splits into queue, load and spot.
struct FleetThroughputCard: View {
    let s: FleetAnalysis.Aggregate
    /// With several recordings and a cycle target: how many meet it.
    var cycleCheck: FleetAnalysis.TargetCheck?
    @State private var hoveredPhase: String?

    var body: some View {
        let total = max(1, s.meanQueueS + s.meanLoadS + s.meanSpotS + s.meanDepartS)
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            FleetCardTitle(title: "Throughput", icon: "arrow.triangle.2.circlepath") {
                FleetChip(text: "\(s.cyclesPerHour.formatted(.number.precision(.fractionLength(1)))) / h", ink: Ov.sageInk, fill: Ov.sage)
            }
            HStack(spacing: Ov.Space.s) {
                stat("Passes a cycle", s.meanPasses.formatted(.number.precision(.fractionLength(1))))
                stat("Cycle", "\(FleetAnalysis.dur(s.meanCycleS)) ± \(FleetAnalysis.dur(s.cycleSdS))")
            }
            VStack(alignment: .leading, spacing: Ov.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.totalCycles.formatted())
                        .ovText(.value)
                    Text("cycles · \(s.cyclesPerClip.formatted(.number.precision(.fractionLength(1)))) a clip"
                         + (s.incompleteCycles > 0 ? " · \(s.incompleteCycles) incomplete" : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(Ov.ink2)
                }
                phaseBar(total: total)
                if let c = cycleCheck {
                    FleetCheckLine(check: c)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ovCard()
    }

    /// A figure in its own inner card, like the idle and utilisation rows.
    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ov.Space.m)
        .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// How a mean cycle splits into its phases. Hovering a part shows its name, length and share straight away.
    private func phaseBar(total: Double) -> some View {
        let parts: [(name: String, seconds: Double, color: Color)] = [
            ("Queue", s.meanQueueS, FleetPalette.queue), ("Load", s.meanLoadS, FleetPalette.load),
            ("Spot", s.meanSpotS, FleetPalette.spot), ("Depart", s.meanDepartS, FleetPalette.depart),
        ].filter { $0.seconds > 0 }
        return GeometryReader { proxy in
            let gap: CGFloat = 2
            let usable = proxy.size.width - gap * CGFloat(max(0, parts.count - 1))
            let widths = parts.map { max(4, usable * $0.seconds / total) }
            HStack(spacing: gap) {
                ForEach(Array(parts.enumerated()), id: \.element.name) { i, part in
                    Capsule()
                        .fill(part.color)
                        .opacity(hoveredPhase == nil || hoveredPhase == part.name ? 1 : 0.35)
                        .frame(width: widths[i])
                        .contentShape(Rectangle().inset(by: -6))
                        .onHover { inside in
                            if inside { hoveredPhase = part.name } else if hoveredPhase == part.name { hoveredPhase = nil }
                        }
                        .accessibilityLabel("\(part.name) \(FleetAnalysis.dur(part.seconds)), \(Int((part.seconds / total * 100).rounded()))% of a mean cycle")
                }
            }
            .overlay {
                if let i = parts.firstIndex(where: { $0.name == hoveredPhase }) {
                    let part = parts[i]
                    let center = widths.prefix(i).reduce(0, +) + gap * CGFloat(i) + widths[i] / 2
                    FleetCalloutLayout(centerX: center) {
                        FleetCallout {
                            HStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 8, height: 8)
                                Text("\(part.name) \(FleetAnalysis.dur(part.seconds))").fontWeight(.semibold)
                                Text("\(Int((part.seconds / total * 100).rounded()))%").foregroundStyle(Ov.onInverse2)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
        .frame(height: 12)
        .zIndex(1)
        .animation(.easeOut(duration: 0.12), value: hoveredPhase)
    }
}

/// Excavator and truck idle, each a mean with its spread, and whether trucks bunch.
struct FleetIdleCard: View {
    let s: FleetAnalysis.Aggregate
    let targets: FleetTargets
    /// With several recordings: how many meet the queue target.
    var queueCheck: FleetAnalysis.TargetCheck?

    var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            FleetCardTitle(title: "Idle and bunching", icon: "pause.circle") {
                if s.isBunching {
                    FleetChip(text: "Bunching", ink: Ov.negativeInk, fill: Ov.negativeBg)
                } else {
                    FleetChip(text: "Steady arrivals", ink: Ov.positiveInk, fill: Ov.positiveBg)
                }
            }
            row("Excavator idle", mean: s.excIdleMeanS, sd: s.excIdleSdS, color: FleetPalette.queue, alarm: s.isBunching)
            row("Truck idle and wait", mean: s.truckIdleMeanS, sd: s.truckIdleSdS, color: Ov.ink2, alarm: false)
            HStack {
                Text("Solid: mean · faint: one σ more")
                Spacer()
                if let c = queueCheck {
                    FleetCheckLine(check: c)
                } else if let q = targets.maxQueueS {
                    Text("Queue target ≤ \(FleetAnalysis.dur(q))").foregroundStyle(Ov.warningInk)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Ov.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ovCard()
    }

    private func row(_ title: String, mean: Double, sd: Double, color: Color, alarm: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(FleetAnalysis.dur(mean)).font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text("σ \(FleetAnalysis.dur(sd))")
                    .font(.system(size: 12, weight: alarm ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(alarm ? Ov.negativeInk : Ov.ink2)
            }
            FleetMeter(fraction: mean / 280, color: color, shade: (mean + sd) / 280)
        }
        .padding(Ov.Space.m)
        .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Excavator and truck utilisation, against their targets when there are some, and the gap between them.
struct FleetEEUCard: View {
    let s: FleetAnalysis.Aggregate
    let targets: FleetTargets
    /// With several recordings: how many meet each EEU target. The pooled gauges then carry no target.
    var checks: [FleetAnalysis.TargetCheck]?

    var body: some View {
        let gap = s.truckEEU - s.excEEU
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            FleetCardTitle(title: "Utilisation (EEU)", icon: "gauge.with.needle") {
                FleetChip(text: "\(s.excCount) exc · \(s.truckCount) trk · 1:\((Double(s.truckCount) / Double(max(1, s.excCount))).formatted(.number.precision(.fractionLength(1))))"
                          + (s.clipCount > 1 ? " · \(s.clipCount) videos" : ""))
                    .help(s.clipCount > 1 ? "Counted per video: a machine seen in two videos counts twice." : "Machines seen in this video")
            }
            gauge("Excavator", s.excEEU, target: checks == nil ? targets.excEEU : nil, color: FleetPalette.load)
            gauge("Truck", s.truckEEU, target: checks == nil ? targets.truckEEU : nil, color: Ov.ink2)
            if let checks, !checks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(checks) { FleetCheckLine(check: $0) }
                }
                .padding(.top, Ov.Space.xs)
            } else {
            HStack {
                if targets.excEEU == nil && targets.truckEEU == nil {
                    Text(gap >= 0 ? "Trucks busier than excavators by" : "Excavators busier than trucks by")
                    Spacer()
                    Text("\(abs(gap).formatted(.number.precision(.fractionLength(1)))) pts")
                        .fontWeight(.semibold)
                        .foregroundStyle(abs(gap) > 25 ? Ov.ink : Ov.positiveInk)
                } else {
                    Text("Tick: the target")
                    Spacer()
                    Text([targets.excEEU.map { "Exc \(Int($0))%" }, targets.truckEEU.map { "Trk \(Int($0))%" }]
                        .compactMap { $0 }.joined(separator: " · "))
                }
            }
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(Ov.ink3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ovCard()
    }

    private func gauge(_ title: String, _ value: Double, target: Double?, color: Color) -> some View {
        let below = target.map { value < $0 } ?? false
        // Laid out like the idle card's rows, each in its own inner card.
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                if let target {
                    FleetChip(text: "\(value - target >= 0 ? "+" : "")\((value - target).formatted(.number.precision(.fractionLength(1)))) vs target",
                              ink: below ? Ov.negativeInk : Ov.positiveInk, fill: below ? Ov.negativeBg : Ov.positiveBg)
                }
                Text(FleetAnalysis.pct(value)).font(.system(size: 15, weight: .semibold).monospacedDigit())
            }
            FleetMeter(fraction: value / 100, color: below ? Ov.negativeInk : color, target: target.map { $0 / 100 })
        }
        .padding(Ov.Space.m)
        .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// "Excavator EEU ≥ 60%: 3 of 4 recordings", coloured by how many meet it.
struct FleetCheckLine: View {
    let check: FleetAnalysis.TargetCheck

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: check.allMet ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .semibold))
            Text("\(check.phrase): \(check.met) of \(check.judged) recordings")
        }
        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
        .foregroundStyle(check.allMet ? Ov.positiveInk : (check.met == 0 ? Ov.negativeInk : Ov.warningInk))
        .help(check.misses.isEmpty ? "Each recording meets it by its own figures"
              : "Missing: " + check.misses.map { "\($0.camera), \($0.detail)" }.joined(separator: "; "))
    }
}

/// The dashboard's own tooltip: shown the moment something is hovered, unlike the system's delayed one.
struct FleetCallout<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(Ov.onInverse)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Ov.inverse, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

/// Places one callout above a point of its container: centred on `centerX` but kept within the container's width,
/// with its bottom `gap` above `bottomY` (the container's top by default).
struct FleetCalloutLayout: Layout {
    let centerX: CGFloat
    var bottomY: CGFloat = 0
    var gap: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let x = min(max(bounds.minX, bounds.minX + centerX - size.width / 2), max(bounds.minX, bounds.maxX - size.width))
            view.place(at: CGPoint(x: x, y: bounds.minY + bottomY - size.height - gap), proposal: ProposedViewSize(size))
        }
    }
}

// MARK: - Timeline

/// Cycles an hour and mean queue across the shift, bin by bin; a bin picked filters every cycle list below.
struct FleetTimelineCard: View {
    @Bindable var state: FleetDashboardState
    let timeline: FleetAnalysis.Timeline
    let recording: FleetRecording
    /// Whether this recording was opened from several, so the card offers the way back to all of them.
    let canGoBack: Bool
    @State private var hoveredBin: Int?
    private let chartHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            HStack(spacing: Ov.Space.m) {
                Button { withAnimation(.snappy) { state.timelineOpen.toggle() } } label: {
                    HStack(spacing: Ov.Space.s) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(state.timelineOpen ? 90 : 0))
                            .foregroundStyle(Ov.ink3)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Ov.Space.s) {
                                Text("Through the video")
                                    .font(.system(size: 17, weight: .semibold))
                                if canGoBack { FleetChip(text: recording.camera, ink: Ov.sageInk, fill: Ov.sage) }
                            }
                            Text("Time from the start of the video, \(FleetAnalysis.hm(recording.durationMin)) long, in \(Int(timeline.binMin)) min bins. Pick one to filter the cycles below.")
                                .font(.system(size: 13))
                                .foregroundStyle(Ov.ink2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if canGoBack {
                    Button {
                        state.drilledId = nil
                        state.clearSubFilters()
                    } label: { Label("All recordings", systemImage: "chevron.left") }
                    .buttonStyle(OvButtonStyle(.quiet, size: .small))
                }
                OvLegend([(Ov.sageStrong, "Cycles / h"), (FleetPalette.queue, "Mean queue"),
                          state.targets.maxQueueS != nil ? (Ov.negativeInk.opacity(0.75), "Over queue target")
                                                         : (FleetPalette.queue.opacity(0.85), "Long queue")])
                    .help(state.targets.maxQueueS != nil ? "An hour whose mean queue is over the cluster's queue target"
                                                          : "An hour whose mean queue is well above this video's usual (mean + 1.25σ)")
                if let i = state.binIndex, timeline.bins.indices.contains(i) {
                    Button { state.binIndex = nil } label: {
                        Label(timeline.bins[i].rangeLabel, systemImage: "xmark")
                    }
                    .buttonStyle(OvButtonStyle(.primary, size: .small))
                }
            }
            if state.timelineOpen {
                chart
            }
        }
        .ovCard()
    }

    private var chart: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                if let target = state.targets.maxQueueS {
                    let y = min(0.96, target / timeline.maxQueueS) * chartHeight
                    Rectangle()
                        .fill(Ov.negativeInk.opacity(0.7))
                        .frame(height: 1)
                        .offset(y: -y)
                        .overlay(alignment: .trailing) {
                            Text("Target \(FleetAnalysis.dur(target))")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Ov.negativeInk)
                                .offset(y: -y - 9)
                        }
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(timeline.bins) { bin in bar(bin) }
                }
            }
            .frame(height: chartHeight)
            .overlay { callout }
            .zIndex(1)
            // Fades in, then glides from bar to bar, as the Throughput bar's label does.
            .animation(.easeOut(duration: 0.12), value: hoveredBin)
            HStack(spacing: 6) {
                ForEach(timeline.bins) { bin in
                    Text(bin.label)
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(state.binIndex == bin.index ? Ov.ink : Ov.ink3)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(Ov.Space.m)
        .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
    }

    /// The hovered hour's figures, just above its bar.
    private var callout: some View {
        GeometryReader { proxy in
            if let i = hoveredBin, timeline.bins.indices.contains(i) {
                let bin = timeline.bins[i]
                let n = CGFloat(timeline.bins.count)
                let width = (proxy.size.width - 6 * (n - 1)) / n
                let barTop = chartHeight - max(barHeight(bin), dotHeight(bin) + 5.5)
                FleetCalloutLayout(centerX: CGFloat(i) * (width + 6) + width / 2, bottomY: barTop) {
                    FleetCallout {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bin.rangeLabel).fontWeight(.semibold)
                            Text("\(bin.normalizedRate.formatted(.number.precision(.fractionLength(1)))) cycles/h · \(bin.cycleCount) cycles")
                            HStack(spacing: 5) {
                                Circle().fill(FleetPalette.queue).frame(width: 7, height: 7)
                                Text("Mean queue \(FleetAnalysis.dur(bin.meanQueueS))")
                                if isFlagged(bin) {
                                    Text(state.targets.maxQueueS != nil ? "· over target" : "· long").foregroundStyle(Ov.onInverse2)
                                }
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }

    private func barHeight(_ bin: FleetAnalysis.Bin) -> CGFloat {
        max(0.06, bin.normalizedRate / timeline.maxRate) * (chartHeight - 12)
    }

    private func dotHeight(_ bin: FleetAnalysis.Bin) -> CGFloat {
        min(0.95, bin.meanQueueS / timeline.maxQueueS) * chartHeight
    }

    /// An hour whose mean queue is over the queue target, or well above this video's usual when there isn't one.
    private func isFlagged(_ bin: FleetAnalysis.Bin) -> Bool {
        state.targets.maxQueueS.map { bin.meanQueueS > $0 } ?? (bin.meanQueueS > timeline.outlierQueueS)
    }

    private func bar(_ bin: FleetAnalysis.Bin) -> some View {
        let picked = state.binIndex == bin.index
        let alarm = isFlagged(bin)
        let height = barHeight(bin)
        let dot = dotHeight(bin)
        return Button {
            withAnimation(.snappy(duration: 0.2)) { state.binIndex = picked ? nil : bin.index }
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(picked ? Ov.card : .clear)
                    .shadow(color: picked ? OvCardModifier.shadowFar : .clear, radius: 6, y: 2)
                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
                    // Picked: white (the inverse colour). Flagged: queue amber, or red when over the queue target.
                    .fill(picked ? Ov.inverse : (alarm ? (state.targets.maxQueueS != nil ? Ov.negativeInk.opacity(0.75) : FleetPalette.queue.opacity(0.85)) : Ov.sageStrong))
                    .frame(maxWidth: 34)
                    .frame(height: height)
                    .padding(.horizontal, 4)
                Circle()
                    .fill(FleetPalette.queue)
                    .overlay(Circle().strokeBorder(Ov.card, lineWidth: 2))
                    .frame(width: 11, height: 11)
                    .offset(y: -dot + 5.5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: chartHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredBin = bin.index } else if hoveredBin == bin.index { hoveredBin = nil }
        }
        .accessibilityLabel("\(bin.rangeLabel): \(bin.cycleCount) cycles, mean queue \(FleetAnalysis.dur(bin.meanQueueS))")
    }
}

// MARK: - Machines

/// Every excavator and truck of one recording: utilisation, cycles and load or queue time; one picked filters the cycles.
struct FleetMachinesCard: View {
    @Bindable var state: FleetDashboardState
    let recording: FleetRecording
    let fleet: (excavators: [FleetAnalysis.MachineRow], trucks: [FleetAnalysis.MachineRow])

    var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            HStack(spacing: Ov.Space.m) {
                Button { withAnimation(.snappy) { state.fleetOpen.toggle() } } label: {
                    HStack(spacing: Ov.Space.s) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(state.fleetOpen ? 90 : 0))
                            .foregroundStyle(Ov.ink3)
                        Text("Each machine")
                            .font(.system(size: 17, weight: .semibold))
                        Text("\(fleet.excavators.count) excavator\(fleet.excavators.count == 1 ? "" : "s") · \(fleet.trucks.count) truck\(fleet.trucks.count == 1 ? "" : "s") in \(recording.camera)")
                            .font(.system(size: 13))
                            .foregroundStyle(Ov.ink2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if let m = state.machine {
                    Button { state.machine = nil } label: { Label("Only \(m.id)", systemImage: "xmark") }
                        .buttonStyle(OvButtonStyle(.primary, size: .small))
                }
            }
            if state.fleetOpen {
                VStack(alignment: .leading, spacing: Ov.Space.l) {
                    group("Excavators", note: "EEU · cycles · load", rows: fleet.excavators, minimum: 150)
                    group("Trucks", note: "EEU · cycles · queue", rows: fleet.trucks, minimum: 118)
                }
            }
        }
        .ovCard()
    }

    private func group(_ title: String, note: String, rows: [FleetAnalysis.MachineRow], minimum: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Ov.Space.s) {
            HStack {
                OvSectionLabel(title).padding(.horizontal, -Ov.Space.m).padding(.top, -Ov.Space.s)
                Spacer()
                Text(note).font(.system(size: 11)).foregroundStyle(Ov.ink3)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: Ov.Space.s)], spacing: Ov.Space.s) {
                ForEach(rows) { machine(_: $0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func machine(_ m: FleetAnalysis.MachineRow) -> some View {
        let picked = state.machine?.id == m.id
        let low = m.isExcavator && (state.targets.excEEU.map { m.eeu < $0 } ?? (m.eeu < 40))
        let slowQueue = !m.isExcavator && (state.targets.maxQueueS.map { m.meanQueueS > $0 } ?? (m.meanQueueS > 45))
        return Button {
            state.machine = picked ? nil : .init(id: m.id, isExcavator: m.isExcavator)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(m.id).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(m.eeu.formatted(.number.precision(.fractionLength(m.isExcavator ? 1 : 0))))%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(low ? Ov.negativeInk : Ov.ink)
                }
                FleetMeter(fraction: m.eeu / 100, color: low ? Ov.negativeInk : (m.isExcavator ? FleetPalette.load : Ov.ink2), height: 5)
                HStack {
                    Text("\(m.cycles) cyc")
                    Spacer()
                    Text(m.isExcavator ? "Load \(FleetAnalysis.dur(m.meanLoadS))" : "Q \(FleetAnalysis.dur(m.meanQueueS))")
                        .foregroundStyle(slowQueue ? Ov.warningInk : Ov.ink2)
                        .fontWeight(slowQueue ? .semibold : .regular)
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Ov.ink2)
            }
            .padding(10)
            .background(picked ? Ov.sage : Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(picked ? Ov.sageStrong : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
