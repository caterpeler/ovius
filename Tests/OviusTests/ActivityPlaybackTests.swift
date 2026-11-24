import Foundation
import Testing
@testable import Ovius

/// Videos kept on this Mac, and the box tracks that are all the app downloads for playing an activity.
@Suite(.serialized)
struct ActivityPlaybackTests {
    private func tempStore() -> LocalVideoStore {
        LocalVideoStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("videos-\(UUID().uuidString)"))
    }

    private func tempFile(_ name: String, _ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func storeKeepsOneVideoPerRecordingAndReplacesIt() async throws {
        let store = tempStore()
        #expect(store.url(for: "rec_a") == nil)

        let kept = try await store.store(try tempFile("Shift.MOV", "first"), recordingId: "rec_a")
        #expect(kept.lastPathComponent == "rec_a.mov")
        #expect(store.url(for: "rec_a") == kept)
        #expect(store.url(for: "rec") == nil)
        try await store.store(try tempFile("other.mp4", "x"), recordingId: "rec_a.2")
        #expect(store.url(for: "rec_a")?.lastPathComponent == "rec_a.mov")
        store.remove(recordingId: "rec_a.2")

        try await store.store(try tempFile("again.mp4", "second, longer"), recordingId: "rec_a")
        let replaced = try #require(store.url(for: "rec_a"))
        #expect(try String(contentsOf: replaced) == "second, longer")
        #expect(store.stats().count == 1)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: store.directory.path)).contains { $0.hasSuffix(".partial") })

        store.remove(recordingId: "rec_a")
        #expect(store.url(for: "rec_a") == nil)
        #expect(store.stats().count == 0)
    }

    @Test func aFileThatCantBeReadIsNotKept() async throws {
        let store = tempStore()
        await #expect(throws: (any Error).self) {
            try await store.store(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mp4"), recordingId: "rec_b")
        }
        #expect(store.url(for: "rec_b") == nil)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// Five rows like `rec_e2e_82e05ea8`'s: a missing confidence, track 5 used by both a truck and an excavator, a
    /// bulldozer, and a row with no time (skipped).
    private let table = ParquetTable(rowCount: 6, columns: [
        "t": .double([0, 0, 0, 0.33, 0.33, nil]),
        "id": .int64([2, 3, 5, 2, 5, 9]),
        "cls": .string(["dumptruck", "excavator", "excavator", "dumptruck", "bulldozer", "dumptruck"]),
        "conf": .double([0.93, 0.9, nil, 0.92, 0.6, 0.8]),
        "x1": .int64([1224, 1658, 1358, 1230, 10, 1]), "y1": .int64([782, 756, 615, 780, 10, 1]),
        "x2": .int64([1416, 1847, 1507, 1420, 50, 2]), "y2": .int64([869, 872, 688, 870, 40, 2]),
        "hidden": .bool([false, false, false, true, false, false]),
    ])

    @Test func boxesGroupByFrameAndFollowThePlayhead() throws {
        let boxes = try ActivityBoxes(table: table, window: 0...232)

        #expect(boxes.isAvailable)
        #expect(boxes.frames.map(\.t) == [0, 0.33])
        #expect(boxes.boxes(at: 0.2).map(\.machineLabel) == ["T2", "E3", "E5"])
        #expect(boxes.boxes(at: 0.2)[0].rect == CGRect(x: 1224, y: 782, width: 192, height: 87))
        #expect(boxes.boxes(at: 0.2)[2].confidence == nil)
        #expect(boxes.boxes(at: 0.5).map(\.machineLabel) == ["T2", "B5"])
        #expect(boxes.boxes(at: 0.5)[0].hidden)
        #expect(boxes.boxes(at: -1).isEmpty)
        #expect(boxes.boxes(at: 5).isEmpty, "the last sample is too old to stand for this moment")
        #expect(try ActivityBoxes(table: table, window: 0.1...1).frames.map(\.t) == [0.33])
    }

    /// `sample.mp4`'s real box file, cut to a 10-second window, as frames from its video showed it.
    @Test func theRealBoxFileCutToAnActivitysWindow() throws {
        let table = try ParquetReader.read(fixture("boxes_real.parquet"), columns: ActivityBoxes.columns)
        let boxes = try ActivityBoxes(table: table, window: 10...20)

        #expect(!boxes.frames.isEmpty)
        #expect(boxes.frames.allSatisfy { (10...20).contains($0.t) })
        #expect(boxes.boxes(at: 16.64).map(\.machineLabel) == ["T1", "T2", "T3", "T4", "E5"])
        let whole = try ActivityBoxes(table: table, window: 0...83)
        #expect(whole.frames.reduce(0) { $0 + $1.boxes.count } == 1548)
    }

    private func stubbedStore(directory: URL) -> BoxTrackStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubResponder.self]
        let network = NetworkManager(session: URLSession(configuration: config),
                                     configuration: .init(primaryBaseURL: URL(string: "https://api.test/api/v1")!, fallbackBaseURL: nil))
        return BoxTrackStore(network: network, directory: directory)
    }

    private func bboxesReply(_ recordingId: String, link: String?) -> Data {
        let url = link.map { "\"\($0)\"" } ?? "null"
        return Data("""
        {"query_type":"bboxes","status":"\(link == nil ? "template" : "ready")","items":[{"recording_id":"\(recordingId)",
         "bbox_artifact_uri":"s3://bucket/\(recordingId).parquet","presigned_url":\(url),"chunk_parquet_uris":[]}],
         "pagination":{"count":1,"next_token":null}}
        """.utf8)
    }

    @Test func aRecordingsBoxFileIsDownloadedOnceAndKept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boxes-\(UUID().uuidString)")
        StubResponder.requests = []
        StubResponder.replies = [bboxesReply("rec_s", link: "https://s3.test/rec_s.parquet?X-Amz-Expires=3600"),
                                 try fixture("boxes_real.parquet")]
        let store = stubbedStore(directory: directory)

        let first = try await store.boxes(recordingId: "rec_s", window: 10...20)
        let second = try await store.boxes(recordingId: "rec_s", window: 0...5)
        #expect(first.boxes(at: 16.64).count == 5)
        #expect(second.frames.allSatisfy { $0.t <= 5 })
        #expect(StubResponder.requests.map(\.path) == ["/api/v1/bboxes", "/rec_s.parquet"])
        #expect(StubResponder.requests[0].query == "recording_id=rec_s")

        // A new session reads the kept file without asking AWS again.
        let reopened = try await stubbedStore(directory: directory).boxes(recordingId: "rec_s", window: 10...20)
        #expect(reopened == first)
        #expect(StubResponder.requests.count == 2)
    }

    @Test func aRecordingWithoutBoxTracksPlaysWithoutBoxesAndADamagedFileIsFetchedAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boxes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("PAR1 not really".utf8).write(to: directory.appendingPathComponent("rec_d.parquet"))
        StubResponder.requests = []
        StubResponder.replies = [bboxesReply("mock_sample_1_d001", link: nil),
                                 bboxesReply("rec_d", link: "https://s3.test/rec_d.parquet"), try fixture("boxes_real.parquet")]
        let store = stubbedStore(directory: directory)

        let seeded = try await store.boxes(recordingId: "mock_sample_1_d001", window: 0...60)
        #expect(!seeded.isAvailable)
        #expect(try await store.boxes(recordingId: "mock_sample_1_d001", window: 0...60) == seeded)
        let repaired = try await store.boxes(recordingId: "rec_d", window: 0...83)
        #expect(repaired.isAvailable)
        #expect(StubResponder.requests.map(\.path) == ["/api/v1/bboxes", "/api/v1/bboxes", "/rec_d.parquet"])
    }
}

/// Answers each request with the next canned body.
final class StubResponder: URLProtocol {
    nonisolated(unsafe) static var replies: [Data] = []
    nonisolated(unsafe) static var requests: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append(request.url!)
        let body = Self.replies.isEmpty ? Data("{}".utf8) : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
