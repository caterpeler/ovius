import SwiftUI

/// Inline streaming progress indicator shown while telemetry waves are loading.
public struct TelemetryStreamingBannerView: View {
    public let progress: String?

    public init(progress: String?) {
        self.progress = progress
    }

    public var body: some View {
        HStack(spacing: OviusDesign.Spacing.compact) {
            ProgressView()
                .controlSize(.small)
            if let progress {
                Text("Streaming selected telemetry (\(progress))…")
                    .font(.footnote)
                    .foregroundStyle(Tokens.text)
            } else {
                Text("Loading selected telemetry…")
                    .font(.footnote)
                    .foregroundStyle(Tokens.text)
            }
            Spacer()
        }
        .padding(.horizontal, OviusDesign.Spacing.standard)
        .padding(.vertical, OviusDesign.Spacing.compact)
        .panelSurface(
            background: Tokens.info.subtle,
            borderColor: Tokens.info.color.opacity(0.45),
            radius: Tokens.radiusLg
        )
    }
}
