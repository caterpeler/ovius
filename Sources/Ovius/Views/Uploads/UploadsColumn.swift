import SwiftUI
import UniformTypeIdentifiers

/// The Uploads list column: a place to drop or choose videos, then a card per video with its stage and progress.
struct UploadsColumn: View {
    @Bindable var state: UploadsState
    @State private var choosing = false
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Uploads")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                Spacer()
                Button { choosing = true } label: { Label("Add videos", systemImage: "plus") }
                    .buttonStyle(OvButtonStyle(.secondary, size: .small))
            }
            .padding(Ov.Space.l)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Ov.Space.s) {
                    dropArea
                    if let error = state.importError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Ov.negativeInk)
                    }
                    ForEach(state.videos) { video in
                        UploadVideoCard(video: video, isSelected: state.selected?.id == video.id)
                            .onTapGesture { state.selectedId = video.id }
                    }
                }
                .padding(.horizontal, Ov.Space.l)
                .padding(.bottom, Ov.Space.l)
            }

            footer
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await state.add(urls) } }
        }
    }

    private var dropArea: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up.doc")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(dropping ? Ov.sageInk : Ov.ink2)
            Text("Drop videos here").font(.system(size: 13, weight: .semibold))
            Text("Sent in small parts, so a dropped connection only resends what was lost.")
                .font(.system(size: 11.5))
                .foregroundStyle(Ov.ink2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Ov.Space.l)
        .padding(.horizontal, Ov.Space.m)
        .background(dropping ? Ov.sage : Ov.card.opacity(0.5), in: RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous)
            .strokeBorder(dropping ? Ov.sageStrong : Ov.ink3.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .contentShape(Rectangle())
        .onTapGesture { choosing = true }
        .dropDestination(for: URL.self) { urls, _ in
            let movies = urls.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie)) ?? false }
            guard !movies.isEmpty else { return false }
            Task { await state.add(movies) }
            return true
        } isTargeted: { dropping = $0 }
    }

    private var footer: some View {
        let parts = state.videos.reduce(0) { $0 + $1.parts.count }
        let bytes = state.videos.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return Text("\(state.videos.count) videos · \(parts) parts · \(bytes.formatted(.byteCount(style: .file)))")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(Ov.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Ov.Space.l)
            .padding(.vertical, Ov.Space.m)
    }
}

/// A video in the Uploads column: its file, camera, length and size, its stage, and how far along it is.
struct UploadVideoCard: View {
    let video: UploadVideo
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Ov.Space.s) {
                Image(systemName: "film")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ov.ink2)
                Text(video.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Ov.Space.s)
            }
            HStack(spacing: 6) {
                if let camera = video.cameraId {
                    FleetChip(text: camera, ink: Ov.sageInk, fill: isSelected ? Ov.card : Ov.sage)
                } else {
                    FleetChip(text: "No camera yet", ink: Ov.warningInk, fill: Ov.warningBg)
                }
                Text("\(FleetAnalysis.hm(video.durationS / 60)) · \(video.sizeBytes.formatted(.byteCount(style: .file)))")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Ov.ink2)
                    .lineLimit(1)
            }
            HStack {
                UploadStagePill(video: video)
                Spacer()
                Text("\(video.parts.count) part\(video.parts.count == 1 ? "" : "s")")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Ov.ink3)
            }
            switch video.stage {
            case .uploading, .failed:
                FleetMeter(fraction: video.uploadProgress, color: video.stage == .failed ? Ov.negativeInk : Ov.sageInk, height: 4)
            case .processing(let p):
                FleetMeter(fraction: p ?? 0, color: FleetPalette.queue, height: 4)
            default:
                EmptyView()
            }
        }
        .padding(Ov.Space.m)
        .background(isSelected ? Ov.sage : Ov.card, in: RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous)
            .strokeBorder(isSelected ? Ov.sageStrong : Ov.hairline, lineWidth: isSelected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}

/// A video's stage in a small tag.
struct UploadStagePill: View {
    let video: UploadVideo

    var body: some View {
        let (text, icon, ink, fill): (String, String, Color, Color) = switch video.stage {
        case .needsDetails: ("Needs details", "exclamationmark.circle.fill", Ov.warningInk, Ov.warningBg)
        case .ready: ("Ready to upload", "arrow.up.circle", Ov.ink2, Ov.sunken)
        case .uploading: ("Uploading \(Int((video.uploadProgress * 100).rounded()))%", "arrow.up.circle.fill", Ov.sageInk, Ov.sage)
        case .processing(let p): (p.map { "Processing \(Int(($0 * 100).rounded()))%" } ?? "Processing", "gearshape.2.fill", Ov.warningInk, Ov.warningBg)
        case .done: ("Ready to view", "checkmark.circle.fill", Ov.positiveInk, Ov.positiveBg)
        case .failed: ("Upload failed", "xmark.octagon.fill", Ov.negativeInk, Ov.negativeBg)
        }
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(fill, in: Capsule())
    }
}
