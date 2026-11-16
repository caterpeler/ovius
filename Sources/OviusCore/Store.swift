import Foundation

/// The library's records, kept in its database: sites, their clusters and cameras, pipelines, batches (a cluster's
/// cameras analysed together) and each camera's analysis.
public final class Store {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// Everything, read at once.
    public struct Contents {
        public var sites: [Site] = []
        public var clusters: [Cluster] = []
        public var cameras: [Camera] = []
        /// The newest first.
        public var pipelines: [Pipeline] = []
        public var batches: [Batch] = []
        public var analyses: [Analysis] = []
        public var settings = Settings()

        public init() {}
    }

    public func read() throws -> Contents {
        var c = Contents()
        c.sites = try db.query("SELECT id, name FROM sites ORDER BY name COLLATE NOCASE").map(Site.init(row:))
        c.clusters = try db.query("SELECT id, site_id, name FROM clusters ORDER BY name COLLATE NOCASE").map(Cluster.init(row:))
        c.cameras = try db.query("SELECT id, cluster_id, name FROM cameras ORDER BY name COLLATE NOCASE").map(Camera.init(row:))
        c.pipelines = try db.query("SELECT * FROM pipelines ORDER BY imported_at DESC").map(Pipeline.init(row:))
        c.batches = try db.query("SELECT * FROM batches ORDER BY id DESC").map(Batch.init(row:))
        c.analyses = try db.query("SELECT * FROM analyses ORDER BY id").map(Analysis.init(row:))
        if let text = try db.query("SELECT value FROM settings WHERE key = 'settings'").first?.string("value") {
            c.settings = (try? JSONDecoder().decode(Settings.self, from: Data(text.utf8))) ?? Settings()
        }
        return c
    }

    public func save(_ settings: Settings) throws {
        let text = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        try db.run("INSERT INTO settings (key, value) VALUES ('settings', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", text)
    }

    // MARK: Places

    /// The cluster of that name at that site, made (and the site) if new.
    public func cluster(site siteName: String, name: String) throws -> Cluster {
        let siteName = siteName.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !siteName.isEmpty, !name.isEmpty else { throw OviusError(message: "A cluster needs a site and a name.") }
        let site = try db.query("SELECT id FROM sites WHERE name = ?", siteName).first?.int("id")
            ?? db.run("INSERT INTO sites (name) VALUES (?)", siteName)
        let id = try db.query("SELECT id FROM clusters WHERE site_id = ? AND name = ?", site, name).first?.int("id")
            ?? db.run("INSERT INTO clusters (site_id, name) VALUES (?, ?)", site, name)
        return try Cluster(row: only(db.query("SELECT * FROM clusters WHERE id = ?", id)))
    }

