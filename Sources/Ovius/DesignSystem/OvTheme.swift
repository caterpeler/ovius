import SwiftUI

/// The Ovius look: a warm grey canvas, white cards on soft shadows, near-black ink, one sage accent, and pill-shaped
/// controls. Inverse cards (near-black in light mode, near-white in dark) carry the figure that matters most.
public enum Ov {

    // MARK: - Surfaces

    /// The window behind every card.
    public static let canvas = Color.dynamic(light: Color(hex: 0xEDEDEA), dark: Color(hex: 0x111111))
    /// A card.
    public static let card = Color.dynamic(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1B1B1B))
    /// Wells inside a card: a segmented control's track, a side panel, a search field.
    public static let sunken = Color.dynamic(light: Color(hex: 0xF4F4F1), dark: Color(hex: 0x242424))
    /// The emphasised card, and primary buttons.
    public static let inverse = Color.dynamic(light: Color(hex: 0x111111), dark: Color(hex: 0xF0F0EC))

    // MARK: - Ink

    public static let ink = Color.dynamic(light: Color(hex: 0x111111), dark: Color(hex: 0xF0F0EC))
    public static let ink2 = Color.dynamic(light: Color(hex: 0x6C6C68), dark: Color(hex: 0xA4A4A0))
    public static let ink3 = Color.dynamic(light: Color(hex: 0xA3A39E), dark: Color(hex: 0x6C6C69))
    public static let onInverse = Color.dynamic(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x111111))
    public static let onInverse2 = Color.dynamic(light: Color.white.opacity(0.6), dark: Color.black.opacity(0.55))
    public static let hairline = Color.dynamic(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.08))

    // MARK: - Accent and tones

    /// The selected navigation item, the tinted card.
    public static let sage = Color.dynamic(light: Color(hex: 0xDDEAE5), dark: Color(hex: 0x1E2C28))
    /// Sage strong enough to read as data (a tile, a ring).
    public static let sageStrong = Color.dynamic(light: Color(hex: 0xA8CABE), dark: Color(hex: 0x3F6156))
    public static let sageInk = Color.dynamic(light: Color(hex: 0x2D5A4E), dark: Color(hex: 0x9FCDBD))
    /// A live status dot.
    public static let live = Color(hex: 0x37B072)
    public static let positiveBg = Color.dynamic(light: Color(hex: 0xE2F2E9), dark: Color(hex: 0x173022))
    public static let positiveInk = Color.dynamic(light: Color(hex: 0x1F7A4A), dark: Color(hex: 0x6FD39C))
    public static let negativeBg = Color.dynamic(light: Color(hex: 0xF9E3E3), dark: Color(hex: 0x3A1D1D))
    public static let negativeInk = Color.dynamic(light: Color(hex: 0xB3262E), dark: Color(hex: 0xF08A8A))
    public static let warningBg = Color.dynamic(light: Color(hex: 0xFBF0DA), dark: Color(hex: 0x33290F))
    public static let warningInk = Color.dynamic(light: Color(hex: 0x8A5A0B), dark: Color(hex: 0xE9BE64))

    // MARK: - Data tiles (most to least emphasis)

    public static let tileStrong = Color.dynamic(light: Color(hex: 0x141414), dark: Color(hex: 0xEDEDE9))
    public static let tileMid = Color.dynamic(light: Color(hex: 0x8C8C88), dark: Color(hex: 0x7E7E7A))
    public static let tileSage = sageStrong
    public static let tileEmpty = Color.dynamic(light: Color(hex: 0xE7E7E3), dark: Color(hex: 0x2A2A2A))

    // MARK: - Shape and spacing

    public enum Radius {
        public static let card: CGFloat = 20
        public static let inner: CGFloat = 14
        public static let control: CGFloat = 12
        public static let small: CGFloat = 8
    }

    public enum Space {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 28
        /// Around a page's content.
        public static let page: CGFloat = 28
    }
}

// MARK: - Type

/// The type scale: a large, tightly tracked display title, card values a step below, and quiet labels.
public enum OvTextStyle {
    case display, title, value, valueLarge, heading, body, label, caption, eyebrow

