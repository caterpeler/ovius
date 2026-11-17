import SwiftUI

/// Compact adaptive summary strip showing recording-level cycle metrics at the top of Layer 2.
public struct CycleSummaryStripView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public let recording: RecordingExplorerRow
    public let isLoadingDrilldown: Bool

    public init(recording: RecordingExplorerRow, isLoadingDrilldown: Bool) {
        self.recording = recording
        self.isLoadingDrilldown = isLoadingDrilldown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.compact) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 200 : 135), spacing: OviusDesign.Spacing.standard)],
                alignment: .leading,
                spacing: OviusDesign.Spacing.compact
            ) {
                statItem(title: "Camera / File", value: "\(recording.cameraId) • \(recording.filename)")
                statItem(title: "Complete / Total", value: "\(recording.completeCycleCount) / \(recording.totalCycleCount)")
                statItem(
                    title: "Mean Passes",
                    value: recording.avgPassesPerCycle > 0 ? OviusFormat.decimal(recording.avgPassesPerCycle) : "—"
                )
                statItem(title: "Mean Cycle", value: OviusFormat.duration(seconds: recording.avgTotalCycleS))
                statItem(title: "Mean Load", value: OviusFormat.duration(seconds: recording.avgLoadDurationS))
                statItem(title: "Fleet Active", value: "\(recording.excavatorCount) exc • \(recording.truckCount) trucks")
            }

            if isLoadingDrilldown {
                HStack(spacing: OviusDesign.Spacing.tight) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing scoops & segments…")
                        .font(.footnote)
                        .foregroundStyle(Tokens.text2)
                }
            }
        }
        .padding(OviusDesign.Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSurface(
            background: Tokens.surface,
            borderColor: Tokens.border.opacity(0.65),
            radius: OviusDesign.Radius.card
        )
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Tokens.text2)
            Text(value)
                .font(.footnote.monospacedDigit().weight(.semibold))
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
