import AVFoundation
import AppKit
import Foundation
import Testing
@testable import Ovius

/// Draws an activity's boxes onto frames of the video kept on this Mac, scaled as the player scales them, to check
/// by eye that they line up. The boxes come the way the player gets them: the recording's box file downloaded from
/// the live API (into a temporary folder), read, and cut to the window.
///
///     OVIUS_FRAMES_OUT=dir OVIUS_RECORDING_ID=rec_… OVIUS_WINDOW=0-83 [OVIUS_TRUCK=T3 OVIUS_EXCAVATOR=E5] \
///         swift test --filter LiveActivityFrames
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OVIUS_FRAMES_OUT"] != nil))
struct LiveActivityFrames {
    @Test func drawBoxesOnKeptVideo() async throws {
        let env = ProcessInfo.processInfo.environment
        let recordingId = try #require(env["OVIUS_RECORDING_ID"])
        let bounds = try #require(env["OVIUS_WINDOW"]?.split(separator: "-").compactMap { Double($0) })
        try #require(bounds.count == 2)
        let tracks = BoxTrackStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("boxes-\(UUID().uuidString)"))
        let boxes = try await tracks.boxes(recordingId: recordingId, window: bounds[0]...bounds[1])
        try #require(boxes.isAvailable, "the recording has no box tracks")
        let video = try #require(LocalVideoStore.shared.url(for: recordingId))
        let out = URL(fileURLWithPath: try #require(env["OVIUS_FRAMES_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let truck = env["OVIUS_TRUCK"], excavator = env["OVIUS_EXCAVATOR"]

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        // Three moments of the activity, each at a sampled frame so the boxes belong to that exact frame.
        let picks = [0.2, 0.5, 0.8].compactMap { f -> Double? in
            guard !boxes.frames.isEmpty else { return nil }
            return boxes.frames[min(boxes.frames.count - 1, Int(Double(boxes.frames.count) * f))].t
        }
        for t in picks {
            let (cg, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
            let width = 1280, height = Int(Double(cg.height) * 1280 / Double(cg.width))
            let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            // The player's scaling: video pixels to view points. CoreGraphics' y runs up, so flip.
            let sx = Double(width) / Double(cg.width), sy = Double(height) / Double(cg.height)
            for box in boxes.boxes(at: t) {
                let r = box.rect
                let rect = CGRect(x: r.minX * sx, y: Double(height) - r.maxY * sy, width: r.width * sx, height: r.height * sy)
                let color: CGColor = switch box.machineLabel {
                case truck: CGColor(red: 0.98, green: 0.74, blue: 0.18, alpha: 1)
                case excavator: CGColor(red: 0.30, green: 0.78, blue: 0.95, alpha: 1)
                default: CGColor(gray: 1, alpha: 0.7)
                }
                ctx.setStrokeColor(color)
                ctx.setLineWidth(box.machineLabel == truck || box.machineLabel == excavator ? 3 : 1.5)
                ctx.setLineDash(phase: 0, lengths: box.hidden ? [6, 4] : [])
                ctx.stroke(rect)
            }
            let png = NSBitmapImageRep(cgImage: try #require(ctx.makeImage())).representation(using: .png, properties: [:])
            let file = out.appendingPathComponent(String(format: "frame_%07.2f.png", t))
            try png?.write(to: file)
            print("[frames] t=\(t) boxes=\(boxes.boxes(at: t).map { $0.machineLabel ?? $0.cls }) -> \(file.path)")
        }
    }
}
