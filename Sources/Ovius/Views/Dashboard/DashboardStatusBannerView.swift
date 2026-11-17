import SwiftUI

/// Inline alert banner rendered inside the Dashboard detail workspace.
public struct DashboardStatusBannerView: View {
    public let title: String
    public let message: String
    public let accent: Tokens.AccentColor
    public let systemImage: String

    public init(title: String, message: String, accent: Tokens.AccentColor, systemImage: String) {
        self.title = title
        self.message = message
        self.accent = accent
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(alignment: .top, spacing: OviusDesign.Spacing.standard) {
            Image(systemName: systemImage)
                .foregroundStyle(accent.text)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight / 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(Tokens.text)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Tokens.text2)
            }

            Spacer(minLength: 0)
        }
        .padding(OviusDesign.Spacing.standard)
        .panelSurface(
            background: accent.subtle,
            borderColor: accent.color.opacity(0.45),
            radius: Tokens.radiusLg
        )
        .accessibilityElement(children: .combine)
    }
}
