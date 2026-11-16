import Foundation

/// What a run is doing, read from what it says.
public struct RunProgress: Equatable {
    public var stage: String
    /// How far through the video, 0…1; nil while the step has no measure.
    public var fraction: Double?

    public init(stage: String, fraction: Double? = nil) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Reads the lines run.sh and the runner print into a stage and how far along it is.
public struct ProgressReader {
    private var total: Double?

    public init() {}

    public mutating func read(_ line: String) -> RunProgress? {
        if line.hasPrefix("Making a Python environment") {
            return RunProgress(stage: "Making a Python environment")
        }
        if line.hasPrefix("Installing what it needs") {
            return RunProgress(stage: "Installing PyTorch and the rest (the first run only)")
        }
        // "Detect, Track: 1800 s of video, 1 frame in 6": the frame-by-frame pass starts.
        if let m = line.firstMatch(of: #/^.+: (\d+) s of video, 1 frame in \d+/#) {
            total = Double(m.1)
            return RunProgress(stage: "Watching the video", fraction: 0)
        }
        // "   600 s of video | 1200 frames | 14.2 frames/s"
        if let m = line.firstMatch(of: #/^\s*(\d+) s of video \|/#), let total, total > 0, let at = Double(m.1) {
            return RunProgress(stage: "Watching the video", fraction: min(1, at / total))
        }
        if line.hasPrefix("analysed ") {
            return RunProgress(stage: "Watching the video", fraction: 1)
        }
        if let m = line.firstMatch(of: #/^running (.+) \([^()]*\)$/#) {
            return RunProgress(stage: String(m.1))
        }
        if line.contains(": cached (") {
            return RunProgress(stage: "Reusing what an earlier run saw")
        }
        return nil
    }
}

/// One video through the built-in pipeline: run.sh with its pipeline.json, in the library's Python environment.
public struct PipelineRun {
    /// The folder holding run.sh and run_pipeline.py (BuiltInPipeline.folder).
    public var runner: URL
    public var pipeline: URL
    /// The packages to install; run.sh's own requirements.txt when nil.
    public var requirements: URL?
    public var video: URL
    /// Where the runner writes, a folder per video inside.
    public var out: URL
    public var start: String?
    public var device: String
    public var venv: URL
    public var python: URL
    public var log: URL

    public init(runner: URL, pipeline: URL, requirements: URL?, video: URL, out: URL, start: String?, device: String, venv: URL, python: URL, log: URL) {
        self.runner = runner
        self.pipeline = pipeline
        self.requirements = requirements
        self.video = video
        self.out = out
        self.start = start
        self.device = device
        self.venv = venv
        self.python = python
        self.log = log
    }

    /// Runs it, each line it prints given to `onLine` (and written to the log). Throws its last lines when it fails,
    /// and stops it when the task is cancelled.
    public func run(onLine: @escaping @Sendable (String) -> Void) async throws {
        var args = [runner.appendingPathComponent("run.sh").path, video.path, "--pipeline", pipeline.path, "--out", out.path, "--review", "--device", device]
        if let start { args += ["--start", start] }
        var env = ProcessInfo.processInfo.environment
        env["VIRTUAL_ENV"] = nil
        env["OVIUS_VENV"] = venv.path
        env["OVIUS_PYTHON"] = python.path
        env["OVIUS_REQUIREMENTS"] = requirements?.path
        env["PYTHONUNBUFFERED"] = "1"
        // Compiled code beside the environment, not inside the app.
        env["PYTHONPYCACHEPREFIX"] = venv.deletingLastPathComponent().appendingPathComponent("pycache").path
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin"
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await Command(executable: URL(fileURLWithPath: "/bin/bash"), args: args, environment: env, directory: out, log: log)
            .run(onLine: onLine)
    }
}

/// metrics.py on what a run wrote: what one camera saw.
public enum MetricsRun {
    /// Reads the outputs in `out` (the runner's folder inside it that holds the report) into `folder`/metrics.json,
    /// with `settings` (Settings.forMetrics) written beside it.
    public static func run(python: URL, out: URL, settings: [String: Any], folder: URL) throws -> (metrics: CameraMetrics, json: Data) {
        var settings = settings
        let reportFile = settings["report_file"] as? String ?? "report.csv"
        var written = outputFolder(in: out, holding: reportFile)
        // Results imported from a run that named its tables otherwise: found by their columns.
        if written == nil, let results = outputFolder(in: out, holding: "review.json"), let files = try? ResultsFolder.read(results) {
            written = results
            settings["report_file"] = files.reportFile
            settings["events_file"] = files.eventsFile
        }
        guard let written else {
            throw OviusError(message: "The pipeline wrote no \(reportFile).")
        }
        let settingsFile = folder.appendingPathComponent("settings.json")
        let metricsFile = folder.appendingPathComponent("metrics.json")
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsFile)
        try Tool.run(python, ["-I", Library.metricsScript.path, written.path, settingsFile.path, metricsFile.path])
        let data = try Data(contentsOf: metricsFile)
        return (try CameraMetrics.decode(data), data)
    }

