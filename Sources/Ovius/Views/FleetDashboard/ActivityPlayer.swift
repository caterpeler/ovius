import AVFoundation
import AVKit
import SwiftUI

/// An activity (one haul cycle) played from this Mac's copy of its video, with the machines' boxes drawn over it.
/// Only the recording's box tracks come from AWS (once per recording); the video is never downloaded.
struct ActivityPlayer: View {
    let cycle: FleetCycle
    var boxTracks: BoxTrackStore = .shared
    var store: LocalVideoStore = .shared

    private enum Video: Equatable {
        case looking
        case missing
        case ready(AVPlayer, size: CGSize)
    }

    private enum Boxes: Equatable {
        case loading
        case loaded(ActivityBoxes)
        case failed(String)
    }

    @State private var video: Video = .looking
    @State private var boxes: Boxes = .loading
    @State private var locating = false
    @State private var copying = false
    @State private var locateError: String?
    /// Where the video is, in seconds, reported by the player about 15 times a second and whenever it jumps. The
    /// overlay redraws from this value: drawing from the player's clock directly, SwiftUI has no reason to redraw.
    @State private var playhead: Double = 0
    @State private var clock: (player: AVPlayer, token: Any)?

    var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.s) {
            switch video {
            case .looking:
                placeholder { ProgressView().controlSize(.small) }
            case .missing:
                missing
            case .ready(let player, let size):
                VideoPlayer(player: player) {
                    BoxOverlay(now: playhead, videoSize: size, boxes: loadedBoxes, cycle: cycle)
                }
                .aspectRatio(size, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
                status
            }
        }
        .task(id: cycle.id) { await load() }
        .onDisappear { stopClock() }
        .fileImporter(isPresented: $locating, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { Task { await keep(url) } }
        }
    }

    private var loadedBoxes: ActivityBoxes? {
        if case .loaded(let b) = boxes { b } else { nil }
    }

    // MARK: Loading

    private func load() async {
        stopClock()
        video = .looking
        boxes = .loading
        guard let url = store.url(for: cycle.recordingId) else {
            video = .missing
            return
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let geometry = try? await track.load(.naturalSize, .preferredTransform) else {
            video = .missing
            locateError = "The copy on this Mac couldn't be read as a video."
            return
        }
        let shown = geometry.0.applying(geometry.1)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        play(player, window: cycleWindow)
        playhead = cycleWindow.lowerBound
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { time in
            if time.seconds.isFinite { playhead = time.seconds }
        }
        clock = (player, token)
        video = .ready(player, size: CGSize(width: abs(shown.width), height: abs(shown.height)))

        do {
            let fetched = try await boxTracks.boxes(recordingId: cycle.recordingId, window: cycleWindow)
            guard !Task.isCancelled else { return }
            boxes = .loaded(fetched)
        } catch {
            guard !Task.isCancelled else { return }
            boxes = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The cycle's span, arrival to departure (or the last moment known), with 5 seconds either side.
    private var cycleWindow: ClosedRange<Double> {
        max(0, cycle.offsetS - 5)...(cycle.offsetS + cycle.totalS + 5)
    }

    /// Starts at the activity's first moment, paused, and stops playing at its last.
    private func play(_ player: AVPlayer, window: ClosedRange<Double>) {
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: window.upperBound, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: window.lowerBound, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func stopClock() {
        if let clock { clock.player.removeTimeObserver(clock.token) }
        clock = nil
    }

    /// A video found by hand (one uploaded from another Mac, or before copies were kept) is kept like an upload's.
    private func keep(_ url: URL) async {
        copying = true
        locateError = nil
        defer { copying = false }
        do {
            try await store.store(url, recordingId: cycle.recordingId)
            await load()
        } catch {
            locateError = "Couldn't keep a copy of it: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: Pieces

    private var status: some View {
        HStack(spacing: Ov.Space.s) {
            switch boxes {
            case .loading:
                ProgressView().controlSize(.mini)
                Text("Getting this recording's boxes…")
            case .loaded(let b) where !b.isAvailable:
                Image(systemName: "square.dashed")
                Text("This recording has no box tracks, so only the video plays.")
            case .loaded(let b):
                legend
                Spacer()
                Text("\(FleetAnalysis.elapsed(b.window.lowerBound / 60)) – \(FleetAnalysis.elapsed(b.window.upperBound / 60)) of the recording")
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ov.warningInk)
                Text("Boxes couldn't be loaded: \(why)").lineLimit(2).help(why)
            }
        }
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(Ov.ink2)
    }

    private var legend: some View {
        HStack(spacing: Ov.Space.m) {
            swatch(BoxOverlay.truckColor, "Truck \(cycle.truck)")
            swatch(BoxOverlay.excavatorColor, "Excavator \(cycle.excavator)")
            swatch(BoxOverlay.otherColor, "Others")
        }
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 2).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private var missing: some View {
        placeholder {
            VStack(spacing: Ov.Space.s) {
                Image(systemName: "film").font(.system(size: 18)).foregroundStyle(Ov.ink3)
                Text("This recording's video isn't on this Mac").font(.system(size: 13, weight: .semibold))
                Text("Videos uploaded from here are kept automatically. For others, find the file: it's kept the same way, and nothing is downloaded from the cloud.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ov.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button { locating = true } label: {
                    if copying { ProgressView().controlSize(.small) } else { Label("Locate video…", systemImage: "folder") }
                }
                .buttonStyle(OvButtonStyle(.secondary, size: .small))
                .disabled(copying)
                if let locateError {
                    Text(locateError).font(.system(size: 11.5)).foregroundStyle(Ov.negativeInk)
                }
            }
            .padding(Ov.Space.l)
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(Ov.sunken, in: RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
    }
}

/// The boxes of the sampled frame nearest the playhead, scaled from the video's pixels to the view.
private struct BoxOverlay: View {
    static let truckColor = Color(red: 0.98, green: 0.74, blue: 0.18)
    static let excavatorColor = Color(red: 0.30, green: 0.78, blue: 0.95)
    static let otherColor = Color.white.opacity(0.55)

    /// The playhead, in seconds of the recording.
    let now: Double
    let videoSize: CGSize
    let boxes: ActivityBoxes?
    let cycle: FleetCycle

    var body: some View {
        Canvas { context, size in
            guard let boxes, videoSize.width > 0, videoSize.height > 0 else { return }
            let scale = CGAffineTransform(scaleX: size.width / videoSize.width, y: size.height / videoSize.height)
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            for box in boxes.boxes(at: now) {
                let rect = box.rect.applying(scale)
                let color = color(for: box)
                let style = StrokeStyle(lineWidth: color == Self.otherColor ? 1 : 2, dash: box.hidden ? [4, 3] : [])
                context.stroke(Path(rect), with: .color(color), style: style)
                if let label = box.machineLabel, color != Self.otherColor {
                    let text = context.resolve(Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.black))
                    let textSize = text.measure(in: size)
                    let tag = CGRect(x: rect.minX, y: max(0, rect.minY - textSize.height - 2),
                                     width: textSize.width + 6, height: textSize.height + 2)
                    context.fill(Path(tag), with: .color(color))
                    context.draw(text, at: CGPoint(x: tag.minX + 3, y: tag.minY + 1), anchor: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func color(for box: TrackedBox) -> Color {
        switch box.machineLabel {
        case cycle.truck: Self.truckColor
        case cycle.excavator: Self.excavatorColor
        default: Self.otherColor
        }
    }
}
