import AppKit
import OviusCore
import Foundation
import Observation

/// A video picked for a cluster analysis: the camera it is from, and the camera's clock at its start (nil when
/// unknown).
struct NewVideo {
    var url: URL
    var camera: Camera
    var start: String?
}

/// A folder of results run elsewhere, as one camera of a cluster analysis.
struct ResultsImport {
    var folder: URL
    var camera: String
    var start: String?
    /// The video's name; the runner's folder name (video__pipeline) gives it when nil.
    var videoName: String?
}

/// Everything the windows show, kept in the library's database, and the queue that runs one analysis at a time.
@MainActor @Observable
final class AppModel {
    let library: Library
    @ObservationIgnored private var store: Store
    /// Whether queued analyses are run (not when the library is opened from the command line).
    @ObservationIgnored private let runsQueue: Bool

    private(set) var sites: [Site] = []
    private(set) var clusters: [Cluster] = []
    private(set) var cameras: [Camera] = []
    private(set) var pipelines: [Pipeline] = []
    /// The newest first.
    private(set) var batches: [Batch] = []
    /// Each camera's analysis, the oldest first.
    private(set) var analyses: [Analysis] = []
    private(set) var settings = Settings()
    /// The built-in pipeline's detector and state model, in the library.
    private(set) var detector: Detector?
    private(set) var stateModel: StateModel?
    /// What each running analysis is doing.
    private(set) var progress: [Int64: RunProgress] = [:]
    /// The last lines a running analysis printed.
    private(set) var liveLog: [Int64: [String]] = [:]
    private(set) var runningID: Int64?
    /// Batches whose cluster figures are being worked out.
    private(set) var figuring: Set<Int64> = []
    /// Python being set up from Settings, outside a run.
    private(set) var pythonSetup: RunProgress?
    private(set) var recalculating = false
    /// A model being copied into the library.
    private(set) var importingModel = false

    var alert: String?
    /// A batch to delete once the user confirms.
    var deleting: Batch?
    var showNewAnalysis = false
    var showImportResults = false

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var readers: [Int64: ProgressReader] = [:]
    @ObservationIgnored private var recalcTask: Task<Void, Never>?

    /// `runQueue` false opens the library without starting what is queued (to import from the command line).
    init(library: Library = .standard(), runQueue: Bool = true) {
        self.library = library
        runsQueue = runQueue
        do {
            try library.make()
            store = Store(try Database(path: library.database.path))
            try store.recover()
        } catch {
            store = Store(try! Database(path: ":memory:"))
            alert = "Could not open the library at \(library.root.path): \(error.localizedDescription)"
        }
        reload()
        if runQueue, !bringFiguresUpToDate() { pump() }
    }

    /// Works out the figures an older version worked out (or none were), before anything new runs; whether there
    /// were any.
    @discardableResult
    func bringFiguresUpToDate() -> Bool {
        guard analyses.contains(where: { $0.status == .done && $0.metrics == nil })
            || batches.contains(where: { $0.metrics == nil && $0.error == nil && Batch.ready(analyses(of: $0)) }) else { return false }
        recalculate(all: false)
        return true
    }

    // MARK: Reading

    func reload() {
        do {
            let c = try store.read()
            sites = c.sites
            clusters = c.clusters
            cameras = c.cameras
            pipelines = c.pipelines
            batches = c.batches
            analyses = c.analyses
            settings = c.settings
            detector = Models.detector(in: library)
            stateModel = Models.stateModel(in: library)
        } catch {
            alert = error.localizedDescription
        }
    }

    func site(_ id: Int64) -> Site? { sites.first { $0.id == id } }
    func cluster(_ id: Int64) -> Cluster? { clusters.first { $0.id == id } }
    func camera(_ id: Int64) -> Camera? { cameras.first { $0.id == id } }
    func pipeline(_ id: Int64) -> Pipeline? { pipelines.first { $0.id == id } }
    func batch(_ id: Int64) -> Batch? { batches.first { $0.id == id } }

    func analyses(of batch: Batch) -> [Analysis] { analyses.filter { $0.batchID == batch.id } }
    func state(of batch: Batch) -> Batch.State { figuring.contains(batch.id) ? .figuring : batch.state(of: analyses(of: batch)) }

    /// The cluster's name.
    func clusterTitle(_ id: Int64) -> String {
        cluster(id)?.name ?? "Unknown cluster"
    }

    func cameraName(_ id: Int64) -> String { camera(id)?.name ?? "Unknown camera" }

