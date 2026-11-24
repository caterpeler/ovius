import SwiftUI

/// The Settings list column: one row per category.
public struct SettingsCategoryListView: View {
    @Binding public var selectedCategory: SettingsCategory?

    public init(selectedCategory: Binding<SettingsCategory?>) {
        self._selectedCategory = selectedCategory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.s) {
            Text("Settings")
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.2)
                .padding(.bottom, Ov.Space.s)
            ForEach(SettingsCategory.allCases) { row($0) }
            Spacer()
        }
        .padding(Ov.Space.l)
    }

    private func row(_ category: SettingsCategory) -> some View {
        let on = (selectedCategory ?? .endpoint) == category
        return Button { selectedCategory = category } label: {
            HStack(spacing: Ov.Space.m) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(on ? Ov.card : Ov.sunken, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.system(size: 14, weight: on ? .semibold : .medium))
                    Text(category.subtitle).font(.system(size: 12)).foregroundStyle(Ov.ink2).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(Ov.Space.s)
            .background(on ? Ov.sage : .clear, in: RoundedRectangle(cornerRadius: Ov.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
