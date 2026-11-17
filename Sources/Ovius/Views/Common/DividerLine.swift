import SwiftUI

/// Crisp 1px horizontal separator rule matching `Tokens.border`.
public struct DividerLine: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Tokens.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
