import SwiftUI

/// Native middle `NavigationSplitView` column for Settings categories.
public struct SettingsCategoryListView: View {
    @Binding public var selectedCategory: SettingsCategory?

    public init(selectedCategory: Binding<SettingsCategory?>) {
        self._selectedCategory = selectedCategory
    }

    public var body: some View {
        List(SettingsCategory.allCases, selection: $selectedCategory) { category in
            Label {
                VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight / 2) {
                    Text(category.title)
                        .font(.callout)
                        .foregroundStyle(Tokens.text)
                    Text(category.subtitle)
                        .font(.footnote)
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: category.systemImage)
                    .foregroundStyle(Tokens.primary.text)
            }
            .padding(.vertical, OviusDesign.Spacing.tight / 2)
            .tag(category)
            .listRowSeparatorTint(Tokens.border)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Tokens.bg)
        .navigationSplitViewColumnWidth(
            min: OviusDesign.Column.contentMin - 40,
            ideal: 255,
            max: 320
        )
    }
}
