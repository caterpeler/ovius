import Charts
import SwiftUI

private enum GanttZoomSpan: String, CaseIterable, Identifiable {
    case halfHour = "30m Window"
    case oneHour = "1h Window"
    case twoHours = "2h Window"
    case fullSlice = "All"

    var id: String { rawValue }

    var durationS: Double? {
        switch self {
        case .halfHour: return 1_800
        case .oneHour: return 3_600
        case .twoHours: return 7_200
        case .fullSlice: return nil
        }
    }
}

/// Dedicated view for `CARD_STATE_GANTT_TIMELINE` (`DIAG_05_CYCLE_GANTT`).
/// Provides windowed zoom navigation, translucent conflict highlights behind ordered machine swimlanes,
/// concurrency metrics, and a clear color legend.
public struct StateGanttTimelineCardView: View {
    public let segments: [GanttSegmentItem]
    public let audit: GanttConcurrencyAudit
    public let conflicts: [GanttConflictInterval]
    public let activeRecording: RecordingDTO?
    public let availableRecordings: [RecordingDTO]
    public let onSelectRecording: (String) -> Void

    @State private var zoomSpan: GanttZoomSpan = .oneHour
    @State private var windowIndex: Int = 0
    @State private var showConflictBands: Bool = true

    public init(
        segments: [GanttSegmentItem],
        audit: GanttConcurrencyAudit = GanttConcurrencyAudit(),
        conflicts: [GanttConflictInterval] = [],
        activeRecording: RecordingDTO?,
        availableRecordings: [RecordingDTO] = [],
        onSelectRecording: @escaping (String) -> Void = { _ in }
    ) {
        self.segments = segments
        self.audit = audit
        self.conflicts = conflicts
        self.activeRecording = activeRecording
        self.availableRecordings = availableRecordings
        self.onSelectRecording = onSelectRecording
    }

    private var totalBounds: (minS: Double, maxS: Double) {
        let minS = segments.map(\.startS).min() ?? 0.0
        let maxS = segments.map(\.endS).max() ?? max(minS + 60.0, 3_600.0)
        return (minS, max(minS + 60.0, maxS))
    }

    private var activeWindowBounds: (lo: Double, hi: Double) {
        let total = totalBounds
        guard let spanDur = zoomSpan.durationS else {
            return (total.minS, total.maxS)
        }
        let maxIndex = max(0, Int(ceil((total.maxS - total.minS) / spanDur)) - 1)
        let clampedIdx = min(max(0, windowIndex), maxIndex)
        let lo = total.minS + Double(clampedIdx) * spanDur
        let hi = min(total.maxS, lo + spanDur)
        return (lo, max(lo + 60.0, hi))
    }

    private var maxWindowIndex: Int {
        let total = totalBounds
        guard let spanDur = zoomSpan.durationS else { return 0 }
        return max(0, Int(ceil((total.maxS - total.minS) / spanDur)) - 1)
    }

    private var visibleSegments: [GanttSegmentItem] {
        let win = activeWindowBounds
        return segments.compactMap { seg in
            guard seg.endS > win.lo && seg.startS < win.hi else { return nil }
            let clippedStart = max(seg.startS, win.lo)
            let clippedEnd = min(seg.endS, win.hi)
            guard clippedEnd > clippedStart else { return nil }
            if clippedStart == seg.startS && clippedEnd == seg.endS { return seg }
            return GanttSegmentItem(
                segmentId: seg.segmentId,
                recordingId: seg.recordingId,
                machineId: seg.machineId,
                state: seg.state,
                startS: clippedStart,
                endS: clippedEnd,
                confidence: seg.confidence,
                isUncertain: seg.isUncertain
            )
        }
    }

