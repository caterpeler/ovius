import AVFoundation
import Foundation
import Observation

// The upload page's data, and the upload itself: each video goes to the backend as one recording of one chunk (the
// worker joins chunks with `ffmpeg -c copy`, so a chunk must be a whole MP4, and cutting one here would mean copying
// the video), sent to S3 as a multipart upload. A part that fails is sent again on its own.

/// About an hour of a video: a run of its S3 parts, shown together.
struct UploadPart: Identifiable, Hashable {
    enum State: Hashable {
        case waiting
        case uploading(Double)
        case uploaded
        case failed(String)
    }

    let index: Int
    /// Where in the video it is, estimated from where its bytes are.
    let startS: Double
    let durationS: Double
    let byteOffset: Int64
    let sizeBytes: Int64
    /// Its S3 part numbers (from 1).
    let s3Parts: ClosedRange<Int>
    var state: State = .waiting

    var id: Int { index }
    var number: Int { index + 1 }
    var rangeLabel: String { "≈ \(FleetAnalysis.elapsed(startS / 60)) – \(FleetAnalysis.elapsed((startS + durationS) / 60))" }
    var progress: Double {
        switch state {
        case .waiting, .failed: 0
        case .uploading(let p): p
        case .uploaded: 1
        }
    }
}

/// The backend's side of a video being uploaded.
struct RemoteUpload: Hashable {
    let uploadId: String
    let recordingId: String
    /// The S3 multipart upload, once the first part has been signed.
    var s3UploadId: String?
    /// The parts S3 has, by part number.
    var eTags: [Int: String] = [:]
    /// Every part sent and the chunk completed: it's the worker's now.
    var uploaded = false
}

/// A video added for uploading: the file, where it's from, when it was recorded, and how far it has got.
struct UploadVideo: Identifiable, Hashable {
    enum Stage: Hashable {
        /// Waiting for a camera before it can go.
        case needsDetails
        case ready
        case uploading
        case processing(Double?)
        case done
        case failed
    }

    /// S3 part size: big enough that an 18 GB video is a few hundred parts, small enough to hold four in memory.
    static let preferredS3PartBytes: Int64 = 64 << 20

    let id: UUID
    /// `nil` for the sample videos, which can't be uploaded.
    let fileURL: URL?
    let fileName: String
    let sizeBytes: Int64
    let durationS: Double
    let resolution: String?
    let fps: Double?
    /// The date in the file's metadata, when it has one.
    let metadataDate: Date?
    let s3PartBytes: Int64

    var recordedAt: Date
    var clusterId: String?
    var sectionId: String?
    var cameraId: String?
    var locationTag: String = ""
    var tagsText: String = ""
    var parts: [UploadPart]
    var stage: Stage
    var remote: RemoteUpload?
    /// The backend's latest word on processing.
    var note: String?
    /// Why it stopped.
    var failure: String?
    /// It was uploaded but the worker failed it: trying again means uploading it again.
    var processingFailed = false

