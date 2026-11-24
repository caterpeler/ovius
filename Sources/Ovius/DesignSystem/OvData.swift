import SwiftUI

// MARK: - Page header

/// A page's large title, a line of what it covers (each part spaced apart), and its actions on the trailing side.
public struct OvPageHeader<Actions: View>: View {
    public let title: String
    public let details: [String]
    @ViewBuilder public let actions: () -> Actions

    public init(_ title: String, details: [String] = [], @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.details = details
        self.actions = actions
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: Ov.Space.l) {
            VStack(alignment: .leading, spacing: Ov.Space.s) {
                Text(title)
                    .ovText(.display)
                    .foregroundStyle(Ov.ink)
                    .lineLimit(1)
                if !details.isEmpty {
                    HStack(spacing: Ov.Space.l) {
                        ForEach(Array(details.enumerated()), id: \.offset) { k, detail in
                            Text(detail)
                                .foregroundStyle(k == 0 ? Ov.ink2 : Ov.ink)
                        }
                    }
                    .font(.system(size: 14))
                    .lineLimit(1)
                }
            }
            Spacer(minLength: Ov.Space.l)
            HStack(spacing: Ov.Space.s) {
                actions()
            }
        }
    }
}

public extension OvPageHeader where Actions == EmptyView {
    init(_ title: String, details: [String] = []) {
        self.init(title, details: details) { EmptyView() }
    }
}

// MARK: - KPI cards

/// A change against something earlier: its arrow and size, red or green by whether it is better.
public struct OvDeltaChip: View {
    public enum Tone: Sendable { case positive, negative, neutral }

    public let text: String
    public let isUp: Bool
    public let tone: Tone

    public init(_ text: String, isUp: Bool, tone: Tone) {
        self.text = text
        self.isUp = isUp
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isUp ? "arrow.up" : "arrow.down")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(ink)
        .background(fill, in: Capsule())
    }

    private var ink: Color {
        switch tone {
        case .positive: Ov.positiveInk
        case .negative: Ov.negativeInk
        case .neutral: Ov.ink2
        }
    }

    private var fill: Color {
        switch tone {
        case .positive: Ov.positiveBg
        case .negative: Ov.negativeBg
        case .neutral: Ov.sunken
        }
    }
}

/// One figure on its card: what it is (icon and title), its value, and a line under it, a change chip in front of
/// that line when there is one. An accessory (a ring) can sit on the trailing side.
public struct OvKPICard<Accessory: View>: View {
    public let title: String
    public let systemImage: String
    public let value: String
    public let unit: String?
    public let footnote: String?
    public let delta: OvDeltaChip?
    public let style: OvCardStyle
    @ViewBuilder public let accessory: () -> Accessory

    public init(_ title: String, systemImage: String, value: String, unit: String? = nil, footnote: String? = nil,
                delta: OvDeltaChip? = nil, style: OvCardStyle = .plain, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.unit = unit
        self.footnote = footnote
        self.delta = delta
        self.style = style
        self.accessory = accessory
    }

    public var body: some View {
        let quiet = style == .inverse ? Ov.onInverse2 : Ov.ink2
        HStack(alignment: .center, spacing: Ov.Space.m) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Ov.Space.s) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                    Text(title)
                        .font(.system(size: 13.5))
                        .lineLimit(1)
                }
                .foregroundStyle(quiet)
                Spacer(minLength: Ov.Space.l)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .ovText(.value)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let unit {
                        Text(unit)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(quiet)
                    }
                }
                Spacer(minLength: Ov.Space.l)
                HStack(spacing: Ov.Space.s) {
                    if let delta { delta }
                    if let footnote {
                        Text(footnote)
                            .font(.system(size: 12.5))
                            .foregroundStyle(quiet)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .ovCard(style)
        .accessibilityElement(children: .combine)
    }
}

public extension OvKPICard where Accessory == EmptyView {
    init(_ title: String, systemImage: String, value: String, unit: String? = nil, footnote: String? = nil,
         delta: OvDeltaChip? = nil, style: OvCardStyle = .plain) {
        self.init(title, systemImage: systemImage, value: value, unit: unit, footnote: footnote, delta: delta, style: style) { EmptyView() }
    }
}

/// A share as a ring, its track faint.
public struct OvRingGauge: View {
    public let fraction: Double
    public let size: CGFloat
    public let lineWidth: CGFloat
    @Environment(\.ovInverse) private var inverse

