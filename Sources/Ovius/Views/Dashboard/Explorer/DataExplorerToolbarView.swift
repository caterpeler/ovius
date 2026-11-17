import SwiftUI

/// Unified Data Explorer header integrating breadcrumb navigation, search field, and contextual filter controls.
public struct DataExplorerToolbarView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable public var explorer: DataExplorerViewModel
    public let sections: [Section]
    public let cameras: [String]
    public let onPopToRecordings: () -> Void
    public let onPopToCycles: () -> Void

    public init(
        explorer: DataExplorerViewModel,
        sections: [Section],
        cameras: [String],
        onPopToRecordings: @escaping () -> Void,
        onPopToCycles: @escaping () -> Void
    ) {
        self.explorer = explorer
        self.sections = sections
        self.cameras = cameras
        self.onPopToRecordings = onPopToRecordings
        self.onPopToCycles = onPopToCycles
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.compact) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: OviusDesign.Spacing.compact) {
                    breadcrumb
                    searchField
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: OviusDesign.Spacing.standard) {
                        breadcrumb
                        Spacer(minLength: OviusDesign.Spacing.standard)
                        searchField
                            .frame(minWidth: 220, maxWidth: 290)
                    }

                    VStack(alignment: .leading, spacing: OviusDesign.Spacing.compact) {
                        breadcrumb
                        searchField
                    }
                }
            }

            ExplorerFilterControlsView(
                explorer: explorer,
                sections: sections,
                cameras: cameras
            )
        }
    }

    private var breadcrumb: some View {
        DataExplorerBreadcrumbView(
            explorer: explorer,
            onPopToRecordings: onPopToRecordings,
            onPopToCycles: onPopToCycles
        )
    }

    private var searchField: some View {
        HStack(spacing: OviusDesign.Spacing.tight) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tokens.text3)
                .accessibilityHidden(true)

            TextField("Search ID, camera, machine, location…", text: $explorer.explorerSearchText)
                .textFieldStyle(.plain)
                .foregroundStyle(Tokens.text)
                .accessibilityLabel("Search Data Explorer")

            if !explorer.explorerSearchText.isEmpty {
                Button("Clear Explorer Search", systemImage: "xmark.circle.fill", action: clearSearch)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Tokens.text3)
            }
        }
        .padding(.horizontal, OviusDesign.Spacing.compact)
        .padding(.vertical, OviusDesign.Spacing.tight)
        .panelSurface(
            background: Tokens.surface,
            borderColor: Tokens.border.opacity(0.6),
            radius: OviusDesign.Radius.control
        )
    }

    private func clearSearch() {
        explorer.explorerSearchText = ""
    }
}
