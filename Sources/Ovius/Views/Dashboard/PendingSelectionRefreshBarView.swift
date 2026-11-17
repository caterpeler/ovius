import SwiftUI

/// Floating bottom refresh call-to-action displayed when sidebar recording selection differs
/// from the currently projected Dashboard metrics and Data Explorer.
public struct PendingSelectionRefreshBarView: View {
    public let selectedCount: Int
    public let onRefresh: () -> Void

    public init(selectedCount: Int, onRefresh: @escaping () -> Void) {
        self.selectedCount = selectedCount
        self.onRefresh = onRefresh
    }

    public var body: some View {
        Button(action: onRefresh) {
            HStack(spacing: OviusDesign.Spacing.compact) {
                Label("Data selection has changed. Click here to refresh.", systemImage: "arrow.clockwise.circle.fill")
                    .font(.subheadline.bold())
                Text("(\(selectedCount))")
                    .font(.footnote.monospacedDigit())
                    .opacity(0.9)
            }
            .padding(.horizontal, OviusDesign.Spacing.section)
            .padding(.vertical, OviusDesign.Spacing.compact + 2)
            .panelSurface(
                background: Tokens.primary.fill,
                borderColor: Tokens.primary.hover,
                radius: Tokens.radiusLg
            )
            .foregroundStyle(Tokens.onAccent)
            .shadow(color: Tokens.shadowMd, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.vertical, OviusDesign.Spacing.standard)
        .accessibilityHint("Applies the new sidebar recording selection and reloads Dashboard metrics")
    }
}