    /// The newest folder in `out`, or `out` itself, that holds `file`.
    static func outputFolder(in out: URL, holding file: String) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: out.appendingPathComponent(file).path) { return out }
        let inside = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return inside
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(file).path) }
            .max { a, b in
                let da = (try? a.appendingPathComponent(file).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.appendingPathComponent(file).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
    }
}

/// metrics.py --cluster on a batch: its cameras' cycles completed and put together, the team's figures.
public enum ClusterRun {
    /// One finished camera of the batch: its name and its analysis, whose folder holds its metrics.json.
    public struct Camera {
        public var name: String
        public var analysis: Int64

        public init(name: String, analysis: Int64) {
            self.name = name
            self.analysis = analysis
        }
    }

    /// Writes the batch's figures to its folder's metrics.json, with what they were worked out from (cluster.json)
    /// beside it. Each camera's estimated cycles are drawn with its analysis's ID as the seed.
    public static func run(python: URL, library: Library, batch: Int64, cameras: [Camera], settings: [String: Any]) throws -> (metrics: ClusterMetrics, json: Data) {
        guard !cameras.isEmpty else { throw OviusError(message: "No camera of the batch finished.") }
        let folder = library.batch(batch)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input: [String: Any] = [
            "settings": settings,
            "cameras": cameras.map { c -> [String: Any] in
                ["name": c.name, "analysis": c.analysis, "seed": c.analysis,
                 "metrics": library.analysis(c.analysis).appendingPathComponent("metrics.json").path]
            },
        ]
        let inputFile = folder.appendingPathComponent("cluster.json")
        let metricsFile = folder.appendingPathComponent("metrics.json")
        try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]).write(to: inputFile)
        try Tool.run(python, ["-I", Library.metricsScript.path, "--cluster", inputFile.path, metricsFile.path])
        let data = try Data(contentsOf: metricsFile)
        return (try ClusterMetrics.decode(data), data)
    }
}

/// A long command whose lines are read as it runs.
struct Command {
    var executable: URL
    var args: [String]
    var environment: [String: String]
    var directory: URL
    var log: URL

    func run(onLine: @escaping @Sendable (String) -> Void) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let stop = Stopper(process)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { try? logHandle.close() }
                    do {
                        try stop.launch()
                    } catch {
                        done.resume(throwing: error)
                        return
                    }
                    let reader = pipe.fileHandleForReading
                    var lines = LineSplitter()
                    var tail: [String] = []
                    func said(_ line: String) {
                        tail.append(line)
                        if tail.count > 30 { tail.removeFirst() }
                        onLine(line)
                    }
                    while true {
                        let data = reader.availableData
                        if data.isEmpty { break }
                        logHandle.write(data)
                        lines.feed(data).forEach(said)
                    }
                    lines.finish().forEach(said)
                    process.waitUntilExit()
                    if stop.stopped {
                        done.resume(throwing: CancellationError())
                    } else if process.terminationStatus != 0 {
                        let last = tail.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(15)
                        done.resume(throwing: OviusError(message: last.isEmpty ? "It stopped with code \(process.terminationStatus)." : last.joined(separator: "\n")))
                    } else {
                        done.resume()
                    }
                }
            }
        } onCancel: {
            stop.stop()
        }
    }
}

/// Starts a process unless it was already stopped, and stops it (and what it started) once running.
private final class Stopper: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private(set) var stopped = false

    init(_ process: Process) {
        self.process = process
    }

    func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        if stopped { throw CancellationError() }
        try process.run()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        guard process.isRunning else { return }
        // run.sh's own commands (pip, while installing) first: they would carry on without it.
        _ = try? Tool.run(URL(fileURLWithPath: "/usr/bin/pkill"), ["-TERM", "-P", String(process.processIdentifier)])
        process.terminate()
    }
}

/// Bytes into lines, at \n or \r.
struct LineSplitter {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lines.append(String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...end)
        }
        return lines.filter { !$0.isEmpty }
    }

    mutating func finish() -> [String] {
        defer { buffer = Data() }
        return buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
    }
}
