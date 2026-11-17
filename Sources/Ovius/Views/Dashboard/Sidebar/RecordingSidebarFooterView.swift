import SwiftUI

/// Bottom status & pagination bar for the recordings column.
public struct RecordingSidebarFooterView: View {
    public let displayedCount: Int
    public let totalCount: Int
    public let selectedCount: Int
    public let hasMore: Bool
    public let remainingCount: Int
    public let pageSize: Int
    public let isFiltering: Bool
    public let progressText: String?
    public let onLoadMore: () -> Void

    public init(
        displayedCount: Int,
        totalCount: Int,
        selectedCount: Int,
        hasMore: Bool,
        remainingCount: Int,
        pageSize: Int,
        isFiltering: Bool,
        progressText: String?,
        onLoadMore: @escaping () -> Void
    ) {
        self.displayedCount = displayedCount
        self.totalCount = totalCount
        self.selectedCount = selectedCount
        self.hasMore = hasMore
        self.remainingCount = remainingCount
        self.pageSize = pageSize
        self.isFiltering = isFiltering
        self.progressText = progressText
        self.onLoadMore = onLoadMore
    }

    public var body: some View {
        VStack(spacing: OviusDesign.Spacing.compact) {
            if hasMore {
                let nextBatch = min(pageSize, remainingCount)
                Button(action: onLoadMore) {
                    Label("Load \(nextBatch) More (\(remainingCount) remaining)", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack {
                Text("\(displayedCount) of \(totalCount) • \(selectedCount) selected")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Tokens.text2)

                Spacer(minLength: OviusDesign.Spacing.compact)

                if isFiltering {
                    HStack(spacing: OviusDesign.Spacing.tight + 2) {
                        if let progressText {
                            Text(progressText)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Tokens.text2)
                        }
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, OviusDesign.Spacing.standard)
        .padding(.vertical, OviusDesign.Spacing.compact)
        .background(Tokens.surface)
    }
}
