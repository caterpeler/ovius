import SwiftUI

/// Single recording entry rendered inside the recordings column with calm native hierarchy.
public struct RecordingSidebarRowView: View {
    public let recording: RecordingDTO

    public init(recording: RecordingDTO) {
        self.recording = recording
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OviusDesign.Spacing.tight - 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.cameraId)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(Tokens.primary.text)

                Spacer(minLength: OviusDesign.Spacing.compact)

                Text(OviusFormat.duration(seconds: recording.durationS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Tokens.text2)
            }

            Text(recording.filename)
                .font(.callout.weight(.medium))
                .foregroundStyle(Tokens.text)
                .lineLimit(1)

            Text(recording.locationTag)
                .font(.footnote)
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)

            if !recording.formattedTimestampLabel.isEmpty {
                Text(recording.formattedTimestampLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Tokens.text3)
            }
        }
        .padding(.vertical, OviusDesign.Spacing.tight - 1)
        .accessibilityElement(children: .combine)
    }
}
