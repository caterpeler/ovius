import OviusCore
import SwiftUI

extension AppModel {
    /// The day a run is on: its cameras' clock at the start, else when it was added.
    func date(of batch: Batch) -> Date { Format.date(start(of: batch)) ?? batch.createdAt }
}

/// A cluster's runs as a month's calendar: each day's runs, clean, flagged or with a failed camera, and the days
/// since its first run (before today) without one.
struct RunCalendar: View {
    @Environment(AppModel.self) private var model
    /// The cluster's runs.
    let runs: [Batch]
    let open: (Int64) -> Void
    /// The first of the month shown; the latest run's when nil.
    @State private var month: Date?

    private var calendar: Calendar { .current }

    var body: some View {
        let byDay = Dictionary(grouping: runs) { calendar.startOfDay(for: model.date(of: $0)) }
        let months = Set(byDay.keys.compactMap { calendar.dateInterval(of: .month, for: $0)?.start }).sorted()
        let shown = month.flatMap { m in months.contains(m) ? m : nil } ?? months.last ?? calendar.dateInterval(of: .month, for: Date())!.start
        let k = months.firstIndex(of: shown)
        // Days since the first run, before today, without a run are gaps.
        let first = byDay.keys.min()
        let days = days(of: shown)
        let inMonth = runs.filter { calendar.isDate(model.date(of: $0), equalTo: shown, toGranularity: .month) }
        let gaps = days.compactMap { $0 }.filter { day in isGap(day, byDay: byDay, first: first) }.count
        let flagged = inMonth.filter { !model.flags(for: $0).isEmpty }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button { month = k.map { months[max(0, $0 - 1)] } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.page)
                    .disabled(k == nil || k == 0)
                Text(shown.formatted(.dateTime.month(.wide).year()))
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 150)
                Button { month = k.map { months[min(months.count - 1, $0 + 1)] } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.page)
                    .disabled(k == nil || k == months.count - 1)
                Text("\(inMonth.count) \(inMonth.count == 1 ? "run" : "runs") · \(flagged) flagged · \(gaps) \(gaps == 1 ? "day" : "days") without a run")
                    .foregroundStyle(.secondary)
                Spacer()
                legend
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(weekdays, id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        cell(day, runs: (byDay[day] ?? []).sorted { model.date(of: $0) < model.date(of: $1) },
                             gap: isGap(day, byDay: byDay, first: first))
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
    }

    /// The month's days, nil before the first to start the week as the calendar does.
    private func days(of month: Date) -> [Date?] {
        guard let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
    }

    /// The week's days' short names, from the calendar's first.
    private var weekdays: [String] {
        let names = calendar.shortWeekdaySymbols
        return (0..<7).map { names[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    private func isGap(_ day: Date, byDay: [Date: [Batch]], first: Date?) -> Bool {
        guard let first, byDay[day] == nil else { return false }
        return day > first && day < calendar.startOfDay(for: Date())
    }

    private func cell(_ day: Date, runs: [Batch], gap: Bool) -> some View {
        let today = calendar.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(calendar.component(.day, from: day))")
                .font(.callout.weight(today ? .bold : .medium))
                .foregroundStyle(today ? AnyShapeStyle(.white) : AnyShapeStyle(runs.isEmpty ? .secondary : .primary))
                .frame(minWidth: 22, minHeight: 22)
                .background(today ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: Circle())
            ForEach(runs.prefix(3)) { batch in
                chip(batch)
            }
            if runs.count > 3 {
                Text("+\(runs.count - 3) more: see the list")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if gap {
                Text("No run")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(.quaternary.opacity(runs.isEmpty ? 0.12 : 0.3), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if gap {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
    }

    /// A run on its day: when it started, and how it went.
    private func chip(_ batch: Batch) -> some View {
        let flags = model.flags(for: batch)
        let look = look(of: batch, flags: flags)
        return Button { open(batch.id) } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(look.color)
                    .frame(width: 7, height: 7)
                Text(model.date(of: batch).formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Spacer(minLength: 2)
                if !flags.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "flag.fill")
                        Text("\(flags.count)")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                } else if let icon = look.icon {
                    Image(systemName: icon)
                        .font(.caption2)
                        .foregroundStyle(look.color)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(look.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip(batch, flags: flags))
        .contextMenu { BatchActions(batch: batch) }
    }

    /// Green when clean, orange when flagged, red with a camera failed (or no figures), blue while it runs.
    private func look(of batch: Batch, flags: RunFlags) -> (color: Color, icon: String?) {
        switch model.state(of: batch) {
        case .done: flags.isEmpty ? (.green, "checkmark") : (.orange, nil)
        case .partial: (.red, "exclamationmark.triangle.fill")
        case .failed: (.red, "xmark")
        case .stopped: (.secondary, "stop.fill")
        case .running, .copying, .figuring: (.blue, "clock")
        }
    }

    private func tooltip(_ batch: Batch, flags: RunFlags) -> String {
        var lines = ["\(model.when(batch)) · \(model.summary(of: batch))"]
        if let t = batch.metrics?.total {
            lines.append("\(Format.number(Double(t.cycles), digits: 0)) cycles · \(Format.volume(t.volumeM3)) · \(Format.percent(t.excavatorUtilPct)) excavator use · \(Format.value(.cyclesPerH, Kpi.cyclesPerH.value(t)))")
        }
        if !flags.isEmpty { lines.append(FlagText.all(flags)) }
        return lines.joined(separator: "\n")
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([("No flags", Color.green), ("Flagged", .orange), ("Camera failed", .red)], id: \.0) { label, color in
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(label)
                }
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 12, height: 9)
                Text("No run")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Two ways to show the same thing, the one picked drawn as such.
struct ModeSwitch<Mode: Hashable>: View {
    @Binding var mode: Mode
    let modes: [(Mode, String, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.0) { value, title, icon in
                Button { mode = value } label: { Label(title, systemImage: icon) }
                    .buttonStyle(ModeButtonStyle(on: mode == value))
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ModeButtonStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(on ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .background(on ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(on ? .primary : .secondary)
            .contentShape(Rectangle())
    }
}
