import SwiftUI

// With several recordings picked and none opened, each recording is shown on its own: their clocks can't be trusted
// (a video may be trimmed), so they can't be lined up in time, and a label like "T1" only names a machine within its
// own video.

// MARK: - Timeline rows

/// One row per recording: its cycles an hour and mean queue from its own start, drawn to its own length. A row opens
/// that recording, where its hours can filter the cycles.
struct FleetTimelineRowsCard: View {
    @Bindable var state: FleetDashboardState
    @State private var hovered: String?
    private let rowHeight: CGFloat = 46
    private let labelWidth: CGFloat = 150

    var body: some View {
        let recs = state.recordings
        let longest = recs.map(\.durationMin).max() ?? 0
        let binMin = FleetAnalysis.binMinutes(forLongest: longest)
        let lines = recs.map { ($0, FleetAnalysis.timeline([$0], targets: state.targets, binMin: binMin)) }
        let maxRate = max(10, lines.flatMap { $0.1.bins.map(\.normalizedRate) }.max() ?? 0)
        let maxQueue = max(state.targets.maxQueueS.map { $0 * 1.3 } ?? 45, lines.flatMap { $0.1.bins.map(\.meanQueueS) }.max() ?? 0)
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            HStack(alignment: .top, spacing: Ov.Space.m) {
                Button { withAnimation(.snappy) { state.timelineOpen.toggle() } } label: {
                    HStack(alignment: .top, spacing: Ov.Space.s) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(state.timelineOpen ? 90 : 0))
                            .foregroundStyle(Ov.ink3)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Through each video")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Each recording from its own start, to its own length, in \(Int(binMin)) min bins. They aren't lined up in time, since a video's clock can't be trusted. Open one to filter its cycles by hour.")
                                .font(.system(size: 13))
                                .foregroundStyle(Ov.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                OvLegend([(Ov.sageStrong, "Cycles / h"), (FleetPalette.queue, "Mean queue"),
                          state.targets.maxQueueS != nil ? (Ov.negativeInk.opacity(0.75), "Over queue target")
                                                         : (FleetPalette.queue.opacity(0.85), "Long queue")])
            }
            if state.timelineOpen {
                VStack(spacing: Ov.Space.xs) {
                    ForEach(lines, id: \.0.id) { rec, line in
                        row(rec, line, longest: longest, maxRate: maxRate, maxQueue: maxQueue)
                    }
                    axis(longest: longest, binMin: binMin)
                }
                .padding(Ov.Space.m)
                .background(Ov.sunken.opacity(0.6), in: RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
            }
        }
        .ovCard()
    }

    private func row(_ rec: FleetRecording, _ line: FleetAnalysis.Timeline, longest: Double, maxRate: Double, maxQueue: Double) -> some View {
        let isHovered = hovered == rec.id
        return Button {
            state.drilledId = rec.id
            state.clearSubFilters()
        } label: {
            HStack(spacing: Ov.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.camera).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(FleetAnalysis.hm(rec.durationMin)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Ov.ink2)
                }
                .frame(width: labelWidth, alignment: .leading)
                GeometryReader { proxy in
                    let full = proxy.size.width
                    let binWidth = full * line.binMin / max(1, longest)
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Ov.card.opacity(isHovered ? 1 : 0.6))
                            .frame(width: full * rec.durationMin / max(1, longest))
                        ForEach(line.bins) { bin in
                            let alarm = state.targets.maxQueueS.map { bin.meanQueueS > $0 } ?? (bin.meanQueueS > line.outlierQueueS)
                            let x = Double(bin.index) * binWidth
                            let width = binWidth * (bin.endMin - bin.startMin) / line.binMin
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                                .fill(alarm ? (state.targets.maxQueueS != nil ? Ov.negativeInk.opacity(0.75) : FleetPalette.queue.opacity(0.85)) : Ov.sageStrong)
                                .frame(width: max(2, width - 3), height: max(2, bin.normalizedRate / maxRate * (rowHeight - 8)))
                                .offset(x: x + 1.5)
                            Circle()
                                .fill(FleetPalette.queue)
                                .frame(width: 6, height: 6)
                                .offset(x: x + width / 2 - 3, y: -min(0.95, bin.meanQueueS / maxQueue) * (rowHeight - 6))
                        }
                    }
                }
                .frame(height: rowHeight)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isHovered ? Ov.ink : Ov.ink3)
                    .frame(width: 14)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? rec.id : (hovered == rec.id ? nil : hovered) }
        .accessibilityLabel("Open \(rec.camera): \(rec.completeCycles) cycles over \(FleetAnalysis.hm(rec.durationMin))")
    }

    /// Hours from each video's start, under the rows.
    private func axis(longest: Double, binMin: Double) -> some View {
        HStack(spacing: Ov.Space.m) {
            Spacer().frame(width: labelWidth)
            GeometryReader { proxy in
                let ticks = Array(stride(from: 0.0, to: longest + 0.001, by: max(binMin, longest > 360 ? 120 : 60)))
                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.self) { m in
                        Text(FleetAnalysis.elapsed(m))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Ov.ink3)
                            .fixedSize()
                            .offset(x: proxy.size.width * m / max(1, longest))
                    }
                }
            }
            .frame(height: 14)
            Spacer().frame(width: 14)
        }
    }
}

