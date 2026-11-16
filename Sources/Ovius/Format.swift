import OviusCore
import Foundation
import SwiftUI

enum Format {
    /// 48 s, 3 min 54 s, 1 h 12 min.
    static func seconds(_ s: Double?) -> String {
        guard let s else { return "—" }
        let n = Int(s.rounded())
        if n < 60 { return "\(n) s" }
        if n < 3600 { return n % 60 == 0 || n >= 600 ? "\(Int((s / 60).rounded())) min" : "\(n / 60) min \(n % 60) s" }
        return "\(n / 3600) h \((n % 3600) / 60) min"
    }

    static func minutes(_ m: Double?) -> String {
        guard let m else { return "—" }
        return m < 10 ? "\(number(m)) min" : seconds(m * 60)
    }

    static func hours(_ h: Double) -> String {
        h < 1 ? "\(Int((h * 60).rounded())) min" : "\(number(h)) h"
    }

    static func number(_ x: Double?, digits: Int = 1) -> String {
        guard let x else { return "—" }
        return x.formatted(.number.precision(.fractionLength(digits)))
    }

    static func percent(_ x: Double?) -> String {
        guard let x else { return "—" }
        return "\(Int(x.rounded()))%"
    }

    static func value(_ kpi: Kpi, _ x: Double?) -> String {
        switch kpi {
        case .cyclesPerH: x.map { "\(number($0)) /h" } ?? "—"
        case .volumePerH: x.map { "\(number($0, digits: 0)) m³/h" } ?? "—"
        case .excavatorUtilPct, .truckUtilPct: percent(x)
        case .loadS, .queueS, .excavatorIdleS, .truckIdleS: s(x)
        }
    }

    /// A figure's range, its unit once: 65–93%, 75–110 s, 0–101,6 /h.
    static func range(_ kpi: Kpi, _ low: Double, _ high: Double) -> String {
        switch kpi {
        case .cyclesPerH: "\(number(low))–\(number(high)) /h"
        case .volumePerH: "\(number(low, digits: 0))–\(number(high, digits: 0)) m³/h"
        case .excavatorUtilPct, .truckUtilPct: "\(Int(low.rounded()))–\(Int(high.rounded()))%"
        case .loadS, .queueS, .excavatorIdleS, .truckIdleS: "\(Int(low.rounded()))–\(Int(high.rounded())) s"
        }
    }

    /// 82 s, as the team's sheet gives times.
    static func s(_ x: Double?) -> String {
        guard let x else { return "—" }
        return "\(Int(x.rounded())) s"
    }

    /// 82 ± 21 s: a mean and its standard deviation.
    static func spread(_ mean: Double?, _ sd: Double?) -> String {
        guard let mean else { return "—" }
        guard let sd else { return s(mean) }
        return "\(Int(mean.rounded())) ± \(Int(sd.rounded())) s"
    }

    /// 2,862 m³.
    static func volume(_ m3: Double) -> String {
        "\(number(m3, digits: 0)) m³"
    }

    /// When, `seconds` into a video: on the camera's clock (16:03:11) when its start is known, else into the video
    /// (3:11).
    static func at(_ seconds: Double?, start: String?) -> String {
        guard let seconds else { return "—" }
        if let start, let clock = CameraClock.adding(seconds, to: start) { return String(clock.suffix(8)) }
        let n = Int(seconds.rounded())
        return n >= 3600 ? String(format: "%d:%02d:%02d", n / 3600, n % 3600 / 60, n % 60) : String(format: "%d:%02d", n / 60, n % 60)
    }

    /// 56 cycles: 21 observed, 35 estimated.
    static func cycles(_ total: Int, observed: Int, estimated: Int) -> String {
        "\(total) \(total == 1 ? "cycle" : "cycles"): \(observed) observed, \(estimated) estimated"
    }

    /// +12% or −3 pts.
    static func change(_ c: Comparison.Change) -> String {
        let sign = c.by > 0 ? "+" : c.by < 0 ? "−" : "±"
        let size = abs(c.by)
        return c.inPoints ? "\(sign)\(number(size, digits: size < 10 ? 1 : 0)) pts" : "\(sign)\(Int(size.rounded()))%"
    }

    /// The camera's clock as a date here, to place on a chart; nil when unknown.
    static func date(_ start: String?) -> Date? {
        guard let start else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: start)
    }

    /// 2 Feb 2024, 16:00 from the camera's clock.
    static func clock(_ start: String?) -> String {
        guard let start, start.count >= 16 else { return "Time unknown" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = f.date(from: start) else { return start }
        let out = DateFormatter()
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }
}

/// A table at its own width, scrolled sideways only in a window narrower than it.
struct Wide<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content
            ScrollView(.horizontal) {
                content
                    .padding(.bottom, 4)
            }
        }
    }
}

/// A table cell on one line.
struct Cell: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// A section's title, its explanation under the pointer on the ⓘ beside it.
struct SectionTitle: View {
    let title: String
    let help: String

    init(_ title: String, help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)
            Info(help)
        }
    }
}

/// An ⓘ whose explanation shows under the pointer.
struct Info: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .help(text)
    }
}

/// A page's heading, in place of the window's title bar: a way back, its title, a line on what it covers (with its
/// explanation under the pointer), and its actions on the trailing side.
struct PageHeader<Actions: View>: View {
    var back: PageBack?
    let title: String
    let subtitle: String
    var info: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let back {
                Button(action: back.action) {
                    Image(systemName: "chevron.left")
                        .font(.title2.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to \(back.to) (⌘[)")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let info { Info(info) }
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                actions
            }
        }
    }
}

/// Where a page's back arrow goes, and what it is called.
struct PageBack {
    let to: String
    let action: () -> Void
}

/// A page's action: a small rounded button, drawn by SwiftUI alone (so a page renders whole offscreen too).
struct PageButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(PageLabelStyle())
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .frame(minWidth: 30, minHeight: 28)
            .background(.quaternary.opacity(configuration.isPressed ? 0.9 : 0.55), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

/// An icon and a title, or the icon alone for a label whose title is empty.
private struct PageLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

extension ButtonStyle where Self == PageButtonStyle {
    static var page: PageButtonStyle { PageButtonStyle() }
}
