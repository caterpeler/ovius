import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Color Hex & Dynamic Extensions

extension Color {
    public init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }

    public static func dynamic(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        return light
        #endif
    }
}

// MARK: - Visual Tokens

public enum Tokens {

    // MARK: - Surfaces

    public enum Surface {
        public static let bg          = Color.dynamic(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1E1E1E))
        public static let surface     = Color.dynamic(light: Color(hex: 0xF5F5F5), dark: Color(hex: 0x2B2B2B))
        public static let raised      = Color.dynamic(light: Color(hex: 0xEBEBEB), dark: Color(hex: 0x333536))
        public static let tableStripe = Color.dynamic(light: Color(hex: 0xFAFAFA), dark: Color(hex: 0x242424))
        public static let overlay     = Color.dynamic(light: Color.black.opacity(0.06), dark: Color.black.opacity(0.30))
    }

    // MARK: - Text / Ink

    public enum Text {
        public static let primary   = Color.dynamic(light: Color(hex: 0x2B2B2B), dark: Color(hex: 0xDCDCDC))
        public static let secondary = Color.dynamic(light: Color(hex: 0x636363), dark: Color(hex: 0xA9B7C6))
        public static let tertiary  = Color.dynamic(light: Color(hex: 0x999999), dark: Color(hex: 0x787878))
        public static let onAccent  = Color.white
    }

    // MARK: - Borders

    public enum Border {
        public static let primary   = Color.dynamic(light: Color(hex: 0xD1D1D1), dark: Color(hex: 0x505355))
        public static let secondary = Color.dynamic(light: Color(hex: 0xBEBEBE), dark: Color(hex: 0x636567))
    }

    // MARK: - Accent Color (12 Semantic Accents)

    public struct AccentColor: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let fill: Color
        public let hover: Color
        public let subtle: Color
        public let text: Color

        public var color: Color { fill }

        public init(name: String, fill: Color, hover: Color, subtle: Color, text: Color) {
            self.name = name
            self.fill = fill
            self.hover = hover
            self.subtle = subtle
            self.text = text
        }
    }

    public static let primary = AccentColor(
        name: "primary",
        fill: Color.dynamic(light: Color(hex: 0x2E65CC), dark: Color(hex: 0x3568C0)),
        hover: Color.dynamic(light: Color(hex: 0x2758B3), dark: Color(hex: 0x4075CA)),
        subtle: Color.dynamic(light: Color(hex: 0xE5ECF8), dark: Color(hex: 0x1C2840)),
        text: Color.dynamic(light: Color(hex: 0x24508F), dark: Color(hex: 0x5A95F5))
    )

    public static let success = AccentColor(
        name: "success",
        fill: Color.dynamic(light: Color(hex: 0x3C7A47), dark: Color(hex: 0x3A8248)),
        hover: Color.dynamic(light: Color(hex: 0x326A3C), dark: Color(hex: 0x449050)),
        subtle: Color.dynamic(light: Color(hex: 0xEBF4ED), dark: Color(hex: 0x1C2D20)),
        text: Color.dynamic(light: Color(hex: 0x2F6338), dark: Color(hex: 0x6AAF72))
    )

    public static let warning = AccentColor(
        name: "warning",
        fill: Color.dynamic(light: Color(hex: 0xD9A74E), dark: Color(hex: 0xC9A344)),
        hover: Color.dynamic(light: Color(hex: 0xC49542), dark: Color(hex: 0xD0AD55)),
        subtle: Color.dynamic(light: Color(hex: 0xFBF0D9), dark: Color(hex: 0x2C2618)),
        text: Color.dynamic(light: Color(hex: 0x654D16), dark: Color(hex: 0xE8BF6A))
    )

    public static let danger = AccentColor(
        name: "danger",
        fill: Color.dynamic(light: Color(hex: 0xC94448), dark: Color(hex: 0xBD4848)),
        hover: Color.dynamic(light: Color(hex: 0xB33B3F), dark: Color(hex: 0xC85555)),
        subtle: Color.dynamic(light: Color(hex: 0xFBEAEA), dark: Color(hex: 0x2D1C1C)),
        text: Color.dynamic(light: Color(hex: 0x8C2424), dark: Color(hex: 0xE07070))
    )

    public static let info = AccentColor(
        name: "info",
        fill: Color.dynamic(light: Color(hex: 0x3E6FA3), dark: Color(hex: 0x4578A3)),
        hover: Color.dynamic(light: Color(hex: 0x356192), dark: Color(hex: 0x5085B0)),
        subtle: Color.dynamic(light: Color(hex: 0xE5EDF5), dark: Color(hex: 0x1C2838)),
        text: Color.dynamic(light: Color(hex: 0x335C87), dark: Color(hex: 0x7EAED4))
    )

    public static let purple = AccentColor(
        name: "purple",
        fill: Color.dynamic(light: Color(hex: 0x7B5D96), dark: Color(hex: 0x7A5D96)),
        hover: Color.dynamic(light: Color(hex: 0x6B5084), dark: Color(hex: 0x866BA0)),
        subtle: Color.dynamic(light: Color(hex: 0xEFEBF3), dark: Color(hex: 0x282032)),
        text: Color.dynamic(light: Color(hex: 0x583F6E), dark: Color(hex: 0xAD8FBF))
    )

    public static let teal = AccentColor(
        name: "teal",
        fill: Color.dynamic(light: Color(hex: 0x2D7373), dark: Color(hex: 0x2D7878)),
        hover: Color.dynamic(light: Color(hex: 0x256464), dark: Color(hex: 0x358585)),
        subtle: Color.dynamic(light: Color(hex: 0xE4EFEF), dark: Color(hex: 0x1C2D2D)),
        text: Color.dynamic(light: Color(hex: 0x245454), dark: Color(hex: 0x4DA6A6))
    )

    public static let orange = AccentColor(
        name: "orange",
        fill: Color.dynamic(light: Color(hex: 0xA25B22), dark: Color(hex: 0xA8622C)),
        hover: Color.dynamic(light: Color(hex: 0x8E4F1D), dark: Color(hex: 0xB57038)),
        subtle: Color.dynamic(light: Color(hex: 0xF8EDE2), dark: Color(hex: 0x2D2218)),
        text: Color.dynamic(light: Color(hex: 0x854A1B), dark: Color(hex: 0xD4894A))
    )

    public static let indigo = AccentColor(
        name: "indigo",
        fill: Color.dynamic(light: Color(hex: 0x4B47A8), dark: Color(hex: 0x4B47A8)),
        hover: Color.dynamic(light: Color(hex: 0x423EA0), dark: Color(hex: 0x5854B2)),
        subtle: Color.dynamic(light: Color(hex: 0xEEEDF8), dark: Color(hex: 0x222040)),
        text: Color.dynamic(light: Color(hex: 0x3A3580), dark: Color(hex: 0x9A95DA))
    )

    public static let rose = AccentColor(
        name: "rose",
        fill: Color.dynamic(light: Color(hex: 0xB83658), dark: Color(hex: 0xB83658)),
        hover: Color.dynamic(light: Color(hex: 0xA83050), dark: Color(hex: 0xC44068)),
        subtle: Color.dynamic(light: Color(hex: 0xFBEAEE), dark: Color(hex: 0x2D1C22)),
        text: Color.dynamic(light: Color(hex: 0x8A2440), dark: Color(hex: 0xE07090))
    )

    public static let lime = AccentColor(
        name: "lime",
        fill: Color.dynamic(light: Color(hex: 0x4A8018), dark: Color(hex: 0x4A8018)),
        hover: Color.dynamic(light: Color(hex: 0x417215), dark: Color(hex: 0x559222)),
        subtle: Color.dynamic(light: Color(hex: 0xF0F6E4), dark: Color(hex: 0x1E2C14)),
        text: Color.dynamic(light: Color(hex: 0x33580F), dark: Color(hex: 0x8DC050))
    )

    public static let slate = AccentColor(
        name: "slate",
        fill: Color.dynamic(light: Color(hex: 0x5A6577), dark: Color(hex: 0x5A6577)),
        hover: Color.dynamic(light: Color(hex: 0x515C6E), dark: Color(hex: 0x657282)),
        subtle: Color.dynamic(light: Color(hex: 0xEEF0F3), dark: Color(hex: 0x1E2228)),
        text: Color.dynamic(light: Color(hex: 0x3E4854), dark: Color(hex: 0x94A0B0))
    )

    public static let warningOnAccent = Color(hex: 0x3F300D)

    public static let allAccents: [AccentColor] = [
        primary, success, warning, danger, info, purple,
        teal, orange, indigo, rose, lime, slate
    ]

    // MARK: - Spacing

    public enum Spacing {
        public static let space1: CGFloat  = 4
        public static let space2: CGFloat  = 8
        public static let space3: CGFloat  = 12
        public static let space4: CGFloat  = 16
        public static let space5: CGFloat  = 20
        public static let space6: CGFloat  = 24
        public static let space8: CGFloat  = 32
        public static let space10: CGFloat = 40
        public static let space12: CGFloat = 48

        public static let sm: CGFloat = space1
        public static let md: CGFloat = space3
        public static let lg: CGFloat = space6
        public static let xl: CGFloat = space8
    }

    // MARK: - Radii

    public enum Radius {
        public static let `default`: CGFloat = 2
        public static let sm: CGFloat = 2
        public static let md: CGFloat = 3
        public static let lg: CGFloat = 4
    }

    // MARK: - Shadows

    public enum Shadow {
        public static let smColor = Color.dynamic(light: Color.black.opacity(0.08), dark: Color.black.opacity(0.25))
        public static let mdColor = Color.dynamic(light: Color.black.opacity(0.10), dark: Color.black.opacity(0.35))
        public static let lgColor = Color.dynamic(light: Color.black.opacity(0.12), dark: Color.black.opacity(0.45))
    }

    // MARK: - Animation

    public enum Animation {
        public static let fast: SwiftUI.Animation   = .easeInOut(duration: 0.10)
        public static let normal: SwiftUI.Animation = .easeInOut(duration: 0.15)
        public static let slow: SwiftUI.Animation   = .easeInOut(duration: 0.25)
    }

    // MARK: - Direct Convenience Accessors

    public static let bg: Color          = Surface.bg
    public static let surface: Color     = Surface.surface
    public static let raised: Color      = Surface.raised
    public static let tableStripe: Color = Surface.tableStripe
    public static let overlay: Color     = Surface.overlay

    public static let text: Color        = Text.primary
    public static let text2: Color       = Text.secondary
    public static let text3: Color       = Text.tertiary
    public static let onAccent: Color    = Text.onAccent

    public static let border: Color          = Border.primary
    public static let borderSecondary: Color = Border.secondary

    public static let space0: CGFloat  = 0
    public static let space1: CGFloat  = Spacing.space1
    public static let space2: CGFloat  = Spacing.space2
    public static let space3: CGFloat  = Spacing.space3
    public static let space4: CGFloat  = Spacing.space4
    public static let space5: CGFloat  = Spacing.space5
    public static let space6: CGFloat  = Spacing.space6
    public static let space8: CGFloat  = Spacing.space8
    public static let space10: CGFloat = Spacing.space10
    public static let space12: CGFloat = Spacing.space12

    public static let radius: CGFloat   = Radius.default
    public static let radiusSm: CGFloat = Radius.sm
    public static let radiusMd: CGFloat = Radius.md
    public static let radiusLg: CGFloat = Radius.lg

    public static let shadowSm: Color = Shadow.smColor
    public static let shadowMd: Color = Shadow.mdColor
    public static let shadowLg: Color = Shadow.lgColor
}

// MARK: - Environment & Accent Injection

extension EnvironmentValues {
    @Entry public var appAccent: Tokens.AccentColor = Tokens.primary
}

extension View {
    public func appAccent(_ accent: Tokens.AccentColor) -> some View {
        environment(\.appAccent, accent)
    }
}
