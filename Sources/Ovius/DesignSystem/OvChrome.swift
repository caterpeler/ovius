import SwiftUI

// MARK: - Sidebar

/// The app's mark and name at the top of the sidebar, with what it is looking at, and a button that folds the sidebar.
public struct OvBrandHeader: View {
    public let title: String
    public let subtitle: String
    public let systemImage: String
    public let onToggleSidebar: (() -> Void)?

    public init(title: String, subtitle: String, systemImage: String = "viewfinder", onToggleSidebar: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.onToggleSidebar = onToggleSidebar
    }

    public var body: some View {
        HStack(spacing: Ov.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Ov.onInverse)
                .frame(width: 38, height: 38)
                .background(Ov.inverse, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Ov.ink)
                Text(subtitle)
                    .ovText(.caption)
                    .foregroundStyle(Ov.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: Ov.Space.s)
            if let onToggleSidebar {
                OvIconButton("sidebar.left", shape: .square, help: "Hide the sidebar", action: onToggleSidebar)
            }
        }
    }
}

/// A rounded search field with its keyboard shortcut shown at the end.
public struct OvSearchField: View {
    @Binding public var text: String
    public let prompt: String
    public let shortcut: String?

    public init(text: Binding<String>, prompt: String, shortcut: String? = nil) {
        self._text = text
        self.prompt = prompt
        self.shortcut = shortcut
    }

    public var body: some View {
        HStack(spacing: Ov.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ov.ink2)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Ov.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ov.ink3)
                .accessibilityLabel("Clear search")
            } else if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Ov.ink2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Ov.sunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.horizontal, Ov.Space.m)
        .frame(height: 40)
        .ovCard(.plain, padding: 0, radius: Ov.Radius.control)
    }
}

/// A small upper-case label over a group of sidebar items.
public struct OvSectionLabel: View {
    public let title: String
    public let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack {
            Text(title.uppercased())
                .ovText(.eyebrow)
                .foregroundStyle(Ov.ink3)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .ovText(.caption)
                    .foregroundStyle(Ov.ink3)
            }
        }
        .padding(.horizontal, Ov.Space.m)
        .padding(.top, Ov.Space.s)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A sidebar item: its icon and title, a count, and a chevron when it opens more; sage when selected.
public struct OvNavItem: View {
    public let title: String
    public let systemImage: String
    public let count: Int?
    public let showsChevron: Bool
    public let isSelected: Bool
    public let action: () -> Void
    @State private var isHovering = false

    public init(_ title: String, systemImage: String, count: Int? = nil, showsChevron: Bool = false, isSelected: Bool,
                action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.showsChevron = showsChevron
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Ov.Space.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Ov.ink : Ov.ink2)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Ov.ink)
                    .lineLimit(1)
                Spacer(minLength: Ov.Space.s)
                if let count {
                    OvCountBadge(count)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ov.ink3)
                }
            }
            .padding(.horizontal, Ov.Space.m)
            .frame(height: 40)
            .background(fill, in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        isSelected ? Ov.sage : (isHovering ? Ov.sunken : .clear)
    }
}

/// A count in a small black disc.
public struct OvCountBadge: View {
    public let count: Int

    public init(_ count: Int) {
        self.count = count
    }

    public var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Ov.onInverse)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Ov.inverse, in: Capsule())
    }
}

/// A dark card for the bottom of the sidebar: a count against its whole, and dots for how far along.
public struct OvSidebarStatusCard: View {
    public let systemImage: String
    public let value: Int
    public let total: Int
    public let caption: String

    public init(systemImage: String, value: Int, total: Int, caption: String) {
        self.systemImage = systemImage
        self.value = value
        self.total = total
        self.caption = caption
    }

    public var body: some View {
        HStack(spacing: Ov.Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 34)
                .background(Ov.onInverse.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(value)")
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    Text("/\(total) \(caption)")
                        .ovText(.caption)
                        .foregroundStyle(Ov.onInverse2)
                }
                OvDotProgress(value: value, total: total, maxDots: 60, dotSize: 5, oneRow: true)
            }
            Spacer(minLength: 0)
        }
        .ovCard(.inverse, padding: Ov.Space.m, radius: 16)
        .accessibilityElement(children: .combine)
    }
}

