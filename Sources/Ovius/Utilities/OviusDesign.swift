import SwiftUI

/// Centralized Ovius layout metrics and panel surface styling helpers aligned to Apple HIG proportions.
public enum OviusDesign {
    public enum Spacing {
        public static let tight: CGFloat = 6
        public static let compact: CGFloat = 8
        public static let standard: CGFloat = 12
        public static let section: CGFloat = 16
        public static let page: CGFloat = 20
    }

    public enum Radius {
        public static let control: CGFloat = 6
        public static let card: CGFloat = 8
    }

    public enum Column {
        public static let sidebarMin: CGFloat = 185
        public static let sidebarIdeal: CGFloat = 210
        public static let sidebarMax: CGFloat = 250

        public static let contentMin: CGFloat = 290
        public static let contentIdeal: CGFloat = 325
        public static let contentMax: CGFloat = 410

        public static let detailMin: CGFloat = 540
    }
}

public extension View {
    /// Applies a subtle continuous-corner panel surface with a soft hairline border.
    func panelSurface(
        background: Color = Tokens.surface,
        borderColor: Color = Tokens.border.opacity(0.65),
        radius: CGFloat = OviusDesign.Radius.card
    ) -> some View {
        self
            .background(background, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }
}