    /// The cluster of that name, whatever its site (the app no longer shows sites); made if new, at the library's
    /// first site.
    public func cluster(named name: String) throws -> Cluster {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw OviusError(message: "A cluster needs a name.") }
        if let id = try db.query("SELECT id FROM clusters WHERE name = ? COLLATE NOCASE ORDER BY id LIMIT 1", name).first?.int("id") {
            return try Cluster(row: only(db.query("SELECT * FROM clusters WHERE id = ?", id)))
        }
        let site = try db.query("SELECT name FROM sites ORDER BY id LIMIT 1").first?.string("name") ?? "Site"
        return try cluster(site: site, name: name)
    }

    /// Renames a cluster: no two clusters share a name.
    public func rename(cluster: Cluster, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw OviusError(message: "A cluster needs a name.") }
        if try !db.query("SELECT 1 FROM clusters WHERE name = ? COLLATE NOCASE AND id <> ?", name, cluster.id).isEmpty {
            throw OviusError(message: "There is already a cluster called \(name).")
        }
        try db.run("UPDATE clusters SET name = ? WHERE id = ?", name, cluster.id)
    }

    /// The camera of that name in the cluster, made if new.
    public func camera(cluster: Int64, name: String) throws -> Camera {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw OviusError(message: "A camera needs a name.") }
        let id = try db.query("SELECT id FROM cameras WHERE cluster_id = ? AND name = ?", cluster, name).first?.int("id")
            ?? db.run("INSERT INTO cameras (cluster_id, name) VALUES (?, ?)", cluster, name)
        return try Camera(row: only(db.query("SELECT * FROM cameras WHERE id = ?", id)))
    }

    /// Renames a cluster, or moves it to another site (made if new).
    public func rename(cluster: Cluster, site siteName: String, name: String) throws {
        let siteName = siteName.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !siteName.isEmpty, !name.isEmpty else { throw OviusError(message: "A cluster needs a site and a name.") }
        try db.transaction {
            let site = try db.query("SELECT id FROM sites WHERE name = ?", siteName).first?.int("id")
                ?? db.run("INSERT INTO sites (name) VALUES (?)", siteName)
            if try !db.query("SELECT 1 FROM clusters WHERE site_id = ? AND name = ? AND id <> ?", site, name, cluster.id).isEmpty {
                throw OviusError(message: "\(siteName) already has a cluster called \(name).")
            }
            try db.run("UPDATE clusters SET site_id = ?, name = ? WHERE id = ?", site, name, cluster.id)
            try dropEmpty()
        }
    }

    public func rename(camera: Camera, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw OviusError(message: "A camera needs a name.") }
        if try !db.query("SELECT 1 FROM cameras WHERE cluster_id = ? AND name = ? AND id <> ?", camera.clusterID, name, camera.id).isEmpty {
            throw OviusError(message: "The cluster already has a camera called \(name).")
        }
        try db.run("UPDATE cameras SET name = ? WHERE id = ?", name, camera.id)
    }

    public func delete(camera: Camera) throws {
        guard try db.query("SELECT 1 FROM analyses WHERE camera_id = ?", camera.id).isEmpty else {
            throw OviusError(message: "\(camera.name) has analyses: delete them first.")
        }
        try db.transaction {
            try db.run("DELETE FROM cameras WHERE id = ?", camera.id)
            try dropEmpty()
        }
    }

    public func delete(cluster: Cluster) throws {
        guard try db.query("SELECT 1 FROM batches WHERE cluster_id = ?", cluster.id).isEmpty else {
            throw OviusError(message: "\(cluster.name) has analyses: delete them first.")
        }
        try db.transaction {
            try db.run("DELETE FROM cameras WHERE cluster_id = ?", cluster.id)
            try db.run("DELETE FROM clusters WHERE id = ?", cluster.id)
            try dropEmpty()
        }
    }

    /// Sites left without clusters. (A cluster without cameras is kept: it is made before its first footage.)
    private func dropEmpty() throws {
        try db.run("DELETE FROM sites WHERE id NOT IN (SELECT site_id FROM clusters)")
    }

    // MARK: Pipelines

    public func addPipeline(name: String, nodes: [String], reportFile: String, eventsFile: String) throws -> Int64 {
        try db.run("INSERT INTO pipelines (name, nodes, report_file, events_file, imported_at) VALUES (?, ?, ?, ?, ?)",
                   name, String(decoding: try JSONEncoder().encode(nodes), as: UTF8.self), reportFile, eventsFile, Date())
    }

    public func delete(pipeline: Int64) throws {
        guard try db.query("SELECT 1 FROM batches WHERE pipeline_id = ?", pipeline).isEmpty else {
            throw OviusError(message: "The pipeline has analyses: delete them first.")
        }
        try db.run("DELETE FROM pipelines WHERE id = ?", pipeline)
    }

    // MARK: Batches

    /// One camera's video in a new batch.
    public struct NewVideo {
        public var camera: Int64
        public var videoName: String
        /// The camera's clock at the first frame.
        public var start: String?

        public init(camera: Int64, videoName: String, start: String?) {
            self.camera = camera
            self.videoName = videoName
            self.start = start
        }
    }

    /// A new batch of the cluster: an analysis for each video, in `status`. Its ID and its analyses', in order.
    public func addBatch(cluster: Int64, pipeline: Int64, videos: [NewVideo], status: Status) throws -> (batch: Int64, analyses: [Int64]) {
        guard !videos.isEmpty else { throw OviusError(message: "A batch needs at least one video.") }
        guard Set(videos.map(\.camera)).count == videos.count else {
            throw OviusError(message: "Each video needs a camera of its own: a batch has one video per camera.")
        }
        let cameras = try db.query("SELECT id FROM cameras WHERE cluster_id = ?", cluster).compactMap { $0.int("id") }
        guard videos.allSatisfy({ cameras.contains($0.camera) }) else { throw OviusError(message: "Every camera must be the cluster's.") }
        return try db.transaction {
            let now = Date()
            let batch = try db.run("INSERT INTO batches (cluster_id, pipeline_id, created_at) VALUES (?, ?, ?)", cluster, pipeline, now)
            let ids = try videos.map { v in
                try db.run("INSERT INTO analyses (batch_id, camera_id, pipeline_id, video_name, start, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                           batch, v.camera, pipeline, v.videoName, v.start, status.rawValue, now)
            }
            return (batch, ids)
        }
    }

    public func batch(_ id: Int64) throws -> Batch? {
        try db.query("SELECT * FROM batches WHERE id = ?", id).first.map(Batch.init(row:))
    }

    public func analyses(of batch: Int64) throws -> [Analysis] {
        try db.query("SELECT * FROM analyses WHERE batch_id = ? ORDER BY id", batch).map(Analysis.init(row:))
    }

    public func analysis(_ id: Int64) throws -> Analysis? {
        try db.query("SELECT * FROM analyses WHERE id = ?", id).first.map(Analysis.init(row:))
    }

    /// An analysis's status, and its figures when given.
    public func set(_ analysis: Int64, status: Status, error: String? = nil, metrics: Data? = nil) throws {
        let finished: Date? = status == .done || status == .failed ? Date() : nil
        if let metrics {
            try db.run("UPDATE analyses SET status = ?, error = ?, metrics = ?, finished_at = ? WHERE id = ?",
                       status.rawValue, error, String(decoding: metrics, as: UTF8.self), finished, analysis)
        } else {
            try db.run("UPDATE analyses SET status = ?, error = ?, finished_at = COALESCE(?, finished_at) WHERE id = ?",
                       status.rawValue, error, finished, analysis)
        }
    }

    public func setMetrics(of analysis: Int64, _ metrics: Data) throws {
        try db.run("UPDATE analyses SET metrics = ? WHERE id = ?", String(decoding: metrics, as: UTF8.self), analysis)
    }

    /// A batch's figures, or why they could not be worked out.
    public func setFigures(of batch: Int64, metrics: Data?, error: String?) throws {
        try db.run("UPDATE batches SET metrics = ?, error = ?, finished_at = ? WHERE id = ?",
                   metrics.map { String(decoding: $0, as: UTF8.self) }, error, Date(), batch)
    }

    public func delete(batch: Int64) throws {
        try db.transaction {
            try db.run("DELETE FROM analyses WHERE batch_id = ?", batch)
            try db.run("DELETE FROM batches WHERE id = ?", batch)
        }
    }

    // MARK: Opening the library

    /// Brings the library back to a steady state after the app closed: a run it closed on is queued again, a copy it
    /// closed on is lost.
    public func recover() throws {
        try db.run("UPDATE analyses SET status = 'queued' WHERE status = 'running'")
        try db.run("UPDATE analyses SET status = 'failed', error = 'The app closed while copying the video. Delete this and add the video again.' WHERE status = 'copying'")
    }
}

/// The one row a query just made or found.
private func only(_ rows: [Row]) throws -> Row {
    guard let row = rows.first else { throw OviusError(message: "A row went missing.") }
    return row
}
