import Foundation
import Testing
@testable import Ovius

/// Payloads as the backend has actually returned them, decoded offline.
struct BackendPayloadDecodingTests {
    /// A segment the GPU worker wrote before it set `cycle_id: "NONE"` (live: `rec_e2e_82e05ea8`), and one without
    /// `confidence`, which the schema allows.
    @Test func segmentsWithoutCycleIdOrConfidenceDecode() throws {
        let json = """
        {"query_type":"segments","state_segments":[
          {"segment_id":"rec#EX-1#0","recording_id":"rec","machine_id":"EX-1","state":"idle","start_s":0,"end_s":18,"confidence":0.91},
          {"segment_id":"rec#DT-1#0","recording_id":"rec","cycle_id":"rec-T001","machine_id":"DT-1","state":"spotting","start_s":5,"end_s":9}
        ],"pagination":{"count":2,"next_token":null}}
        """
        let page = try JSONDecoder().decode(SegmentsPageResponse.self, from: Data(json.utf8))
        #expect(page.stateSegments.map(\.cycleId) == ["NONE", "rec-T001"])
        #expect(page.stateSegments.map(\.confidence) == [0.91, 1])
    }

    @Test func recordingWithoutLocationTagDecodes() throws {
        let json = """
        {"recording_id":"rec","camera_id":"CAM-1","filename":"a.mp4","timestamp":"2026-11-19T05:30:36Z",
         "duration_s":127,"fps":9.7,"resolution":"1920x1080","tags":[]}
        """
        let rec = try JSONDecoder().decode(RecordingDTO.self, from: Data(json.utf8))
        #expect(rec.locationTag == "")
        #expect(rec.startDate != nil)
    }
}

/// Calls the deployed backend (`OVIUS_API_BASE_URL`, else CloudFront) through the app's own `NetworkManager` and DTOs,
/// so a change on either side that breaks decoding shows up here. Off by default; run with
/// `OVIUS_LIVE_API=1 swift test --filter LiveBackendContractTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OVIUS_LIVE_API"] == "1"), .serialized)
struct LiveBackendContractTests {
    private let network = NetworkManager()

    /// Recordings the GPU worker wrote (not the seeded mocks); they carry the fields the worker leaves out.
    private func workerRecordings() async throws -> [RecordingDTO] {
        let all = try await network.fetchAllRecordings(filters: TelemetryQueryFilters(startTime: "2020-01-01", limit: 15_000))
        return all.filter { !$0.recordingId.hasPrefix("mock_sample") }
    }

    @Test func recordingsDecodeAndPaginate() async throws {
        let first = try await network.fetchRecordingsPage(filters: TelemetryQueryFilters(startTime: "2020-01-01", limit: 5))
        #expect(first.recordings.count == 5)
        let token = try #require(first.pagination.nextToken)

        let second = try await network.fetchRecordingsPage(filters: TelemetryQueryFilters(startTime: "2020-01-01", limit: 5, nextToken: token))
        #expect(Set(first.recordings.map(\.id)).isDisjoint(with: second.recordings.map(\.id)))

        let all = try await network.fetchAllRecordings(filters: TelemetryQueryFilters(startTime: "2020-01-01", limit: 15_000))
        #expect(all.count == first.pagination.totalMatchedRecordings)
        #expect(all.allSatisfy { $0.startDate != nil })
    }

    @Test func dashboardBundleDecodes() async throws {
        let page = try await network.fetchMetricsPage(filters: TelemetryQueryFilters(
            startTime: "2020-01-01", includeSegments: true, includeScoops: false, limit: 200
        ))
        #expect(!page.recordings.isEmpty)
        #expect(!page.haulCycles.isEmpty)
    }

    /// What the Dashboard does for each selected recording: every cycle and state segment, both paginated.
    @Test func everyWorkerRecordingLoadsItsCyclesAndSegments() async throws {
        let recordings = try await workerRecordings()
        #expect(!recordings.isEmpty)
        for rec in recordings {
            let loaded = try await network.fetchRecordingCyclesAndSegments(recordingId: rec.recordingId, durationS: rec.durationS)
            #expect(!loaded.truncated, "\(rec.recordingId)")
            for cycle in loaded.cycles {
                let bySegments = try await network.fetchAllSegments(filters: TelemetryQueryFilters(cycleId: cycle.cycleId))
                #expect(bySegments.allSatisfy { $0.cycleId == cycle.cycleId }, "\(cycle.cycleId)")
            }
        }
    }

    @Test func aSeededRecordingLoadsItsCyclesAndSegments() async throws {
        let page = try await network.fetchRecordingsPage(filters: TelemetryQueryFilters(startTime: "2020-01-01", limit: 1))
        let rec = try #require(page.recordings.first)
        let loaded = try await network.fetchRecordingCyclesAndSegments(recordingId: rec.recordingId, durationS: rec.durationS)
        #expect(!loaded.cycles.isEmpty)
        #expect(!loaded.segments.isEmpty)
    }

    @Test func videoAndBBoxManifestsDecode() async throws {
        for rec in try await workerRecordings() {
            let filters = TelemetryQueryFilters(recordingIds: [rec.recordingId])
            let videos = try await network.fetchVideosTemplate(filters: filters)
            let bboxes = try await network.fetchBBoxesTemplate(filters: filters)
            #expect(videos.items.map(\.recordingId) == [rec.recordingId])
            #expect(bboxes.items.map(\.recordingId) == [rec.recordingId])
        }
    }

    @Test func badFiltersComeBackAsBadRequest() async throws {
        do {
            _ = try await network.fetchRecordingsPage(filters: TelemetryQueryFilters(startTime: "not-a-date"))
            Issue.record("expected the backend to reject the date")
        } catch NetworkError.badRequest {
        } catch {
            Issue.record("expected .badRequest, got \(error)")
        }
    }
}