    var tags: [String] { tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var hasDetails: Bool { cameraId?.isEmpty == false }
    var uploadProgress: Double {
        let total = parts.reduce(0) { $0 + Double($1.sizeBytes) }
        return total > 0 ? parts.reduce(0) { $0 + Double($1.sizeBytes) * $1.progress } / total : 0
    }
    var hasFailedPart: Bool { parts.contains { if case .failed = $0.state { true } else { false } } }
    /// The backend has (or is getting) the camera, location, tags and date it was registered with, and has no way
    /// to change them, so they're fixed from the moment it's sent until it's cancelled or the worker fails it.
    var detailsLocked: Bool { (stage == .uploading || remote != nil) && !processingFailed }
    var s3PartCount: Int { parts.last?.s3Parts.upperBound ?? 0 }

    /// The byte range of S3 part `number`.
    func s3Range(_ number: Int) -> (offset: Int64, length: Int64) {
        let offset = Int64(number - 1) * s3PartBytes
        return (offset, min(s3PartBytes, sizeBytes - offset))
    }

    /// S3 allows 10,000 parts, so a very large file gets bigger ones.
    static func s3PartBytes(sizeBytes: Int64, preferred: Int64 = preferredS3PartBytes) -> Int64 {
        max(preferred, (sizeBytes + 9_999) / 10_000)
    }

    /// One part per hour of video (the last one shorter), each a whole number of S3 parts so that only the file's
    /// last S3 part is under S3's 5 MiB minimum.
    static func parts(durationS: Double, sizeBytes: Int64, s3PartBytes: Int64) -> [UploadPart] {
        let s3Count = max(1, Int((sizeBytes + s3PartBytes - 1) / s3PartBytes))
        let count = min(s3Count, max(1, Int((durationS / 3600).rounded(.up))))
        return (0..<count).map { i in
            let first = i * s3Count / count, end = (i + 1) * s3Count / count
            let offset = Int64(first) * s3PartBytes
            let size = min(Int64(end) * s3PartBytes, sizeBytes) - offset
            let share = sizeBytes > 0 ? durationS / Double(sizeBytes) : 0
            return UploadPart(index: i, startS: Double(offset) * share, durationS: Double(size) * share,
                              byteOffset: offset, sizeBytes: size, s3Parts: (first + 1)...end)
        }
    }
}

@MainActor @Observable
final class UploadsState {
    /// How often to check on the backend; shortened in tests.
    struct Timing: Sendable {
        var statusPoll: Duration = .seconds(5)
        var heartbeat: Duration = .seconds(30)
        /// The first retry's wait; each one after waits twice as long.
        var retryBase: Duration = .seconds(1)
    }

    var videos: [UploadVideo] = []
    var selectedId: UUID?
    var importError: String?

    @ObservationIgnored private let network: NetworkManager
    @ObservationIgnored private let videoStore: LocalVideoStore
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let preferredS3PartBytes: Int64
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Bytes sent so far of the S3 parts on their way, by video and part number.
    @ObservationIgnored private var inFlight: [UUID: [Int: Int64]] = [:]

    init(network: NetworkManager = .shared, videoStore: LocalVideoStore = .shared, timing: Timing = Timing(),
         preferredS3PartBytes: Int64 = UploadVideo.preferredS3PartBytes) {
        self.network = network
        self.videoStore = videoStore
        self.timing = timing
        self.preferredS3PartBytes = preferredS3PartBytes
    }

    var selected: UploadVideo? { videos.first { $0.id == selectedId } ?? videos.first }

    func binding(_ id: UUID) -> UploadVideo? { videos.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout UploadVideo) -> Void) {
        guard let i = videos.firstIndex(where: { $0.id == id }) else { return }
        change(&videos[i])
        if videos[i].stage == .needsDetails, videos[i].hasDetails { videos[i].stage = .ready }
        if videos[i].stage == .ready, !videos[i].hasDetails { videos[i].stage = .needsDetails }
    }

    func remove(_ id: UUID) {
        cancelUpload(id)
        videos.removeAll { $0.id == id }
        if selectedId == id { selectedId = videos.first?.id }
    }

    /// The sections a video lands in with its current details, by the same rule the dashboard uses.
    func sections(for video: UploadVideo, in clusters: [Cluster]) -> [(cluster: Cluster, section: Section)] {
        guard let camera = video.cameraId, !camera.isEmpty else { return [] }
        return clusters.flatMap { cluster in
            cluster.sections
                .filter { DatabaseManager.matches(cameraId: camera, locationTag: video.locationTag, filename: video.fileName,
                                                 tags: video.tags, section: $0) }
                .sorted { $0.sectionId < $1.sectionId }
                .map { (cluster, $0) }
        }
    }

    // MARK: Adding files

