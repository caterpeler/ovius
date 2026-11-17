import SwiftUI

/// Accessible label-value row used inside Dashboard metric panels, stacking vertically
/// under large Dynamic Type sizes.
public struct MetricValueRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight / 2) {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(Tokens.text2)
                    Text(value)
                        .font(.callout.monospacedDigit().bold())
                        .foregroundStyle(Tokens.text)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.footnote)
                        .foregroundStyle(Tokens.text2)
                    Spacer(minLength: OviusDesign.Spacing.compact)
                    Text(value)
                        .font(.callout.monospacedDigit().bold())
                        .foregroundStyle(Tokens.text)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
