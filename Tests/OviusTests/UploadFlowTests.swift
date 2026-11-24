import Foundation
import Testing
@testable import Ovius

/// The Uploads page against a fake backend and S3: the requests it makes, in order, and what it shows.
@MainActor @Suite(.serialized)
struct UploadFlowTests {
    private let backend = FakeUploadBackend()
    private let videoStore = LocalVideoStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("videos-\(UUID().uuidString)"))

    private func makeState() -> UploadsState {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeUploadBackend.URLProtocolStub.self]
        FakeUploadBackend.current = backend
        let network = NetworkManager(
            session: URLSession(configuration: config),
            configuration: .init(primaryBaseURL: URL(string: "https://api.test/api/v1")!, fallbackBaseURL: nil)
        )
        return UploadsState(network: network, videoStore: videoStore,
                            timing: .init(statusPoll: .milliseconds(5), heartbeat: .seconds(60), retryBase: .milliseconds(1)),
                            preferredS3PartBytes: 4)
    }

    /// A 10-byte, two-hour video in 4-byte S3 parts: S3 parts 1–3, shown as two parts.
    private func addVideo(to state: UploadsState) throws -> UUID {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).mp4")
        try Data("0123456789".utf8).write(to: file)
        let video = UploadVideo(id: UUID(), fileURL: file, fileName: "alpha.mp4", sizeBytes: 10, durationS: 7200,
                                resolution: "1920×1080", fps: 25, metadataDate: nil, s3PartBytes: 4,
                                recordedAt: Date(timeIntervalSince1970: 1_795_000_000), cameraId: "CAM-ALPHA-01",
                                tagsText: "section:Alpha, shift:day",
                                parts: UploadVideo.parts(durationS: 7200, sizeBytes: 10, s3PartBytes: 4), stage: .ready)
        state.videos = [video]
        return video.id
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func partsAreWholeS3PartsAndCoverTheFile() {
        let size: Int64 = 18_300_000_000
        let partBytes = UploadVideo.s3PartBytes(sizeBytes: size)
        let parts = UploadVideo.parts(durationS: 12.25 * 3600, sizeBytes: size, s3PartBytes: partBytes)
        #expect(parts.count == 13)
        #expect(parts.reduce(0) { $0 + $1.sizeBytes } == size)
        for (a, b) in zip(parts, parts.dropFirst()) {
            #expect(a.byteOffset + a.sizeBytes == b.byteOffset)
            #expect(a.s3Parts.upperBound + 1 == b.s3Parts.lowerBound)
            #expect(a.sizeBytes == Int64(a.s3Parts.count) * partBytes)
        }
        // S3 allows 10,000 parts; a 1 TB file gets parts big enough to fit.
        #expect(UploadVideo.s3PartBytes(sizeBytes: 1 << 40) * 10_000 >= 1 << 40)
    }

    @Test func uploadsEveryPartThenFollowsProcessingToTheEnd() async throws {
        let state = makeState()
        let id = try addVideo(to: state)
        backend.statuses = [
            ("QUEUED", nil, nil),
            ("PROCESSING_CHUNK", 40, "Frame 225/411 | RTF 0.24x | ETA 14s"),
            ("COMPLETED", 100, nil),
        ]

        state.startUpload(id)
        try await waitUntil { state.binding(id)?.stage == .done }

        let session = try #require(backend.sessionBodies.first)
        let rec = try #require((session["recordings"] as? [[String: Any]])?.first)
        #expect(rec["camera_id"] as? String == "CAM-ALPHA-01")
        #expect(rec["location_tag"] == nil)
        #expect(rec["tags"] as? [String] == ["section:Alpha", "shift:day"])
        #expect(rec["resolution"] as? String == "1920x1080")
        #expect(rec["timestamp"] as? String == "2026-11-18T11:06:40Z")
        #expect((rec["chunks"] as? [[String: Any]])?.first?["byte_size"] as? Int == 10)

        #expect(backend.putBodies == [1: Data("0123".utf8), 2: Data("4567".utf8), 3: Data("89".utf8)])
        #expect(backend.completedParts == [[1, "\"etag-1\""], [2, "\"etag-2\""], [3, "\"etag-3\""]])
        #expect(backend.presignedWithS3UploadId.dropFirst().allSatisfy { $0 == "mpu-1" })
        let video = try #require(state.binding(id))
        #expect(video.parts.allSatisfy { $0.state == .uploaded })
        #expect(video.note == "7 cycles found.")
        #expect(video.detailsLocked, "the backend has its details; editing them here would change nothing")
        // Kept on this Mac under its recording ID, for playing its activities without downloading it.
        let kept = try #require(videoStore.url(for: rec["recording_id"] as? String ?? ""))
        #expect(try Data(contentsOf: kept) == Data("0123456789".utf8))
    }

    @Test func aFailedPartIsTheOnlyOneSentAgain() async throws {
        let state = makeState()
        let id = try addVideo(to: state)
        backend.failingPart = 2
        backend.statuses = [("COMPLETED", 100, nil)]

        state.startUpload(id)
        try await waitUntil { state.binding(id)?.stage == .failed }
        var video = try #require(state.binding(id))
        #expect(backend.putAttempts[2] == 4)
        #expect(video.failure == "HTTP 500: S3 InternalError")
        #expect(video.parts[0].state == .uploaded)
        #expect(video.parts[1].state == .failed("HTTP 500: S3 InternalError"))
        #expect(video.remote?.eTags.keys.sorted() == [1, 3])

        backend.failingPart = nil
        state.startUpload(id)
        try await waitUntil { state.binding(id)?.stage == .done }
        video = try #require(state.binding(id))
        #expect(backend.sessionBodies.count == 1)
        #expect(backend.putAttempts == [1: 1, 2: 5, 3: 1])
        #expect(video.parts.allSatisfy { $0.state == .uploaded })
    }

    @Test func cancellingAbortsTheRecordingAndStartsItsPartsAgain() async throws {
        let state = makeState()
        let id = try addVideo(to: state)
        backend.failingPart = 3

        state.startUpload(id)
        try await waitUntil { state.binding(id)?.stage == .failed }
        state.cancelUpload(id)
        try await waitUntil { !backend.abortedRecordings.isEmpty }

        let video = try #require(state.binding(id))
        #expect(backend.abortedRecordings == [backend.recordingIds.first])
        #expect(videoStore.stats().count == 0)
        #expect(video.stage == .ready)
        #expect(video.remote == nil)
        #expect(!video.detailsLocked)
        #expect(video.parts.allSatisfy { $0.state == .waiting })
    }

    @Test func aProcessingFailureIsShownAndUploadingAgainStartsANewRecording() async throws {
        let state = makeState()
        let id = try addVideo(to: state)
        backend.statuses = [("FAILED", nil, nil)]
        backend.lastError = "ffmpeg: moov atom not found"

        state.startUpload(id)
        try await waitUntil { state.binding(id)?.stage == .failed }
        let video = try #require(state.binding(id))
        #expect(video.processingFailed)
        #expect(video.failure == "ffmpeg: moov atom not found")
        #expect(!video.detailsLocked, "uploading again makes a new recording, so its details can change")

        backend.statuses = [("COMPLETED", 100, nil)]
        state.startUpload(id)
        try await waitUntil { state.binding(id)?.stage == .done }
        #expect(backend.recordingIds.count == 2)
        #expect(Set(backend.recordingIds).count == 2)
        #expect(videoStore.url(for: backend.recordingIds[0]) == nil)
        #expect(videoStore.url(for: backend.recordingIds[1]) != nil)
    }

    @Test func aCameraIdTheBackendWouldRejectStopsBeforeAnythingIsSent() async throws {
        let state = makeState()
        let id = try addVideo(to: state)
        state.update(id) { $0.cameraId = "CAM ALPHA/01" }

        state.startUpload(id)
        try await waitUntil { state.binding(id)?.stage == .failed }
        #expect(state.binding(id)?.failure?.contains("can only use letters") == true)
        #expect(state.binding(id)?.detailsLocked == false, "nothing was registered, so the camera can be fixed")
        #expect(backend.sessionBodies.isEmpty)
        #expect(videoStore.stats().count == 0)
    }

    @Test func aVideoThatCantBeKeptHereIsNotRegisteredOrSent() async throws {
        let state = makeState()
        let id = try addVideo(to: state)
        try FileManager.default.removeItem(at: try #require(state.binding(id)?.fileURL))

        state.startUpload(id)
        try await waitUntil { state.binding(id)?.stage == .failed }
        #expect(state.binding(id)?.failure?.contains("Couldn't keep a copy") == true)
        #expect(backend.sessionBodies.isEmpty)
        #expect(backend.putBodies.isEmpty)
    }
}