    private var orderedMachines: [String] {
        let unique = Set(visibleSegments.map(\.machineId))
        return unique.sorted { lhs, rhs in
            let lIsExc = lhs.uppercased().hasPrefix("E")
            let rIsExc = rhs.uppercased().hasPrefix("E")
            if lIsExc != rIsExc { return lIsExc }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private var visibleConflicts: [GanttConflictInterval] {
        guard showConflictBands else { return [] }
        let win = activeWindowBounds
        return conflicts.compactMap { c in
            guard c.endS > win.lo && c.startS < win.hi else { return nil }
            let lo = max(c.startS, win.lo)
            let hi = min(c.endS, win.hi)
            guard hi > lo else { return nil }
            return GanttConflictInterval(id: c.id, kind: c.kind, startS: lo, endS: hi)
        }
    }

    public var body: some View {
        let win = activeWindowBounds
        let visSegs = visibleSegments
        let machines = orderedMachines
        let visConflicts = visibleConflicts

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if !availableRecordings.isEmpty {
                    Menu {
                        ForEach(availableRecordings.prefix(40)) { rec in
                            Button {
                                onSelectRecording(rec.recordingId)
                            } label: {
                                let prefix = (rec.recordingId == activeRecording?.recordingId) ? "✓ " : ""
                                Text("\(prefix)\(rec.cameraId) • \(rec.filename) (\(rec.timestamp))")
                            }
                        }
                    } label: {
                        Label(
                            activeRecording.map { "\($0.cameraId) • \($0.filename)" } ?? "Select Recording",
                            systemImage: "film"
                        )
                        .font(.caption.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                } else if let activeRecording {
                    Text("Previewing: \(activeRecording.cameraId) • \(activeRecording.filename)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Conflicts", isOn: $showConflictBands)
                    .toggleStyle(.checkbox)
                    .font(.caption2)

                Picker("Zoom", selection: $zoomSpan) {
                    ForEach(GanttZoomSpan.allCases) { span in
                        Text(span.rawValue).tag(span)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 108)
            }

            if zoomSpan != .fullSlice && maxWindowIndex > 0 {
                HStack(spacing: 8) {
                    Button {
                        windowIndex = max(0, windowIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(windowIndex == 0)

                    Text("Window: \(formatWindowClock(startS: win.lo)) – \(formatWindowClock(startS: win.hi))")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)

                    Button {
                        windowIndex = min(maxWindowIndex, windowIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(windowIndex >= maxWindowIndex)

                    Spacer()

                    Text("\(visSegs.count) intervals shown")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // Concurrency Audit Strip
            HStack(spacing: 14) {
                auditStat(title: "Queue Overlap", value: OviusFormat.percentage(audit.queueOverlapPct))
                auditStat(title: "Excavator Starved", value: OviusFormat.percentage(audit.starvedPct))
                auditStat(title: "Fleet Stoppages", value: "\(audit.syncedHaltCount)")
                auditStat(title: "Boundary Cutoffs", value: "\(audit.boundaryCutoffCount)")
            }

            if visSegs.isEmpty {
                ContentUnavailableView(
                    "No Machine Intervals in Window",
                    systemImage: "timeline.selection",
                    description: Text("Step to another time window above or pick a different recording.")
                )
                .frame(height: 200)
            } else {
                Chart {
                    // Subtle conflict highlight bands behind swimlanes instead of an opaque row dominating the chart.
                    ForEach(visConflicts) { conflict in
                        RectangleMark(
                            xStart: .value("Start (s)", conflict.startS),
                            xEnd: .value("End (s)", conflict.endS)
                        )
                        .foregroundStyle(
                            conflict.kind == "Synced Halt"
                                ? Color.red.opacity(0.14)
                                : Color.orange.opacity(0.12)
                        )
                    }

                    ForEach(visSegs) { seg in
                        BarMark(
                            xStart: .value("Start (s)", seg.startS),
                            xEnd: .value("End (s)", seg.endS),
                            y: .value("Machine", seg.machineId),
                            height: .ratio(0.68)
                        )
                        .foregroundStyle(color(for: seg.state).opacity(seg.isUncertain ? 0.35 : 0.90))
                        .cornerRadius(2)
                    }
                }
                .chartXScale(domain: win.lo...win.hi)
                .chartYScale(domain: machines)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { val in
                        AxisGridLine()
                        AxisValueLabel {
                            if let offsetS = val.as(Double.self) {
                                Text(formatWindowClock(startS: offsetS))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
                .frame(height: max(220, CGFloat(machines.count) * 22 + 32))

                // Concise Inline State & Conflict Legend
                HStack(spacing: 10) {
                    legendDot("Load", .blue)
                    legendDot("Prep", .teal)
                    legendDot("Queue", .orange)
                    legendDot("Spot/Depart", .indigo)
                    legendDot("Idle", .red)
                    if showConflictBands {
                        legendBand("Overlap Band", .orange.opacity(0.28))
                        legendBand("Fleet Halt Band", .red.opacity(0.28))
                    }
                    Spacer()
                }
            }
        }
        .onChange(of: activeRecording?.recordingId) { _, _ in
            windowIndex = 0
        }
        .onChange(of: zoomSpan) { _, _ in
            windowIndex = min(windowIndex, maxWindowIndex)
        }
    }

    private func formatWindowClock(startS: Double) -> String {
        if let rec = activeRecording, let baseDate = OviusFormat.parseISODate(rec.timestamp) {
            let utc = OviusFormat.utcHourAndMinute(for: baseDate.addingTimeInterval(startS))
            return String(format: "%02d:%02d", utc.hour, utc.minuteOfDay % 60)
        }
        return OviusFormat.duration(seconds: startS)
    }

    private func auditStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.bold().monospacedDigit())
        }
    }

    private func legendDot(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func legendBand(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func color(for state: MachineState) -> Color {
        switch state {
        case .loadingScoop, .beingLoaded: return .blue
        case .facePrep: return .teal
        case .queuingIdle: return .orange
        case .spotting, .departing: return .indigo
        case .idle: return .red
        case .outOfFrame: return .gray
        }
    }
}
