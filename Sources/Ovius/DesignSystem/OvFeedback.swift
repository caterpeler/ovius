import SwiftUI

/// A message across the page: an icon in its tone, a title and what to do.
public struct OvBanner: View {
    public enum Tone: Sendable { case info, warning, error }

    public let tone: Tone
    public let title: String
    public let message: String

    public init(_ tone: Tone, title: String, message: String) {
        self.tone = tone
        self.title = title
        self.message = message
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Ov.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 28, height: 28)
                .background(Ov.card.opacity(0.7), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Ov.ink)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Ov.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Ov.Space.m)
        .background(fill, in: RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch tone {
        case .info: "info"
        case .warning: "exclamationmark"
        case .error: "xmark"
        }
    }

    private var ink: Color {
        switch tone {
        case .info: Ov.sageInk
        case .warning: Ov.warningInk
        case .error: Ov.negativeInk
        }
    }

    private var fill: Color {
        switch tone {
        case .info: Ov.sage
        case .warning: Ov.warningBg
        case .error: Ov.negativeBg
        }
    }
}

/// Nothing to show yet: an icon in a soft disc, a title, what to do, and an action when there is one.
public struct OvEmptyState<Action: View>: View {
    public let systemImage: String
    public let title: String
    public let message: String
    @ViewBuilder public let action: () -> Action

    public init(systemImage: String, title: String, message: String, @ViewBuilder action: @escaping () -> Action) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Ov.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Ov.ink2)
                .frame(width: 52, height: 52)
                .background(Ov.sunken, in: Circle())
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ov.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Ov.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            action()
                .padding(.top, Ov.Space.xs)
        }
        .padding(Ov.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

public extension OvEmptyState where Action == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// Waiting for data: a spinner, what is loading, and why it takes a moment.
public struct OvLoadingState: View {
    public let title: String
    public let message: String

    public init(_ title: String, message: String) {
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: Ov.Space.m) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ov.ink)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Ov.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(Ov.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

/// A labelled text field in a soft well.
public struct OvField: View {
    public let label: String
    public let prompt: String
    @Binding public var text: String
    public let isSecure: Bool

    public init(_ label: String, prompt: String = "", text: Binding<String>, isSecure: Bool = false) {
        self.label = label
        self.prompt = prompt
        self._text = text
        self.isSecure = isSecure
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Ov.ink2)
            Group {
                if isSecure {
                    SecureField(prompt, text: $text)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Ov.ink)
            .padding(.horizontal, Ov.Space.m)
            .frame(height: 40)
            .background(Ov.sunken, in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
        }
    }
}

/// A floating pill at the foot of the page that asks for one action.
public struct OvActionBar: View {
    public let message: String
    public let actionTitle: String
    public let systemImage: String
    public let action: () -> Void

    public init(_ message: String, actionTitle: String, systemImage: String = "arrow.clockwise", action: @escaping () -> Void) {
        self.message = message
        self.actionTitle = actionTitle
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        HStack(spacing: Ov.Space.l) {
            Text(message)
                .font(.system(size: 13.5))
                .foregroundStyle(Ov.onInverse2)
            Button(action: action) {
                Label(actionTitle, systemImage: systemImage)
            }
            .buttonStyle(OvButtonStyle(.secondary, size: .small))
        }
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(Ov.inverse, in: Capsule())
        .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
    }
}

public extension View {
    /// Sets a native table on a white card: rounded, its own background hidden.
    func ovTableCard() -> some View {
        scrollContentBackground(.hidden)
            .padding(.vertical, Ov.Space.xs)
            .ovCard(.plain, padding: 0, radius: 16)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