/// Answers `/uploads/*` like the backend and part `PUT`s like S3, recording what it was sent.
final class FakeUploadBackend: @unchecked Sendable {
    nonisolated(unsafe) static var current: FakeUploadBackend?

    private let lock = NSLock()
    private var _sessionBodies: [[String: Any]] = []
    private var _recordingIds: [String] = []
    private var _putBodies: [Int: Data] = [:]
    private var _putAttempts: [Int: Int] = [:]
    private var _presignedWithS3UploadId: [String?] = []
    private var _completedParts: [[AnyHashable]] = []
    private var _abortedRecordings: [String] = []
    private var _failingPart: Int?
    private var _statuses: [(String, Double?, String?)] = []
    private var _lastError: String?
    private var multipartCount = 0

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var sessionBodies: [[String: Any]] { locked { _sessionBodies } }
    var recordingIds: [String] { locked { _recordingIds } }
    var putBodies: [Int: Data] { locked { _putBodies } }
    var putAttempts: [Int: Int] { locked { _putAttempts } }
    var presignedWithS3UploadId: [String?] { locked { _presignedWithS3UploadId } }
    var completedParts: [[AnyHashable]] { locked { _completedParts } }
    var abortedRecordings: [String] { locked { _abortedRecordings } }
    var failingPart: Int? { get { locked { _failingPart } } set { locked { _failingPart = newValue } } }
    /// What each status poll answers, in turn (process_status, progress %, stage); the last one repeats.
    var statuses: [(String, Double?, String?)] { get { locked { _statuses } } set { locked { _statuses = newValue } } }
    var lastError: String? { get { locked { _lastError } } set { locked { _lastError = newValue } } }

