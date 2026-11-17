import Foundation

/// Owns per-recording AWS telemetry caches, LZFSE disk-cache hydration, bounded concurrent fetching,
/// and off-actor precomputation of dashboard metrics and Explorer rows.
@MainActor
public final class TelemetryRepository {
    private let networkManager: NetworkManager
    private let diskCache: TelemetryDiskCache

    public var cachedClusterId: String?
    public var cachedDiscoveryTruncated: Bool = false
    public var cachedTelemetryTruncated: Bool = false

    private var cyclesByRec: [String: [HaulCycleDTO]] = [:]
    private var segmentsByRec: [String: [StateSegmentDTO]] = [:]
    private var contributionsByRec: [String: RecordingMetricsContribution] = [:]
    private var recordingRowsByRec: [String: RecordingExplorerRow] = [:]
    private var fetchedRecIds: Set<String> = []

    public var hasTruncatedData: Bool {
        cachedDiscoveryTruncated || cachedTelemetryTruncated
    }

    public init(
        networkManager: NetworkManager? = nil,
        diskCache: TelemetryDiskCache? = nil
    ) {
        self.networkManager = networkManager ?? .shared
        self.diskCache = diskCache ?? .shared
    }

    public func clearAll() {
        cyclesByRec = [:]
        segmentsByRec = [:]
        contributionsByRec = [:]
        recordingRowsByRec = [:]
        fetchedRecIds = []
        cachedTelemetryTruncated = false
        diskCache.clearAll()
    }

    public func resetForClusterSwitch() {
        cachedClusterId = nil
        recordingRowsByRec = [:]
    }

    public func invalidateRecordingRows() {
        recordingRowsByRec = [:]
    }

    public func cycles(for recordingId: String) -> [HaulCycleDTO] {
        cyclesByRec[recordingId] ?? []
    }

    public func segments(for recordingId: String) -> [StateSegmentDTO] {
        segmentsByRec[recordingId] ?? []
    }

    public func fetchClusterRecordings(
        filters: TelemetryQueryFilters
    ) async throws -> (items: [RecordingDTO], hitPageCap: Bool) {
        try await networkManager.fetchAllRecordingsWithStatus(filters: filters, maxPages: 5)
    }

    /// Loads missing cycle + state-segment payloads from disk cache first, then fetches remaining
    /// recordings from AWS in bounded waves of 8 concurrent requests.
    public func ensureLoaded(
        recordingIds: [String],
        recordingsById: [String: RecordingDTO],
        sectionMapByRecId: [String: (sectionId: String, sectionName: String)],
        bypassDiskCache: Bool = false,
        onProgress: (@MainActor (String?) -> Void)? = nil,
        onPartialUpdate: (@MainActor () -> Void)? = nil
    ) async throws {
        let missing = Array(Set(recordingIds)).filter { !fetchedRecIds.contains($0) }.sorted()
        guard !missing.isEmpty else { return }

        onProgress?(nil)
        defer { onProgress?(nil) }

        let nm = networkManager
        let dc = diskCache
        let cacheNamespace = dc.isEnabled ? await nm.currentConfiguration().primaryBaseURL.absoluteString : ""

        var networkMissing = missing
        if !bypassDiskCache && dc.isEnabled {
            let diskHits = await hydrateFromDisk(
                recordingIds: missing,
                recordingsById: recordingsById,
                sectionMapByRecId: sectionMapByRecId,
                cacheNamespace: cacheNamespace,
                diskCache: dc
            )
            guard !Task.isCancelled else { return }

            if !diskHits.isEmpty {
                var hitIds: Set<String> = []
                hitIds.reserveCapacity(diskHits.count)
                for hit in diskHits {
                    cyclesByRec[hit.recordingId] = hit.cycles
                    segmentsByRec[hit.recordingId] = hit.segments
                    contributionsByRec[hit.recordingId] = hit.contribution
                    if let row = hit.row {
                        recordingRowsByRec[hit.recordingId] = row
                    }
                    fetchedRecIds.insert(hit.recordingId)
                    hitIds.insert(hit.recordingId)
                }
                networkMissing = missing.filter { !hitIds.contains($0) }
                if !networkMissing.isEmpty {
                    onPartialUpdate?()
                }
            }
        }

        guard !networkMissing.isEmpty else { return }

        if networkMissing.count > 1 {
            onProgress?("0 / \(networkMissing.count) clips")
        }

        let durationsByRec = recordingsById.mapValues(\.durationS)
        let maxConcurrent = 8
        let waveCount = (networkMissing.count + maxConcurrent - 1) / maxConcurrent
        var loadedCount = 0

        for waveIdx in 0..<waveCount {
            let startIdx = waveIdx * maxConcurrent
            let endIdx = min(startIdx + maxConcurrent, networkMissing.count)
            let wave = Array(networkMissing[startIdx..<endIdx])
            guard !Task.isCancelled else { return }

            let results = try await fetchWave(
                wave: wave,
                durationsByRec: durationsByRec,
                recordingsById: recordingsById,
                sectionMapByRecId: sectionMapByRecId,
                cacheNamespace: cacheNamespace,
                networkManager: nm,
                diskCache: dc
            )
            guard !Task.isCancelled else { return }

            for res in results {
                cyclesByRec[res.recordingId] = res.cycles
                segmentsByRec[res.recordingId] = res.segments
                contributionsByRec[res.recordingId] = res.contribution
                if let row = res.row {
                    recordingRowsByRec[res.recordingId] = row
                }
                if res.truncated {
                    cachedTelemetryTruncated = true
                } else {
                    fetchedRecIds.insert(res.recordingId)
                }
            }
            loadedCount += results.count

            if networkMissing.count > 1 {
                onProgress?("\(loadedCount) / \(networkMissing.count) clips")
            }
            if waveIdx < waveCount - 1 {
                onPartialUpdate?()
            }
        }
    }