/// Who or what the workspace belongs to: initials, a name and a line under it, and a chevron to switch.
public struct OvIdentityRow: View {
    public let initials: String
    public let title: String
    public let subtitle: String
    public let showsSwitcher: Bool

    public init(initials: String, title: String, subtitle: String, showsSwitcher: Bool = true) {
        self.initials = initials
        self.title = title
        self.subtitle = subtitle
        self.showsSwitcher = showsSwitcher
    }

    public var body: some View {
        HStack(spacing: Ov.Space.m) {
            OvAvatar(initials: initials, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Ov.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .ovText(.caption)
                    .foregroundStyle(Ov.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: Ov.Space.s)
            if showsSwitcher {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ov.ink3)
            }
        }
        .padding(.horizontal, Ov.Space.m)
        .padding(.vertical, Ov.Space.s)
        .contentShape(Rectangle())
    }
}

// MARK: - Top bar

/// Where the page is: earlier steps grey (and tappable when they can be gone back to), the current one in ink.
public struct OvBreadcrumb: View {
    public struct Step: Identifiable {
        public let id = UUID()
        public let title: String
        public let action: (() -> Void)?

        public init(_ title: String, action: (() -> Void)? = nil) {
            self.title = title
            self.action = action
        }
    }

    public let steps: [Step]

    public init(_ steps: [Step]) {
        self.steps = steps
    }

    public var body: some View {
        HStack(spacing: Ov.Space.s) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { k, step in
                if k > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ov.ink3)
                        .accessibilityHidden(true)
                }
                let last = k == steps.count - 1
                if let action = step.action, !last {
                    Button(step.title, action: action)
                        .buttonStyle(.plain)
                        .foregroundStyle(Ov.ink2)
                } else {
                    Text(step.title)
                        .foregroundStyle(last ? Ov.ink : Ov.ink2)
                }
            }
        }
        .font(.system(size: 14, weight: .medium))
        .lineLimit(1)
    }
}

/// A short status in a pill, its dot coloured by how things are.
public struct OvStatusPill: View {
    public enum Tone: Sendable { case live, busy, warning, error }

    public let text: String
    public let tone: Tone

    public init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: Ov.Space.s) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
                .background(Circle().fill(dot.opacity(0.25)).frame(width: 13, height: 13))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ov.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(fill, in: Capsule())
    }

    private var dot: Color {
        switch tone {
        case .live: Ov.live
        case .busy: Ov.ink2
        case .warning: Ov.warningInk
        case .error: Ov.negativeInk
        }
    }

    private var fill: Color {
        switch tone {
        case .live: Ov.sage
        case .busy: Ov.sunken
        case .warning: Ov.warningBg
        case .error: Ov.negativeBg
        }
    }
}

/// An icon on its own: a round white button (with a count when there is one), or a small square well.
public struct OvIconButton: View {
    public enum Shape: Sendable { case round, square }

    public let systemImage: String
    public let shape: Shape
    public let count: Int?
    public let help: String
    public let action: () -> Void

    public init(_ systemImage: String, shape: Shape = .round, count: Int? = nil, help: String, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.shape = shape
        self.count = count
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: shape == .round ? 15 : 13, weight: .medium))
                .foregroundStyle(Ov.ink)
                .frame(width: shape == .round ? 40 : 32, height: shape == .round ? 40 : 32)
                .background {
                    if shape == .round {
                        Circle().fill(Ov.card)
                            .shadow(color: OvCardModifier.shadowFar, radius: 8, y: 3)
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Ov.sunken)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let count, count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Ov.onInverse)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Ov.inverse, in: Circle())
                            .offset(x: 2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Initials in a soft disc.
public struct OvAvatar: View {
    public let initials: String
    public let size: CGFloat

    public init(initials: String, size: CGFloat = 36) {
        self.initials = initials
        self.size = size
    }

    public var body: some View {
        Text(initials.prefix(2).uppercased())
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(Ov.ink2)
            .frame(width: size, height: size)
            .background(Ov.sunken, in: Circle())
            .overlay(Circle().strokeBorder(Ov.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }
}
