import SwiftUI

/// Loading placeholder shown over the Data Explorer whenever initial telemetry loads.
public struct SectionLoadingPlaceholderView: View {
    public let title: String
    public let subtitle: String
    public let minHeight: CGFloat

    public init(title: String, subtitle: String, minHeight: CGFloat = 120) {
        self.title = title
        self.subtitle = subtitle
        self.minHeight = minHeight
    }

    public var body: some View {
        VStack(spacing: OviusDesign.Spacing.standard) {
            ProgressView()
                .controlSize(.regular)
            Text(title)
                .font(.headline)
                .foregroundStyle(Tokens.text)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(Tokens.text2)
                .multilineTextAlignment(.center)
        }
        .padding(OviusDesign.Spacing.page)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity)
        .panelSurface(
            background: Tokens.surface,
            borderColor: Tokens.border,
            radius: Tokens.radiusLg
        )
    }
}