    public func makeSnapshotSync(
        for activeRecs: [RecordingDTO],
        progressive: Bool
    ) -> (summary: DashboardMetricsSummary, rows: [RecordingExplorerRow]) {
        let contributions = activeRecs.compactMap { contributionsByRec[$0.recordingId] }
        let summary = TelemetryMetricsCalculator.combineContributions(
            contributions,
            recordingCount: progressive ? contributions.count : activeRecs.count
        )
        let rows = activeRecs
            .compactMap { recordingRowsByRec[$0.recordingId] }
            .sorted { $0.startDate > $1.startDate }
        return (summary, rows)
    }

    public func buildSnapshot(
        for activeRecs: [RecordingDTO],
        sectionMapByRecId: [String: (sectionId: String, sectionName: String)]
    ) async -> (summary: DashboardMetricsSummary, rows: [RecordingExplorerRow]) {
        var missingWork: [(rec: RecordingDTO, needContrib: Bool, needRow: Bool, cycles: [HaulCycleDTO], segments: [StateSegmentDTO])] = []
        for rec in activeRecs {
            let id = rec.recordingId
            let needContrib = contributionsByRec[id] == nil
            let needRow = recordingRowsByRec[id] == nil
            if needContrib || needRow {
                missingWork.append((
                    rec: rec,
                    needContrib: needContrib,
                    needRow: needRow,
                    cycles: cyclesByRec[id] ?? [],
                    segments: segmentsByRec[id] ?? []
                ))
            }
        }

        if !missingWork.isEmpty {
            let backfilled = await Task.detached(priority: .userInitiated) { [missingWork, sectionMapByRecId] in
                var computedContribs: [String: RecordingMetricsContribution] = [:]
                var computedRows: [String: RecordingExplorerRow] = [:]
                for item in missingWork {
                    let recId = item.rec.recordingId
                    if item.needContrib {
                        computedContribs[recId] = TelemetryMetricsCalculator.computeRecordingContribution(
                            recordingId: recId,
                            cycles: item.cycles,
                            segments: item.segments
                        )
                    }
                    if item.needRow {
                        computedRows[recId] = DataExplorerBuilder.buildRecordingRow(
                            for: item.rec,
                            sectionInfo: sectionMapByRecId[recId],
                            cycles: item.cycles
                        )
                    }
                }
                return (computedContribs, computedRows)
            }.value
            guard !Task.isCancelled else {
                return makeSnapshotSync(for: activeRecs, progressive: false)
            }

            for (recId, contrib) in backfilled.0 {
                contributionsByRec[recId] = contrib
            }
            for (recId, row) in backfilled.1 {
                recordingRowsByRec[recId] = row
            }
        }

        return makeSnapshotSync(for: activeRecs, progressive: false)
    }

