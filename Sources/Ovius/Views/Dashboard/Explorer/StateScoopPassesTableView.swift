import SwiftUI

/// Native inset sortable sub-table displaying embedded bucket scoop passes (`ScoopTimingDTO`) inside Layer 3.
public struct StateScoopPassesTableView: View {
    public let rows: [ScoopTimingExplorerRow]

    @State private var sortOrder: [KeyPathComparator<ScoopTimingExplorerRow>] = [
        .init(\.scoopNumber, order: .forward)
    ]
    @State private var sortedRows: [ScoopTimingExplorerRow] = []

    public init(rows: [ScoopTimingExplorerRow]) {
        self.rows = rows
    }

    private func refreshSortedRows() {
        sortedRows = rows.sorted(using: sortOrder)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight) {
            Text("Embedded Bucket Scoop Passes (\(rows.count))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Tokens.text)

            Table(sortedRows, sortOrder: $sortOrder) {
                TableColumn("Scoop #", value: \.scoopNumber) { row in
                    Text("#\(row.scoopNumber)")
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Tokens.text)
                }
                .width(min: 55, ideal: 65)

                TableColumn("Excavator Segment ID", value: \.excavatorSegmentId) { row in
                    Text(row.excavatorSegmentId)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                }
                .width(min: 145, ideal: 190)

                TableColumn("Start (s)", value: \.startS) { row in
                    Text(String(format: "%.2f", row.startS))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text2)
                }
                .width(min: 65, ideal: 80)

                TableColumn("Dump (s)", value: \.dumpS) { row in
                    Text(String(format: "%.2f", row.dumpS))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text2)
                }
                .width(min: 65, ideal: 80)

                TableColumn("End (s)", value: \.endS) { row in
                    Text(String(format: "%.2f", row.endS))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text2)
                }
                .width(min: 65, ideal: 80)

                TableColumn("Duration", value: \.durationS) { row in
                    Text(OviusFormat.duration(seconds: row.durationS))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text)
                }
                .width(min: 70, ideal: 85)

                TableColumn("Inter-Scoop Gap", value: \.interScoopGapSortKey) { row in
                    Text(OviusFormat.duration(seconds: row.interScoopGapS))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Tokens.text2)
                }
                .width(min: 80, ideal: 95)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: OviusDesign.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: OviusDesign.Radius.card, style: .continuous)
                    .strokeBorder(Tokens.border.opacity(0.65), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { refreshSortedRows() }
        .onChange(of: rows) { _, _ in refreshSortedRows() }
        .onChange(of: sortOrder) { _, _ in refreshSortedRows() }
    }
}