    func respond(to request: URLRequest, body: Data) -> (Int, [String: String], Data) {
        let url = request.url!
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        func reply(_ status: Int, _ object: Any) -> (Int, [String: String], Data) {
            (status, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
        }

        if url.host == "s3.test" {
            let number = Int(url.query!.dropFirst("part=".count))!
            return locked {
                _putAttempts[number, default: 0] += 1
                if _failingPart == number {
                    return (500, [:], Data("<Error><Code>InternalError</Code></Error>".utf8))
                }
                _putBodies[number] = body
                return (200, ["ETag": "\"etag-\(number)\""], Data())
            }
        }

        let path = url.path.replacingOccurrences(of: "/api/v1/", with: "")
        return locked {
            switch (request.httpMethod ?? "GET", path) {
            case ("POST", "uploads/sessions"):
                _sessionBodies.append(json)
                let rec = (json["recordings"] as? [[String: Any]])?.first?["recording_id"] as? String ?? ""
                _recordingIds.append(rec)
                return reply(201, ["upload_id": "upl-\(_sessionBodies.count)", "site_id": "open_pit_mine_01", "session_status": "UPLOADING"])
            case ("POST", "uploads/chunks/presign"):
                let given = json["s3_upload_id"] as? String
                _presignedWithS3UploadId.append(given)
                if given == nil { multipartCount += 1 }
                let parts = (json["part_numbers"] as? [Int] ?? []).map { ["part_number": $0, "url": "https://s3.test/chunk?part=\($0)"] }
                return reply(200, ["s3_upload_id": given ?? "mpu-\(multipartCount)", "presigned_parts": parts])
            case ("POST", "uploads/chunks/complete"):
                _completedParts = (json["parts"] as? [[String: Any]] ?? []).map { [$0["PartNumber"] as! Int, $0["ETag"] as! String] }
                return reply(200, ["upload_status": "READY", "transitioned_to_ready": true])
            case ("POST", let p) where p.hasPrefix("uploads/recordings/"):
                _abortedRecordings.append(p.split(separator: "/")[2].description)
                return reply(200, ["upload_status": "ABORTED"])
            case ("GET", let p) where p.hasPrefix("uploads/sessions/"):
                let (status, pct, stage) = _statuses.count > 1 ? _statuses.removeFirst() : (_statuses.first ?? ("QUEUED", nil, nil))
                var rec: [String: Any] = ["recording_id": _recordingIds.last ?? "", "process_status": status, "cycles_extracted_so_far": 7]
                rec["active_chunk_frame_progress_pct"] = pct
                rec["process_stage"] = stage
                rec["last_error"] = status == "FAILED" ? _lastError : nil
                return reply(200, ["upload_id": p.split(separator: "/")[2].description, "session_status": "PROCESSING",
                                   "worker_instance_state": "running", "recordings": [rec]])
            default:
                return reply(404, ["error": "Not Found"])
            }
        }
    }

    final class URLProtocolStub: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    body.append(buffer, count: n)
                }
            }
            let (status, headers, data) = FakeUploadBackend.current!.respond(to: request, body: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