    internal func seedForTesting(
        clusterId: String?,
        recordingIds: [String],
        cyclesByRec: [String: [HaulCycleDTO]],
        segmentsByRec: [String: [StateSegmentDTO]]
    ) {
        self.cachedClusterId = clusterId
        self.cyclesByRec = cyclesByRec
        self.segmentsByRec = segmentsByRec
        self.contributionsByRec = [:]
        self.recordingRowsByRec = [:]
        self.fetchedRecIds = Set(recordingIds)
    }

    // MARK: - Private Disk & Network Helpers

    private struct DiskHydratedRec: Sendable {
        let recordingId: String
        let cycles: [HaulCycleDTO]
        let segments: [StateSegmentDTO]
        let contribution: RecordingMetricsContribution
        let row: RecordingExplorerRow?
    }

    private struct SingleRecResult: Sendable {
        let recordingId: String
        let cycles: [HaulCycleDTO]
        let segments: [StateSegmentDTO]
        let truncated: Bool
        let contribution: RecordingMetricsContribution
        let row: RecordingExplorerRow?
    }

    private func hydrateFromDisk(
        recordingIds: [String],
        recordingsById: [String: RecordingDTO],
        sectionMapByRecId: [String: (sectionId: String, sectionName: String)],
        cacheNamespace: String,
        diskCache: TelemetryDiskCache
    ) async -> [DiskHydratedRec] {
        await Task.detached(priority: .userInitiated) {
            var hits: [DiskHydratedRec] = []
            hits.reserveCapacity(recordingIds.count)
            for recId in recordingIds {
                if Task.isCancelled { break }
                guard let entry = diskCache.load(recordingId: recId, namespace: cacheNamespace) else { continue }
                let contrib = TelemetryMetricsCalculator.computeRecordingContribution(
                    recordingId: recId,
                    cycles: entry.cycles,
                    segments: entry.segments
                )
                let row = recordingsById[recId].map {
                    DataExplorerBuilder.buildRecordingRow(
                        for: $0,
                        sectionInfo: sectionMapByRecId[recId],
                        cycles: entry.cycles
                    )
                }
                hits.append(
                    DiskHydratedRec(
                        recordingId: recId,
                        cycles: entry.cycles,
                        segments: entry.segments,
                        contribution: contrib,
                        row: row
                    )
                )
            }
            return hits
        }.value
    }

    private func fetchWave(
        wave: [String],
        durationsByRec: [String: Double],
        recordingsById: [String: RecordingDTO],
        sectionMapByRecId: [String: (sectionId: String, sectionName: String)],
        cacheNamespace: String,
        networkManager: NetworkManager,
        diskCache: TelemetryDiskCache
    ) async throws -> [SingleRecResult] {
        try await withThrowingTaskGroup(of: SingleRecResult.self) { group in
            for recId in wave {
                let dur = max(43_200.0, durationsByRec[recId] ?? 43_200.0)
                let targetRec = recordingsById[recId]
                let secInfo = sectionMapByRecId[recId]
                group.addTask {
                    let fetched = try await networkManager.fetchRecordingCyclesAndSegments(
                        recordingId: recId,
                        durationS: dur,
                        maxPages: 12
                    )
                    if !fetched.truncated && diskCache.isEnabled {
                        diskCache.save(
                            recordingId: recId,
                            cycles: fetched.cycles,
                            segments: fetched.segments,
                            namespace: cacheNamespace
                        )
                    }
                    let contrib = TelemetryMetricsCalculator.computeRecordingContribution(
                        recordingId: recId,
                        cycles: fetched.cycles,
                        segments: fetched.segments
                    )
                    let row = targetRec.map {
                        DataExplorerBuilder.buildRecordingRow(
                            for: $0,
                            sectionInfo: secInfo,
                            cycles: fetched.cycles
                        )
                    }
                    return SingleRecResult(
                        recordingId: recId,
                        cycles: fetched.cycles,
                        segments: fetched.segments,
                        truncated: fetched.truncated,
                        contribution: contrib,
                        row: row
                    )
                }
            }

            var out: [SingleRecResult] = []
            out.reserveCapacity(wave.count)
            for try await item in group {
                out.append(item)
            }
            return out
        }
    }
}
