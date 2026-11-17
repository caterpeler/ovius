import SwiftUI

/// Shared diagnostic card shell supporting Lead-driven highlighting and horizon metadata badges.
public struct DiagnosticCardContainerView<Content: View>: View {
    public let item: ActiveDiagnosticViewItem
    public let isHighlighted: Bool
    public let isDimmed: Bool
    @ViewBuilder public let content: () -> Content

    public init(
        item: ActiveDiagnosticViewItem,
        isHighlighted: Bool,
        isDimmed: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.item = item
        self.isHighlighted = isHighlighted
        self.isDimmed = isDimmed
        self.content = content
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("#\(item.priorityOrder)")
                                .font(.caption2.monospacedDigit().bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(.rect(cornerRadius: 4))

                            Text(item.cardName)
                                .font(.headline)

                            if isHighlighted {
                                Label("Highlighted", systemImage: "star.fill")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor)
                                    .foregroundStyle(.white)
                                    .clipShape(.rect(cornerRadius: 4))
                            }
                        }

                        Text(item.promptName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if item.showsHorizon {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(item.dateHorizon)
                                .font(.caption.weight(.medium))
                            Text(item.timeHorizon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(item.timeHorizon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !item.triggeredByLeadNames.isEmpty {
                    HStack(spacing: 6) {
                        Text("Triggered by:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(item.triggeredByLeadNames, id: \.self) { leadName in
                            Text(leadName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12))
                                .foregroundStyle(.orange)
                                .clipShape(.rect(cornerRadius: 4))
                        }
                    }
                }

                Divider()

                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHighlighted ? Color.accentColor : Color.clear, lineWidth: isHighlighted ? 2 : 0)
        )
        .opacity(isDimmed ? 0.45 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isHighlighted)
        .animation(.easeInOut(duration: 0.18), value: isDimmed)
    }
}