    /// The camera's clock at the batch's earliest start; nil when no video's is known.
    func start(of batch: Batch) -> String? { analyses(of: batch).compactMap(\.start).min() }

    func folder(of analysis: Analysis) -> URL { library.analysis(analysis.id) }

    /// Its copied video, or its folder for results imported without one.
    func revealable(_ analysis: Analysis) -> URL {
        let video = video(of: analysis)
        return FileManager.default.fileExists(atPath: video.path) ? video : folder(of: analysis)
    }
    func video(of analysis: Analysis) -> URL { library.analysis(analysis.id).appendingPathComponent(analysis.videoName) }

    /// The end of what an analysis's run printed.
    func log(of analysis: Analysis) -> String {
        if let live = liveLog[analysis.id] { return live.joined(separator: "\n") }
        let file = folder(of: analysis).appendingPathComponent("run.log")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// The cluster's earlier runs, however they were made, averaged by their hours.
    func comparison(for batch: Batch) -> Comparison? {
        Comparison.of(batches
            .filter { $0.id < batch.id && $0.clusterID == batch.clusterID }
            .compactMap { $0.metrics?.total })
    }

    /// The cluster's runs, the newest first, and the latest of them with figures.
    func runs(of cluster: Int64) -> [Batch] { batches.filter { $0.clusterID == cluster } }
    func latestFinished(of cluster: Int64) -> Batch? { runs(of: cluster).first { $0.metrics != nil } }

    var isBusy: Bool { runningID != nil || pythonSetup != nil || recalculating || importingModel }

    // MARK: Clusters and cameras

    /// The cluster of that name, made if new.
    func cluster(named name: String) throws -> Cluster {
        defer { reload() }
        return try store.cluster(named: name)
    }

    /// The cluster's camera of that name, made if new.
    func camera(in cluster: Cluster, name: String) throws -> Camera {
        defer { reload() }
        return try store.camera(cluster: cluster.id, name: name)
    }

    func rename(_ cluster: Cluster, name: String) {
        attempt { try store.rename(cluster: cluster, name: name) }
    }

    func rename(_ camera: Camera, name: String) {
        attempt { try store.rename(camera: camera, name: name) }
    }

    func delete(_ camera: Camera) {
        attempt { try store.delete(camera: camera) }
    }

    func delete(_ cluster: Cluster) {
        attempt { try store.delete(cluster: cluster) }
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            alert = error.localizedDescription
        }
        reload()
    }

    // MARK: The built-in pipeline

    /// What the built-in pipeline is called with the library's models; nil without a detector.
    var pipelineName: String? { detector.map { BuiltInPipeline.name(detector: $0, states: stateModel) } }

    /// Why new footage cannot be analysed now; nil when it can.
    var cannotAnalyse: String? {
        detector == nil ? "Choose the detector in Settings (⌘,) first: a model or pipeline bundle from the labeler." : nil
    }

    /// The library's record of the built-in pipeline as it is now, made the first time.
    private func builtInPipeline() throws -> Pipeline {
        guard let detector, let name = pipelineName else { throw OviusError(message: cannotAnalyse ?? "No detector.") }
        if let known = pipelines.first(where: { $0.name == name }) { return known }
        let id = try store.addPipeline(name: name, nodes: BuiltInPipeline.steps(states: stateModel), reportFile: "report.csv", eventsFile: "events.csv")
        reload()
        guard let made = pipeline(id) else { throw OviusError(message: "Could not keep the pipeline \(detector.name).") }
        return made
    }

    /// Why an analysis cannot be run (again) with the built-in pipeline; nil when it can. It runs with the models
    /// the library has when it starts.
    func cannotRun(_ analysis: Analysis) -> String? {
        cannotAnalyse
    }

    /// Why the models cannot be changed now; nil when they can.
    var cannotChangeModels: String? {
        runningID != nil ? "Wait for the running video to finish, or stop it, before changing a model." : nil
    }

    func importDetector(from url: URL) {
        changeModels { library in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try Models.importDetector(url, into: library)
        }
    }

    func importStateModel(from url: URL) {
        changeModels { library in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try Models.importStateModel(url, into: library)
        }
    }

    func removeStateModel() {
        changeModels { try Models.removeStateModel(from: $0) }
    }

    private func changeModels(_ body: @escaping @Sendable (Library) throws -> Void) {
        if let problem = cannotChangeModels {
            alert = problem
            return
        }
        importingModel = true
        let library = library
        Task {
            let result = await Task.detached {
                try body(library)
            }.result
            if case .failure(let error) = result { alert = error.localizedDescription }
            importingModel = false
            reload()
        }
    }

