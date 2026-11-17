import SwiftUI

/// Calm Apple HIG metric card surface with an icon/title header row and breathable body rows.
public struct MetricPanelCard<Content: View>: View {
    public let title: String
    public let systemImage: String
    public let accent: Tokens.AccentColor
    @ViewBuilder public let content: () -> Content

    public init(
        title: String,
        systemImage: String,
        accent: Tokens.AccentColor,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.standard) {
            HStack(spacing: OviusDesign.Spacing.tight) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(accent.text)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.text)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(OviusDesign.Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panelSurface(
            background: Tokens.surface,
            borderColor: Tokens.border.opacity(0.65),
            radius: OviusDesign.Radius.card
        )
    }
}