    public init(fraction: Double, size: CGFloat = 72, lineWidth: CGFloat = 8) {
        self.fraction = fraction
        self.size = size
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(inverse ? Ov.onInverse.opacity(0.15) : Ov.sunken, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(inverse ? Ov.onInverse : Ov.sageInk, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(Int((fraction * 100).rounded()))%")
    }
}

// MARK: - Controls

/// Options in a pill-shaped track, the chosen one lifted onto a white pill.
public struct OvSegmentedControl<Value: Hashable>: View {
    @Binding public var selection: Value
    public let options: [(value: Value, title: String)]
    @Namespace private var lift

    public init(selection: Binding<Value>, options: [(value: Value, title: String)]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: chosen ? .medium : .regular))
                        .foregroundStyle(chosen ? Ov.ink : Ov.ink2)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background {
                            if chosen {
                                Capsule()
                                    .fill(Ov.card)
                                    .shadow(color: OvCardModifier.shadowFar, radius: 4, y: 1)
                                    .matchedGeometryEffect(id: "lift", in: lift)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Ov.sunken, in: Capsule())
    }
}

/// A dropdown as a pill: what is chosen, and a chevron.
public struct OvPillMenu<Content: View>: View {
    public let title: String
    public let systemImage: String?
    @ViewBuilder public let content: () -> Content

    public init(_ title: String, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    public var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ov.ink2)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Ov.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Ov.ink3)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Ov.sunken, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Tile chart

/// What a tile counts, in order of emphasis.
public enum OvTileKind: Hashable, Sendable {
    case strong, mid, sage, empty

    public var color: Color {
        switch self {
        case .strong: Ov.tileStrong
        case .mid: Ov.tileMid
        case .sage: Ov.tileSage
        case .empty: Ov.tileEmpty
        }
    }
}

/// A day (or any bucket) of the tile chart: its label, and its tiles from the bottom up.
public struct OvTileColumn: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let tiles: [OvTileKind]

    public init(id: String, label: String, tiles: [OvTileKind]) {
        self.id = id
        self.label = label
        self.tiles = tiles
    }
}

/// Columns of rounded tiles, each tile a batch: the strongest kind at the bottom, empty capacity on top. A column can be
/// picked, and the picked one is lifted onto a white lane.
public struct OvTileChart: View {
    public let columns: [OvTileColumn]
    public let rows: Int
    @Binding public var selection: String?
    /// Every how many columns a label is shown.
    public let labelEvery: Int

    public init(columns: [OvTileColumn], rows: Int, selection: Binding<String?>, labelEvery: Int = 2) {
        self.columns = columns
        self.rows = rows
        self._selection = selection
        self.labelEvery = labelEvery
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { k, column in
                let picked = selection == column.id
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = column.id }
                } label: {
                    VStack(spacing: 6) {
                        VStack(spacing: 5) {
                            ForEach(0..<rows, id: \.self) { row in
                                let index = rows - 1 - row
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(index < column.tiles.count ? column.tiles[index].color : Ov.tileEmpty.opacity(0.55))
                                    .frame(minWidth: 12, minHeight: 16, maxHeight: 16)
                            }
                        }
                        .padding(4)
                        .background {
                            if picked {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Ov.card)
                                    .shadow(color: OvCardModifier.shadowFar, radius: 6, y: 2)
                            }
                        }
                        Text(k % labelEvery == labelEvery - 1 || picked ? column.label : " ")
                            .font(.system(size: 11, weight: picked ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(picked ? Ov.ink : Ov.ink3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(column.label)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }
}

/// The key under a chart: a swatch and a name for each kind.
public struct OvLegend: View {
    public let items: [(color: Color, title: String)]

    public init(_ items: [(color: Color, title: String)]) {
        self.items = items
    }

    public var body: some View {
        HStack(spacing: Ov.Space.l) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(item.color)
                        .frame(width: 10, height: 10)
                    Text(item.title)
                        .ovText(.caption)
                        .foregroundStyle(Ov.ink2)
                }
                .fixedSize()
            }
        }
    }
}

/// One part of a whole: its swatch, its name and share, and its count.
public struct OvBreakdownRow: View {
    public let color: Color
    public let title: String
    public let share: String
    public let value: String