    var font: Font {
        switch self {
        case .display: .system(size: 38, weight: .medium)
        case .title: .system(size: 20, weight: .semibold)
        case .value: .system(size: 30, weight: .medium)
        case .valueLarge: .system(size: 52, weight: .medium)
        case .heading: .system(size: 15, weight: .semibold)
        case .body: .system(size: 14)
        case .label: .system(size: 13)
        case .caption: .system(size: 12)
        case .eyebrow: .system(size: 11, weight: .semibold)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .display: -1.2
        case .valueLarge: -1.6
        case .value: -0.6
        case .title: -0.3
        case .eyebrow: 0.9
        default: 0
        }
    }

    var isNumeric: Bool { self == .value || self == .valueLarge }
}

public extension View {
    /// Sets a type style from the Ovius scale.
    func ovText(_ style: OvTextStyle) -> some View {
        font(style.isNumeric ? style.font.monospacedDigit() : style.font)
            .tracking(style.tracking)
    }
}

// MARK: - Cards

/// How a card stands out from the canvas.
public enum OvCardStyle: Sendable {
    /// White, on a soft shadow.
    case plain
    /// Sage: a figure that is going well, or the selected thing.
    case tinted
    /// Near-black: the one figure to look at first.
    case inverse
    /// A well inside another card.
    case sunken
}

extension EnvironmentValues {
    /// Whether the view sits on an inverse card, so ink should be light.
    @Entry public var ovInverse: Bool = false
}

public extension View {
    /// Draws the view as an Ovius card.
    func ovCard(_ style: OvCardStyle = .plain, padding: CGFloat? = Ov.Space.xl, radius: CGFloat = Ov.Radius.card) -> some View {
        modifier(OvCardModifier(style: style, padding: padding, radius: radius))
    }
}

struct OvCardModifier: ViewModifier {
    let style: OvCardStyle
    let padding: CGFloat?
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding ?? 0)
            .environment(\.ovInverse, style == .inverse)
            .foregroundStyle(style == .inverse ? Ov.onInverse : Ov.ink)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: style == .sunken ? .clear : Self.shadowNear, radius: 1, y: 1)
            .shadow(color: style == .sunken ? .clear : Self.shadowFar, radius: 16, y: 8)
    }

    private var fill: Color {
        switch style {
        case .plain: Ov.card
        case .tinted: Ov.sage
        case .inverse: Ov.inverse
        case .sunken: Ov.sunken
        }
    }

    /// Shadows carry a card in light mode; a hairline does in dark.
    private var border: Color {
        style == .sunken ? .clear : Color.dynamic(light: .clear, dark: Color.white.opacity(0.06))
    }

    static let shadowNear = Color.dynamic(light: Color.black.opacity(0.04), dark: .clear)
    static let shadowFar = Color.dynamic(light: Color.black.opacity(0.05), dark: .clear)
}

// MARK: - Buttons

/// Pill buttons: primary (inverse fill), secondary (a white card), quiet (no fill) and destructive.
public struct OvButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, quiet, destructive }
    public enum Size: Sendable { case regular, small }

    public let kind: Kind
    public let size: Size
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind = .secondary, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .regular ? 14 : 12.5, weight: .medium))
            .labelStyle(OvLabelStyle())
            .padding(.horizontal, size == .regular ? 18 : 12)
            .frame(minHeight: size == .regular ? 40 : 30)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .shadow(color: kind == .secondary ? OvCardModifier.shadowFar : .clear, radius: 8, y: 3)
            .overlay(Capsule().strokeBorder(kind == .secondary ? Ov.hairline : .clear, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Ov.onInverse
        case .secondary: Ov.ink
        case .quiet: Ov.ink2
        case .destructive: Ov.negativeInk
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Ov.inverse
        case .secondary: Ov.card
        case .quiet: .clear
        case .destructive: Ov.negativeBg
        }
    }
}

/// An icon and a title a little apart, as the pill buttons show them.
struct OvLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
            configuration.title
        }
    }
}

public extension ButtonStyle where Self == OvButtonStyle {
    static var ovPrimary: OvButtonStyle { OvButtonStyle(.primary) }
    static var ovSecondary: OvButtonStyle { OvButtonStyle(.secondary) }
    static var ovQuiet: OvButtonStyle { OvButtonStyle(.quiet) }
    static func ov(_ kind: OvButtonStyle.Kind, size: OvButtonStyle.Size = .regular) -> OvButtonStyle { OvButtonStyle(kind, size: size) }
}