// MARK: - Machines by recording

/// The machines seen in each recording, under it. A machine opens its recording with the cycles filtered to it.
struct FleetMachinesByRecordingCard: View {
    @Bindable var state: FleetDashboardState

    var body: some View {
        let recs = state.recordings
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            HStack(spacing: Ov.Space.m) {
                Button { withAnimation(.snappy) { state.fleetOpen.toggle() } } label: {
                    HStack(spacing: Ov.Space.s) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(state.fleetOpen ? 90 : 0))
                            .foregroundStyle(Ov.ink3)
                        Text("Machines in each video")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("EEU · cycles · load or queue. A label like T1 only names a machine within its own video.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Ov.ink3)
                    .multilineTextAlignment(.trailing)
            }
            if state.fleetOpen {
                VStack(alignment: .leading, spacing: Ov.Space.m) {
                    ForEach(recs) { rec in group(rec) }
                }
            }
        }
        .ovCard()
    }

    private func group(_ rec: FleetRecording) -> some View {
        let fleet = FleetAnalysis.fleet(rec, within: nil)
        return VStack(alignment: .leading, spacing: Ov.Space.s) {
            HStack(spacing: Ov.Space.s) {
                Text(rec.camera).font(.system(size: 13, weight: .semibold))
                Text("\(fleet.excavators.count) exc · \(fleet.trucks.count) trk · \(FleetAnalysis.hm(rec.durationMin))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Ov.ink2)
                Spacer()
                Button {
                    state.drilledId = rec.id
                    state.clearSubFilters()
                } label: {
                    HStack(spacing: 3) { Text("Open"); Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)) }
                }
                .buttonStyle(OvButtonStyle(.quiet, size: .small))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: Ov.Space.s)], spacing: Ov.Space.s) {
                ForEach(fleet.excavators + fleet.trucks) { tile($0, in: rec) }
            }
        }
        .padding(Ov.Space.m)
        .background(Ov.sunken.opacity(0.45), in: RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
    }

    private func tile(_ m: FleetAnalysis.MachineRow, in rec: FleetRecording) -> some View {
        let low = m.isExcavator && (state.targets.excEEU.map { m.eeu < $0 } ?? (m.eeu < 40))
        let slowQueue = !m.isExcavator && (state.targets.maxQueueS.map { m.meanQueueS > $0 } ?? (m.meanQueueS > 45))
        return Button {
            state.drilledId = rec.id
            state.clearSubFilters()
            state.machine = .init(id: m.id, isExcavator: m.isExcavator)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(m.id).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(Int(m.eeu.rounded()))%")
                        .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(low ? Ov.negativeInk : Ov.ink)
                }
                FleetMeter(fraction: m.eeu / 100, color: low ? Ov.negativeInk : (m.isExcavator ? FleetPalette.load : Ov.ink2), height: 4)
                HStack {
                    Text("\(m.cycles) cyc")
                    Spacer()
                    Text(m.isExcavator ? FleetAnalysis.dur(m.meanLoadS) : "Q \(FleetAnalysis.dur(m.meanQueueS))")
                        .foregroundStyle(slowQueue ? Ov.warningInk : Ov.ink2)
                        .fontWeight(slowQueue ? .semibold : .regular)
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Ov.ink2)
            }
            .padding(8)
            .background(Ov.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(rec.camera) with only \(m.id)'s cycles")
    }
}