    public init(color: Color, title: String, share: String, value: String) {
        self.color = color
        self.title = title
        self.share = share
        self.value = value
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Ov.Space.s) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 11, height: 11)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Ov.ink)
                Text(share)
                    .ovText(.caption)
                    .foregroundStyle(Ov.ink3)
            }
            Spacer(minLength: Ov.Space.s)
            Text(value)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(Ov.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Progress

/// How far along, as dots: filled ones, then faint ones. Up to `maxDots`, wrapping onto more rows, or (`oneRow`) as
/// many as fit on one.
public struct OvDotProgress: View {
    public let value: Int
    public let total: Int
    public let maxDots: Int
    public let dotSize: CGFloat
    public let oneRow: Bool
    @Environment(\.ovInverse) private var inverse

    public init(value: Int, total: Int, maxDots: Int = 40, dotSize: CGFloat = 7, oneRow: Bool = false) {
        self.value = value
        self.total = total
        self.maxDots = maxDots
        self.dotSize = dotSize
        self.oneRow = oneRow
    }

    public var body: some View {
        let gap = dotSize * 0.7
        Group {
            if oneRow {
                GeometryReader { proxy in
                    let fits = Int((proxy.size.width + gap) / (dotSize + gap))
                    HStack(spacing: gap) { dots(max(1, min(fits, maxDots))) }
                }
                .frame(height: dotSize)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dotSize, maximum: dotSize), spacing: gap)], alignment: .leading, spacing: gap) {
                    dots(max(1, min(total, maxDots)))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(value) of \(total)")
    }

    /// `count` dots, the filled share of them first.
    private func dots(_ count: Int) -> some View {
        let filled = total > 0 ? Int((Double(value) / Double(total) * Double(count)).rounded()) : 0
        let ink = inverse ? Ov.onInverse : Ov.ink
        return ForEach(0..<count, id: \.self) { k in
            Circle()
                .fill(k < filled ? ink : ink.opacity(0.22))
                .frame(width: dotSize, height: dotSize)
        }
    }
}

/// A thin bar for a share.
public struct OvProgressBar: View {
    public let fraction: Double

    public init(fraction: Double) {
        self.fraction = fraction
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Ov.sunken)
                Capsule().fill(Ov.ink2).frame(width: proxy.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 5)
        .accessibilityLabel("\(Int((fraction * 100).rounded()))%")
    }
}

// MARK: - Highlight and list cards

/// The one thing to look at, on a dark card: its title and a way into it, a large count against its whole, dots for
/// how far along, and a line under them.
public struct OvHighlightCard: View {
    public let title: String
    public let value: Int
    public let total: Int
    public let caption: String
    public let action: (() -> Void)?

    public init(_ title: String, value: Int, total: Int, caption: String, action: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.total = total
        self.caption = caption
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if let action {
                    Button(action: action) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Ov.onInverse.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(title)")
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(value)")
                    .ovText(.valueLarge)
                Text("/\(total)")
                    .font(.system(size: 20, weight: .medium).monospacedDigit())
                    .foregroundStyle(Ov.onInverse2)
            }
            OvDotProgress(value: value, total: total)
            Text(caption)
                .font(.system(size: 12.5))
                .foregroundStyle(Ov.onInverse2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .ovCard(.inverse, padding: 24)
    }
}

/// A row of a list card: initials, a name and the line under it, a bar for its share, and its figure.
public struct OvListRow: View {
    public let initials: String
    public let title: String
    public let subtitle: String
    public let fraction: Double?
    public let value: String

    public init(initials: String, title: String, subtitle: String, fraction: Double? = nil, value: String) {
        self.initials = initials
        self.title = title
        self.subtitle = subtitle
        self.fraction = fraction
        self.value = value
    }

    public var body: some View {
        HStack(spacing: Ov.Space.m) {
            OvAvatar(initials: initials, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(Ov.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .ovText(.caption)
                    .foregroundStyle(Ov.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: Ov.Space.m)
            if let fraction {
                OvProgressBar(fraction: fraction)
                    .frame(width: 56)
            }
            Text(value)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(Ov.ink)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .padding(.vertical, Ov.Space.s)
        .accessibilityElement(children: .combine)
    }
}

/// A card's title, the line under it, and an action on the trailing side.
public struct OvCardHeader<Trailing: View>: View {
    public let title: String
    public let subtitle: String?
    @ViewBuilder public let trailing: () -> Trailing

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Ov.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Ov.ink2)
                }
            }
            Spacer(minLength: Ov.Space.m)
            trailing()
        }
    }
}

public extension OvCardHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}
