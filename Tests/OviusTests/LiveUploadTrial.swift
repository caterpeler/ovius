import Foundation
import Testing
@testable import Ovius

/// Uploads a real video through the Uploads page's own code to the deployed backend and follows it until the GPU
/// worker is done, keeping the copy in the app's real video folder so its activities can be played afterwards.
/// This writes a recording to the production tables and wakes the GPU worker, so it only runs when asked:
///
///     OVIUS_LIVE_UPLOAD=/path/to/video.mp4 [OVIUS_LIVE_CAMERA=CAM-E2E-OVIUS] swift test --filter LiveUploadTrial
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["OVIUS_LIVE_UPLOAD"] != nil))
struct LiveUploadTrial {
    @Test(.timeLimit(.minutes(30))) func uploadAndProcess() async throws {
        let env = ProcessInfo.processInfo.environment
        let file = URL(fileURLWithPath: try #require(env["OVIUS_LIVE_UPLOAD"]))
        let state = UploadsState()

        await state.add([file])
        let id = try #require(state.videos.first?.id, "\(state.importError ?? "not added")")
        state.update(id) { v in
            v.cameraId = env["OVIUS_LIVE_CAMERA"] ?? "CAM-E2E-OVIUS"
            v.locationTag = "Ovius app trial"
            v.tagsText = "e2e-audit, ovius-app"
        }
        let added = try #require(state.binding(id))
        print("[trial] \(added.fileName): \(added.sizeBytes) bytes, \(added.durationS) s, \(added.resolution ?? "?"), \(added.fps ?? 0) fps, \(added.s3PartCount) S3 part(s)")

        state.startUpload(id)
        var last = ""
        let started = Date()
        while true {
            let v = try #require(state.binding(id))
            let line = "\(v.stage) | \(Int(v.uploadProgress * 100))% sent | \(v.note ?? "")"
            if line != last {
                print("[trial] +\(Int(Date().timeIntervalSince(started)))s \(line)")
                last = line
            }
            if v.stage == .done || v.stage == .failed { break }
            try await Task.sleep(for: .seconds(1))
        }

        let v = try #require(state.binding(id))
        let remote = try #require(v.remote)
        print("[trial] upload_id=\(remote.uploadId) recording_id=\(remote.recordingId)")
        print("[trial] kept at \(LocalVideoStore.shared.url(for: remote.recordingId)?.path ?? "nowhere")")
        #expect(v.stage == .done, "\(v.failure ?? "")")
        #expect(LocalVideoStore.shared.url(for: remote.recordingId) != nil)
    }
}