    // MARK: Cluster analyses

    /// A cluster analysis: each video copied into the library, one after another, then queued. Its ID.
    @discardableResult
    func add(cluster: Cluster, videos: [NewVideo]) -> Int64? {
        let made: (batch: Int64, analyses: [Int64])
        do {
            let pipeline = try builtInPipeline()
            made = try store.addBatch(cluster: cluster.id, pipeline: pipeline.id, videos: videos.map {
                Store.NewVideo(camera: $0.camera.id, videoName: $0.url.lastPathComponent, start: $0.start)
            }, status: .copying)
        } catch {
            alert = error.localizedDescription
            return nil
        }
        reload()
        let copies = zip(made.analyses, videos).map { id, video in
            (id, video.url, library.analysis(id).appendingPathComponent(video.url.lastPathComponent))
        }
        Task {
            for (id, from, to) in copies {
                let copied = await Task.detached {
                    let access = from.startAccessingSecurityScopedResource()
                    defer { if access { from.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: from, to: to)
                }.result
                switch copied {
                case .success: set(id, status: .queued)
                case .failure(let error): set(id, status: .failed, error: "Could not copy the video: \(error.localizedDescription)")
                }
                pump()
            }
        }
        return made.batch
    }

    func retry(_ analysis: Analysis) {
        guard analysis.status.isOver else { return }
        if let problem = cannotRun(analysis) {
            alert = problem
            return
        }
        guard FileManager.default.fileExists(atPath: video(of: analysis).path) else {
            alert = "The copied video is gone from the library; add it again."
            return
        }
        set(analysis.id, status: .queued)
        pump()
    }

    func cancel(_ analysis: Analysis) {
        if runningID == analysis.id {
            runTask?.cancel()
        } else if analysis.status == .queued {
            set(analysis.id, status: .cancelled)
        }
    }

    /// Stops every camera of the batch still to run.
    func cancel(_ batch: Batch) {
        for analysis in analyses(of: batch) { cancel(analysis) }
    }

    func delete(_ batch: Batch) {
        let mine = analyses(of: batch)
        if mine.contains(where: { $0.id == runningID }) { runTask?.cancel() }
        do {
            try store.delete(batch: batch.id)
            for analysis in mine { try? FileManager.default.removeItem(at: library.analysis(analysis.id)) }
            try? FileManager.default.removeItem(at: library.batch(batch.id))
        } catch {
            alert = error.localizedDescription
        }
        reload()
    }

    private func set(_ id: Int64, status: Status, error: String? = nil, metrics: Data? = nil) {
        do {
            try store.set(id, status: status, error: error, metrics: metrics)
        } catch {
            alert = error.localizedDescription
        }
        reload()
        if status.isOver, let done = analyses.first(where: { $0.id == id }).flatMap({ self.batch($0.batchID) }) { settle(done) }
    }

    /// Works out a batch's cluster figures once every camera of it is over.
    private func settle(_ batch: Batch) {
        guard !recalculating, !figuring.contains(batch.id), Batch.ready(analyses(of: batch)) else { return }
        figuring.insert(batch.id)
        Task {
            await figure(batch)
            figuring.remove(batch.id)
            reload()
        }
    }

    // MARK: The queue

    /// Starts the oldest queued analysis, if none is running.
    private func pump() {
        guard runsQueue, runTask == nil, pythonSetup == nil, !recalculating,
              let next = analyses.filter({ $0.status == .queued }).min(by: { $0.id < $1.id }) else { return }
        runningID = next.id
        runTask = Task {
            await run(next)
            runTask = nil
            runningID = nil
            pump()
        }
    }

    private func run(_ analysis: Analysis) async {
        let id = analysis.id
        guard let detector else {
            set(id, status: .failed, error: cannotAnalyse)
            return
        }
        let states = stateModel
        set(id, status: .running)
        progress[id] = RunProgress(stage: "Starting")
        readers[id] = ProgressReader()
        liveLog[id] = []
        defer {
            progress[id] = nil
            readers[id] = nil
            liveLog[id] = nil
        }
        do {
            let python = try await basePython { [weak self] stage, fraction in
                self?.progress[id] = RunProgress(stage: stage, fraction: fraction)
            }
            let folder = library.analysis(id)
            let out = folder.appendingPathComponent("out", isDirectory: true)
            let spec = folder.appendingPathComponent("pipeline.json")
            try JSONSerialization.data(withJSONObject: BuiltInPipeline.spec(detector: detector, states: states, settings: settings),
                                       options: [.prettyPrinted, .sortedKeys]).write(to: spec)
            let run = PipelineRun(
                runner: BuiltInPipeline.folder, pipeline: spec, requirements: try BuiltInPipeline.requirements(for: detector, in: library),
                video: video(of: analysis), out: out, start: analysis.start, device: settings.device, venv: library.venv, python: python,
                log: folder.appendingPathComponent("run.log")
            )
            try await run.run { [weak self] line in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(line, from: id) } }
            }
            try Task.checkCancellation()
            progress[id] = RunProgress(stage: "Working out the figures")
            let json = try await figures(of: analysis)
            set(id, status: .done, metrics: json)
        } catch is CancellationError {
            set(id, status: .cancelled)
        } catch {
            set(id, status: .failed, error: error.localizedDescription)
        }
    }

    private func heard(_ line: String, from id: Int64) {
        guard liveLog[id] != nil else { return }
        liveLog[id]!.append(line)
        if liveLog[id]!.count > 300 { liveLog[id]!.removeFirst(liveLog[id]!.count - 300) }
        if let now = readers[id]?.read(line) { progress[id] = now }
    }

    /// A Python for metrics.py, which needs Python alone: the packages', the one in Settings or the app's own, else
    /// the Mac's, so working figures out never waits on a download.
    func metricsPython() -> URL {
        let fm = FileManager.default
        let venv = library.venv.appendingPathComponent("bin/python")
        if fm.isExecutableFile(atPath: venv.path) { return venv }
        let custom = settings.customPython.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty, fm.isExecutableFile(atPath: custom) { return URL(fileURLWithPath: custom) }
        return library.setUpPython ?? URL(fileURLWithPath: "/usr/bin/python3")
    }

    /// metrics.py on what one camera's run wrote, with the settings as they are now.
    private func figures(of analysis: Analysis) async throws -> Data {
        let python = metricsPython()
        let settings = settings.forMetrics(start: analysis.start)
        let folder = library.analysis(analysis.id)
        return try await Task.detached {
            try MetricsRun.run(python: python, out: folder.appendingPathComponent("out"), settings: settings, folder: folder).json
        }.value
    }

    /// metrics.py --cluster on a batch's finished cameras: its figures, or why there are none, kept.
    private func figure(_ batch: Batch) async {
        let python = metricsPython()
        let settings = settings.forCluster()
        let library = library
        let cameras = analyses(of: batch).filter { $0.status == .done }.map { ClusterRun.Camera(name: cameraName($0.cameraID), analysis: $0.id) }
        let result = await Task.detached {
            try ClusterRun.run(python: python, library: library, batch: batch.id, cameras: cameras, settings: settings).json
        }.result
        do {
            switch result {
            case .success(let json): try store.setFigures(of: batch.id, metrics: json, error: nil)
            case .failure(let error): try store.setFigures(of: batch.id, metrics: nil, error: error.localizedDescription)
            }
        } catch {
            alert = error.localizedDescription
        }
    }

    // MARK: Results run elsewhere

    /// What runs imported from elsewhere are kept under.
    private static let importedResults = "Imported results"

    /// Imports what a pipeline wrote elsewhere (on the labeler, on another Mac), a folder per camera of the cluster
    /// (its report, its events and review.json), as one run without videos; then works out the cluster's figures. A
    /// folder whose figures cannot be worked out is kept as a failed camera; the run's ID.
    @discardableResult
    func importResults(_ items: [ResultsImport], cluster: Cluster) throws -> Int64 {
        guard !items.isEmpty else { throw OviusError(message: "Pick a folder of results for each camera.") }
        for item in items { _ = try ResultsFolder.read(item.folder) }
        let pipelineID = try pipelines.first { $0.name == Self.importedResults }?.id
            ?? store.addPipeline(name: Self.importedResults, nodes: [], reportFile: "report.csv", eventsFile: "events.csv")
        reload()
        let cams = try items.map { try store.camera(cluster: cluster.id, name: $0.camera) }
        let (batch, ids) = try store.addBatch(cluster: cluster.id, pipeline: pipelineID, videos: zip(items, cams).map { item, camera in
            Store.NewVideo(camera: camera.id, videoName: item.videoName ?? item.folder.lastPathComponent.components(separatedBy: "__").first ?? item.folder.lastPathComponent,
                           start: item.start)
        }, status: .running)
        var failed: [String] = []
        for (item, id) in zip(items, ids) {
            let here = library.analysis(id)
            do {
                let out = here.appendingPathComponent("out", isDirectory: true)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: item.folder, to: out.appendingPathComponent(item.folder.lastPathComponent))
                let json = try MetricsRun.run(python: metricsPython(), out: out, settings: settings.forMetrics(start: item.start),
                                              folder: here).json
                try store.set(id, status: .done, metrics: json)
            } catch {
                failed.append("\(item.folder.lastPathComponent): \(error.localizedDescription)")
                try store.set(id, status: .failed, error: error.localizedDescription)
            }
        }
        if failed.count == items.count {
            try store.delete(batch: batch)
            for id in ids { try? FileManager.default.removeItem(at: library.analysis(id)) }
            reload()
            throw OviusError(message: failed.joined(separator: "\n"))
        }
        reload()
        let done = analyses.filter { $0.batchID == batch && $0.status == .done }.map { ClusterRun.Camera(name: cameraName($0.cameraID), analysis: $0.id) }
        do {
            let json = try ClusterRun.run(python: metricsPython(), library: library, batch: batch, cameras: done, settings: settings.forCluster()).json
            try store.setFigures(of: batch, metrics: json, error: nil)
        } catch {
            try store.setFigures(of: batch, metrics: nil, error: error.localizedDescription)
        }
        reload()
        if !failed.isEmpty { alert = "Some folders could not be read:\n" + failed.joined(separator: "\n") }
        return batch
    }

    // MARK: Python

    /// The Python to make the packages' environment with: the one in Settings, else the app's own, set up now if
    /// it has none yet.
    private func basePython(progress: @escaping (String, Double?) -> Void) async throws -> URL {
        let custom = settings.customPython.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: custom) else {
                throw OviusError(message: "The Python in Settings (\(custom)) is not there.")
            }
            return URL(fileURLWithPath: custom)
        }
        if let python = library.setUpPython { return python }
        return try await PythonSetup.install(into: library) { stage, fraction in
            DispatchQueue.main.async { MainActor.assumeIsolated { progress(stage, fraction) } }
        }
    }

    var pythonDescription: String {
        let custom = settings.customPython.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        guard let python = library.setUpPython else { return "Not set up yet: the first analysis downloads it (about 20 MB)." }
        let version = (try? Data(contentsOf: library.python.appendingPathComponent("BUILD")))
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        return version.map { "\(python.path) (\($0))" } ?? python.path
    }

    /// Downloads the app's Python again, and with it the packages on the next run.
    func reinstallPython() {
        guard !isBusy else { return }
        pythonSetup = RunProgress(stage: "Starting")
        Task {
            do {
                _ = try await PythonSetup.install(into: library) { stage, fraction in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.pythonSetup = RunProgress(stage: stage, fraction: fraction) } }
                }
            } catch {
                alert = "Could not set up Python: \(error.localizedDescription)"
            }
            pythonSetup = nil
            pump()
        }
    }

    /// Removes the pipelines' packages; the next run installs them again.
    func reinstallPackages() {
        guard !isBusy else { return }
        do {
            if FileManager.default.fileExists(atPath: library.venv.path) { try FileManager.default.removeItem(at: library.venv) }
        } catch {
            alert = error.localizedDescription
        }
    }

    // MARK: Settings

    func apply(_ new: Settings) {
        guard new != settings else { return }
        let refigure = new.refigures(settings)
        do {
            try store.save(new)
            settings = new
        } catch {
            alert = error.localizedDescription
        }
        if refigure {
            recalcTask?.cancel()
            recalcTask = Task {
                // Once they stop changing.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                recalculate(all: true)
            }
        }
    }

    /// Works the figures out again with the settings: every finished camera's then every batch's, or (`all` false)
    /// only those missing (worked out by an older version). The queue waits meanwhile.
    private func recalculate(all: Bool) {
        recalcTask = Task {
            while recalculating || runTask != nil {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            recalculating = true
            var failed: [String] = []
            for analysis in analyses where analysis.status == .done && (all || analysis.metrics == nil) {
                guard !Task.isCancelled else { break }
                do {
                    try store.setMetrics(of: analysis.id, try await figures(of: analysis))
                } catch {
                    failed.append("\(analysis.videoName): \(error.localizedDescription)")
                }
            }
            reload()
            for batch in batches where Batch.ready(analyses(of: batch)) && (all || batch.metrics == nil) {
                guard !Task.isCancelled else { break }
                await figure(batch)
            }
            reload()
            recalculating = false
            if !failed.isEmpty { alert = "Could not work these figures out again:\n" + failed.joined(separator: "\n") }
            pump()
        }
    }

    // MARK: Finder

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
