import Foundation

/// The recordings' box tracks, for drawing an activity's boxes over the video kept on this Mac.
///
/// The backend has no route for one activity's boxes, so each recording's box-track file is downloaded once through
/// the pre-signed link `/bboxes` gives (tens of KB for a short clip, a few MB for a 12-hour shift), kept in Caches
/// (it never changes once a recording is visible, and can always be downloaded again), and the activity's rows are
/// picked out here. The video itself is never downloaded.
public actor BoxTrackStore {
    public static let shared = BoxTrackStore()

    private let network: NetworkManager
    public nonisolated let directory: URL
    /// Files already read, most recent last, so the next activity of the same recording opens at once. `nil` for a
    /// recording without box tracks.
    private var tables: [(recordingId: String, table: ParquetTable?)] = []
    private let keepInMemory = 3

    public init(network: NetworkManager = .shared, directory: URL? = nil) {
        self.network = network
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = caches.appendingPathComponent("ovius_box_tracks", isDirectory: true)
        }
    }

    /// The recording's boxes seen within `window`, or `.unavailable` when it has no box tracks (seeded recordings).
    public func boxes(recordingId: String, window: ClosedRange<Double>) async throws -> ActivityBoxes {
        guard let table = try await table(for: recordingId) else { return .unavailable(window: window) }
        return try ActivityBoxes(table: table, window: window)
    }

    public func clearAll() {
        tables = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func table(for recordingId: String) async throws -> ParquetTable? {
        if let i = tables.firstIndex(where: { $0.recordingId == recordingId }) {
            let hit = tables.remove(at: i)
            tables.append(hit)
            return hit.table
        }
        let file = directory.appendingPathComponent(recordingId.replacingOccurrences(of: "/", with: "_") + ".parquet")
        var table: ParquetTable?
        if let kept = try? Data(contentsOf: file), let read = try? await Self.read(kept) {
            table = read
        } else {
            // Not downloaded yet, or the kept copy is damaged: fetch a fresh link (they last an hour) and download it.
            try? FileManager.default.removeItem(at: file)
            if let data = try await download(recordingId) {
                table = try await Self.read(data)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
        }
        tables.append((recordingId, table))
        if tables.count > keepInMemory { tables.removeFirst(tables.count - keepInMemory) }
        return table
    }

    private func download(_ recordingId: String) async throws -> Data? {
        let page = try await network.fetchBBoxesTemplate(filters: TelemetryQueryFilters(recordingIds: [recordingId]))
        guard let link = page.items.first(where: { $0.recordingId == recordingId })?.presignedUrl,
              let url = URL(string: link) else { return nil }
        return try await network.downloadPresigned(url)
    }

    /// Off the actor: a 12-hour shift's file is about 800k rows.
    private nonisolated static func read(_ data: Data) async throws -> ParquetTable {
        try ParquetReader.read(data, columns: ActivityBoxes.columns)
    }
}