    /// Reads each file's length, size, resolution, frame rate and date, and adds it waiting for its details.
    func add(_ urls: [URL]) async {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration).seconds
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                var resolution: String?
                var fps: Double?
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let (natural, rate) = try await track.load(.naturalSize, .nominalFrameRate)
                    resolution = "\(Int(natural.width))×\(Int(natural.height))"
                    fps = Double(rate)
                }
                var date = try? await asset.load(.creationDate)?.load(.dateValue)
                if date == nil { date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate }
                guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                let partBytes = UploadVideo.s3PartBytes(sizeBytes: size, preferred: preferredS3PartBytes)
                let video = UploadVideo(id: UUID(), fileURL: url, fileName: url.lastPathComponent, sizeBytes: size,
                                        durationS: duration, resolution: resolution, fps: fps, metadataDate: date,
                                        s3PartBytes: partBytes, recordedAt: date ?? .now,
                                        parts: UploadVideo.parts(durationS: duration, sizeBytes: size, s3PartBytes: partBytes),
                                        stage: .needsDetails)
                videos.insert(video, at: 0)
                selectedId = video.id
            } catch {
                importError = "\(url.lastPathComponent) couldn't be read as a video."
            }
        }
    }

    // MARK: Uploading

    /// Starts the upload, or carries on with one that failed: only the parts S3 doesn't have are sent. A video the
    /// worker failed is uploaded again from the start.
    func startUpload(_ id: UUID) {
        guard let video = binding(id), video.hasDetails else { return }
        guard video.fileURL != nil else {
            update(id) { $0.stage = .failed; $0.failure = "This is a sample video, with no file to send." }
            return
        }
        // The worker failed that recording, so it has no results: its copy goes, and the new recording gets one.
        if video.processingFailed, let old = video.remote?.recordingId { videoStore.remove(recordingId: old) }
        update(id) { v in
            if v.processingFailed { Self.reset(&v) }
            v.stage = .uploading
            v.failure = nil
            v.note = nil
            for i in v.parts.indices where v.parts[i].state != .uploaded { v.parts[i].state = .waiting }
        }
        tasks[id]?.cancel()
        tasks[id] = Task { await run(id) }
    }

    /// Stops the upload and aborts it on the backend, which then can't be resumed: its parts start again next time,
    /// as a new recording, so the copy kept for this one goes too.
    func cancelUpload(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        inFlight[id] = nil
        guard let video = binding(id) else { return }
        if let remote = video.remote, !remote.uploaded {
            let network = network
            Task { try? await network.abortUploadRecording(recordingId: remote.recordingId, uploadId: remote.uploadId) }
            videoStore.remove(recordingId: remote.recordingId)
        }
        if video.stage == .uploading || video.stage == .failed {
            update(id) { v in
                Self.reset(&v)
                v.stage = v.hasDetails ? .ready : .needsDetails
            }
        }
    }

    private static func reset(_ v: inout UploadVideo) {
        v.remote = nil
        v.failure = nil
        v.note = nil
        v.processingFailed = false
        for i in v.parts.indices { v.parts[i].state = .waiting }
    }

    private func run(_ id: UUID) async {
        guard let url = binding(id)?.fileURL else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            if binding(id)?.remote?.uploaded != true {
                try await send(id, file: url)
            }
            try await followProcessing(id)
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            // The parts still on their way were stopped with the failed one; S3 keeps the ones it has.
            inFlight[id] = nil
            refreshParts(id)
            var message = Self.describe(error)
            if let failure = error as? PartFailure {
                message = Self.describe(failure.underlying)
                update(id) { v in
                    if let i = v.parts.firstIndex(where: { $0.s3Parts.contains(failure.partNumber) }) {
                        v.parts[i].state = .failed(message)
                    }
                }
            }
            update(id) { $0.stage = .failed; $0.failure = message }
        }
    }

    private struct PartFailure: Error {
        let partNumber: Int
        let underlying: Error
    }

    /// Keeps a copy of the video on this Mac (once), registers the recording (once), sends the parts S3 doesn't have
    /// yet, four at a time, then completes the chunk, which queues it for the GPU worker.
    private func send(_ id: UUID, file: URL) async throws {
        guard let video = binding(id) else { return }
        var remote: RemoteUpload
        if let existing = video.remote {
            remote = existing
            if videoStore.url(for: remote.recordingId) == nil {
                try await keepLocalCopy(id, file: file, recordingId: remote.recordingId)
            }
        } else {
            let request = try Self.sessionRequest(for: video)
            let recordingId = request.recordings[0].recordingId
            // Before anything is registered: a video uploaded but not kept here couldn't be played.
            try await keepLocalCopy(id, file: file, recordingId: recordingId)
            let created: UploadSessionCreated
            do {
                created = try await network.createUploadSession(request)
            } catch {
                videoStore.remove(recordingId: recordingId)
                throw error
            }
            remote = RemoteUpload(uploadId: created.uploadId, recordingId: recordingId)
            update(id) { $0.remote = remote }
        }

        let heartbeat = Task { await beat(id, uploadId: remote.uploadId, recordingId: remote.recordingId) }
        defer { heartbeat.cancel() }

        var missing = (1...video.s3PartCount).filter { remote.eTags[$0] == nil }[...]
        // The first part starts the multipart upload; the rest are signed into it, in parallel.
        if remote.s3UploadId == nil, let first = missing.popFirst() {
            let sent = try await sendPart(id, first, of: video, remote: remote, file: file)
            remote.s3UploadId = sent.s3UploadId
            record(id, part: first, eTag: sent.eTag, s3UploadId: sent.s3UploadId)
        }
        let started = remote
        try await withThrowingTaskGroup(of: (Int, PartSent).self) { group in
            func addNext() {
                guard let number = missing.popFirst() else { return }
                group.addTask { (number, try await self.sendPart(id, number, of: video, remote: started, file: file)) }
            }
            for _ in 0..<4 { addNext() }
            while let (number, sent) = try await group.next() {
                record(id, part: number, eTag: sent.eTag, s3UploadId: sent.s3UploadId)
                addNext()
            }
        }

        guard let done = binding(id)?.remote, let s3UploadId = done.s3UploadId else { return }
        _ = try await network.completeChunk(CompleteChunkRequest(
            uploadId: done.uploadId, recordingId: done.recordingId, chunkIndex: 0, s3UploadId: s3UploadId,
            parts: done.eTags.sorted { $0.key < $1.key }.map { .init(partNumber: $0.key, eTag: $0.value) }
        ))
        update(id) { v in
            v.remote?.uploaded = true
            v.stage = .processing(nil)
            v.note = "Queued for processing."
        }
    }

    /// The copy the activity player plays, so it never downloads the video back from AWS.
    private func keepLocalCopy(_ id: UUID, file: URL, recordingId: String) async throws {
        update(id) { $0.note = "Keeping a copy on this Mac…" }
        do {
            try await videoStore.store(file, recordingId: recordingId)
        } catch {
            throw UploadProblem("Couldn't keep a copy of the video on this Mac (\(Self.describe(error))), so nothing was sent.")
        }
        if Task.isCancelled {
            videoStore.remove(recordingId: recordingId)
            throw CancellationError()
        }
        update(id) { $0.note = nil }
    }

    private struct PartSent: Sendable {
        let eTag: String
        let s3UploadId: String
    }

    /// Signs and sends one S3 part, trying again after network trouble, a server error or an expired signature.
    private func sendPart(_ id: UUID, _ number: Int, of video: UploadVideo, remote: RemoteUpload, file: URL) async throws -> PartSent {
        let (offset, length) = video.s3Range(number)
        let data: Data
        do {
            data = try await Self.read(file, offset: offset, length: length)
        } catch {
            throw PartFailure(partNumber: number, underlying: UploadProblem("The video file couldn't be read. Has it moved?"))
        }

        let network = network
        let progress = ProgressThrottle { [weak self] sent in
            Task { @MainActor in self?.progress(id, part: number, sent: sent) }
        }
        var attempt = 0
        while true {
            do {
                let signed = try await network.presignParts(PresignPartsRequest(
                    uploadId: remote.uploadId, recordingId: remote.recordingId, chunkIndex: 0,
                    partNumbers: [number], s3UploadId: remote.s3UploadId ?? binding(id)?.remote?.s3UploadId, expiresIn: nil
                ))
                guard let url = signed.presignedParts.first(where: { $0.partNumber == number })?.url else {
                    throw NetworkError.invalidResponse
                }
                let eTag = try await network.putPart(data, to: url) { progress.report($0, of: length) }
                return PartSent(eTag: eTag, s3UploadId: signed.s3UploadId)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                attempt += 1
                guard attempt < 4, Self.isWorthRetrying(error) else { throw PartFailure(partNumber: number, underlying: error) }
                progress.reset()
                inFlight[id]?[number] = 0
                try await Task.sleep(for: timing.retryBase * (1 << (attempt - 1)))
            }
        }
    }

    /// Off the main actor: a part is 64 MiB.
    private nonisolated static func read(_ file: URL, offset: Int64, length: Int64) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        guard data.count == Int(length) else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    private static func isWorthRetrying(_ error: Error) -> Bool {
        switch error {
        case is URLError:
            true
        case NetworkError.httpError(let status, _):
            // 403: the part's signature ran out (S3's clock or a slow link); it is signed again.
            status >= 500 || status == 403 || status == 408 || status == 429
        case NetworkError.upstreamError, NetworkError.invalidResponse:
            true
        default:
            false
        }
    }

    private func record(_ id: UUID, part number: Int, eTag: String, s3UploadId: String) {
        inFlight[id]?[number] = nil
        update(id) { v in
            v.remote?.s3UploadId = s3UploadId
            v.remote?.eTags[number] = eTag
        }
        refreshParts(id)
    }

    private func progress(_ id: UUID, part number: Int, sent: Int64) {
        guard tasks[id] != nil, binding(id)?.remote?.eTags[number] == nil else { return }
        inFlight[id, default: [:]][number] = sent
        refreshParts(id)
    }

    /// Each part's progress from what S3 has and what's on its way.
    private func refreshParts(_ id: UUID) {
        let sending = inFlight[id] ?? [:]
        update(id) { v in
            let eTags = v.remote?.eTags ?? [:]
            for i in v.parts.indices {
                let part = v.parts[i]
                if part.s3Parts.allSatisfy({ eTags[$0] != nil }) {
                    v.parts[i].state = .uploaded
                    continue
                }
                let sent = part.s3Parts.reduce(Int64(0)) { sum, n in
                    sum + (eTags[n] != nil ? v.s3Range(n).length : sending[n] ?? 0)
                }
                if sent > 0 {
                    v.parts[i].state = .uploading(min(0.999, Double(sent) / Double(max(1, part.sizeBytes))))
                } else if case .uploading = part.state {
                    v.parts[i].state = .waiting
                }
            }
        }
    }

    private func uploadedBytes(_ id: UUID) -> Int64 {
        guard let v = binding(id) else { return 0 }
        let done = (v.remote?.eTags.keys).map { $0.reduce(Int64(0)) { $0 + v.s3Range($1).length } } ?? 0
        return done + (inFlight[id] ?? [:]).values.reduce(0, +)
    }

    /// Tells the backend how far the upload has got and how fast it's going, every 30 seconds, so the GPU worker
    /// knows to wait for it. Missed beats don't matter.
    private func beat(_ id: UUID, uploadId: String, recordingId: String) async {
        var last = uploadedBytes(id)
        var smoothed: Double?
        let seconds = Double(timing.heartbeat.components.seconds) + Double(timing.heartbeat.components.attoseconds) / 1e18
        while !Task.isCancelled {
            try? await Task.sleep(for: timing.heartbeat)
            if Task.isCancelled { return }
            let now = uploadedBytes(id)
            let rate = Double(max(0, now - last)) / max(seconds, 0.001)
            smoothed = smoothed.map { 0.7 * $0 + 0.3 * rate } ?? rate
            last = now
            try? await network.sendUploadHeartbeat(uploadId: uploadId, UploadHeartbeatRequest(
                smoothedUploadBps: smoothed ?? 0, recordings: [.init(recordingId: recordingId, uploadedBytes: now)]
            ))
        }
    }

    // MARK: Processing

    /// Checks on the worker every few seconds until it has finished with the video, one way or the other.
    private func followProcessing(_ id: UUID) async throws {
        guard let remote = binding(id)?.remote else { return }
        while true {
            try Task.checkCancellation()
            do {
                let status = try await network.uploadSessionStatus(uploadId: remote.uploadId)
                if let rec = status.recordings.first(where: { $0.recordingId == remote.recordingId }) {
                    switch rec.processStatus {
                    case "COMPLETED":
                        update(id) { v in
                            v.stage = .done
                            v.note = rec.cyclesExtractedSoFar.map { "\($0) cycle\($0 == 1 ? "" : "s") found." }
                        }
                        return
                    case "FAILED", "ABORTED":
                        update(id) { v in
                            v.stage = .failed
                            v.processingFailed = true
                            v.note = nil
                            v.failure = rec.lastError ?? (rec.processStatus == "ABORTED"
                                ? "It was aborted on the server." : "The worker couldn't process it.")
                        }
                        return
                    case "PROCESSING_CHUNK", "PROCESSING":
                        update(id) { v in
                            v.stage = .processing(rec.activeChunkFrameProgressPct.map { min(1, max(0, $0 / 100)) })
                            v.note = rec.processStage
                        }
                    default:
                        let waking = ["stopped", "stopping", "pending"].contains(status.workerInstanceState ?? "")
                        update(id) { v in
                            v.stage = .processing(nil)
                            v.note = waking ? "Queued. The GPU worker is starting, which can take 10 minutes or so."
                                            : "Queued for processing."
                        }
                    }
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                update(id) { $0.note = "Couldn't reach the server to check on it (\(Self.describe(error))). Trying again." }
            }
            try await Task.sleep(for: timing.statusPoll)
        }
    }

    // MARK: Requests

    /// The session registering this video as one recording of one chunk.
    static func sessionRequest(for video: UploadVideo, recordingId: String = "rec_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()) throws -> UploadSessionRequest {
        guard let camera = video.cameraId?.trimmingCharacters(in: .whitespaces), !camera.isEmpty else {
            throw UploadProblem("Pick its camera first.")
        }
        guard camera.range(of: "^[A-Za-z0-9._-]{2,128}$", options: .regularExpression) != nil else {
            throw UploadProblem("The camera ID \"\(camera)\" can only use letters, digits, '.', '_' and '-'.")
        }
        guard let fps = video.fps, fps > 0 else {
            throw UploadProblem("Its frame rate couldn't be read from the file, and the backend needs it.")
        }
        let location = video.locationTag.trimmingCharacters(in: .whitespaces)
        return UploadSessionRequest(uploadId: nil, siteId: nil, recordings: [.init(
            recordingId: recordingId,
            cameraId: camera,
            locationTag: location.isEmpty ? nil : location,
            filename: video.fileName,
            tags: video.tags,
            timestamp: video.recordedAt.formatted(.iso8601),
            durationS: video.durationS,
            fps: fps,
            resolution: video.resolution?.replacingOccurrences(of: "×", with: "x"),
            chunks: [.init(chunkIndex: 0, startOffsetS: 0, durationS: video.durationS, byteSize: video.sizeBytes)]
        )])
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Sample

    /// One video at each stage, for reviewing the design.
    static func sample() -> UploadsState {
        let state = UploadsState()
        let day: (Int, Int) -> Date = { d, h in
            var c = DateComponents(); c.year = 2026; c.month = 11; c.day = d; c.hour = h; c.minute = 2
            return DashboardFilterState.utcCalendar.date(from: c) ?? .now
        }
        func video(_ name: String, hours: Double, gb: Double, date: Date, camera: String? = nil, cluster: String? = nil,
                   section: String? = nil, location: String = "", tags: String = "", stage: UploadVideo.Stage,
                   partStates: (Int) -> UploadPart.State = { _ in .waiting }) -> UploadVideo {
            let size = Int64(gb * 1_000_000_000)
            let partBytes = UploadVideo.s3PartBytes(sizeBytes: size)
            var parts = UploadVideo.parts(durationS: hours * 3600, sizeBytes: size, s3PartBytes: partBytes)
            for i in parts.indices { parts[i].state = partStates(i) }
            return UploadVideo(id: UUID(), fileURL: nil, fileName: name, sizeBytes: size, durationS: hours * 3600,
                               resolution: "1920×1080", fps: 30, metadataDate: date, s3PartBytes: partBytes, recordedAt: date,
                               clusterId: cluster, sectionId: section, cameraId: camera, locationTag: location, tagsText: tags,
                               parts: parts, stage: stage)
        }
        let main = DatabaseManager.defaultMainClusterId
        state.videos = [
            video("2026-11-18_alpha02_shift-A.mp4", hours: 12.25, gb: 18.3, date: day(18, 6), stage: .needsDetails),
            video("BETA-05_night_1117.mov", hours: 6.5, gb: 9.1, date: day(17, 18), camera: "CAM-BETA-05", cluster: main,
                  section: "SEC_BETA", location: "Section Beta - Panoramic 4-Pocket Bench", tags: "section:Beta", stage: .ready),
            video("gamma01_1117.mp4", hours: 3.1, gb: 4.2, date: day(17, 6), camera: "CAM-GAMMA-01", cluster: main,
                  section: "SEC_GAMMA", location: "Section Gamma - Dual-Truck Loading Pocket", tags: "section:Gamma", stage: .uploading,
                  partStates: { i in i == 0 ? .uploaded : (i == 1 ? .uploading(0.63) : .waiting) }),
            video("alpha01_1116.mp4", hours: 2, gb: 2.9, date: day(16, 6), camera: "CAM-ALPHA-01", cluster: main,
                  section: "SEC_ALPHA", location: "Section Alpha - Wide Overview Bench", tags: "section:Alpha", stage: .failed,
                  partStates: { i in i == 0 ? .uploaded : .failed("The connection dropped. Nothing was lost; retry sends this part again.") }),
            video("alpha03_1116.mp4", hours: 8, gb: 11.6, date: day(16, 6), camera: "CAM-ALPHA-03", cluster: main,
                  section: "SEC_ALPHA", location: "Section Alpha - Pit Floor Loading Pocket", tags: "section:Alpha",
                  stage: .processing(0.4), partStates: { _ in .uploaded }),
            video("beta01_1115.mp4", hours: 4.25, gb: 6.0, date: day(15, 6), camera: "CAM-BETA-01", cluster: main,
                  section: "SEC_BETA", location: "Section Beta - Highwall Haul Ramp Pocket", tags: "section:Beta",
                  stage: .done, partStates: { _ in .uploaded }),
        ]
        state.selectedId = state.videos[0].id
        return state
    }
}

/// Something about the video itself that stops it being sent.
struct UploadProblem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Passes on upload progress at most every MiB, so a 64 MiB part makes 64 updates rather than thousands.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported: Int64 = 0
    private let forward: @Sendable (Int64) -> Void

    init(_ forward: @escaping @Sendable (Int64) -> Void) {
        self.forward = forward
    }

    func report(_ sent: Int64, of total: Int64) {
        lock.lock()
        let due = sent - lastReported >= 1 << 20 || sent >= total
        if due { lastReported = sent }
        lock.unlock()
        if due { forward(sent) }
    }

    func reset() {
        lock.lock()
        lastReported = 0
        lock.unlock()
    }
}
