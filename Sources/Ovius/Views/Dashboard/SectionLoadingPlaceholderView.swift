import SwiftUI

/// Clean loading placeholder shown over Diagnostic Cards and Data Explorer whenever cross-filters update.
public struct SectionLoadingPlaceholderView: View {
    public let title: String
    public let subtitle: String
    public let minHeight: CGFloat

    public init(title: String, subtitle: String, minHeight: CGFloat = 180) {
        self.title = title
        self.subtitle = subtitle
        self.minHeight = minHeight
    }

    public var body: some View {
        GroupBox {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
        }
    }
}
