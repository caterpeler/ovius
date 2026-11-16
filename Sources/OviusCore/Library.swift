import Foundation

/// Where the app keeps everything: ~/Library/Application Support/ovius.
///
///     ovius.sqlite          sites, clusters, cameras, pipelines, batches, analyses and their figures
///     models/               the built-in pipeline's detector (detector/) and state model (states/), and requirements.txt
///     analyses/<id>/        the copied video, out/ (what the pipeline wrote), settings.json, metrics.json, run.log
///     batches/<id>/         a cluster's figures: cluster.json (what they come from) and metrics.json
///     python/               the Python the app set up (python-build-standalone)
///     venv/                 the pipelines' packages (PyTorch and the rest), shared by every bundle
public struct Library {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The usual one, or OVIUS_LIBRARY's folder (to try the app on a library of its own).
    public static func standard() -> Library {
        if let root = ProcessInfo.processInfo.environment["OVIUS_LIBRARY"], !root.isEmpty {
            return Library(root: URL(fileURLWithPath: root, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Library(root: support.appendingPathComponent("ovius", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("ovius.sqlite") }
    public var pipelines: URL { root.appendingPathComponent("pipelines", isDirectory: true) }
    public var analyses: URL { root.appendingPathComponent("analyses", isDirectory: true) }
    public var batches: URL { root.appendingPathComponent("batches", isDirectory: true) }
    public var python: URL { root.appendingPathComponent("python", isDirectory: true) }
    public var venv: URL { root.appendingPathComponent("venv", isDirectory: true) }
    public var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    public var detector: URL { models.appendingPathComponent("detector", isDirectory: true) }
    public var stateModel: URL { models.appendingPathComponent("states", isDirectory: true) }

    public func pipeline(_ id: Int64) -> URL { pipelines.appendingPathComponent(String(id), isDirectory: true) }
    public func analysis(_ id: Int64) -> URL { analyses.appendingPathComponent(String(id), isDirectory: true) }
    public func batch(_ id: Int64) -> URL { batches.appendingPathComponent(String(id), isDirectory: true) }

    public func make() throws {
        for dir in [root, models, analyses, batches, downloads] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// The Python the app set up, once it has.
    public var setUpPython: URL? {
        let python = python.appendingPathComponent("bin/python3")
        return FileManager.default.isExecutableFile(atPath: python.path) ? python : nil
    }

    /// metrics.py: in the app's Resources, or beside this file when run with `swift run`.
    public static var metricsScript: URL {
        if let url = Bundle.main.url(forResource: "metrics", withExtension: "py") { return url }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("metrics.py")
    }
}

/// The camera's clock, as text without a time zone: 2024-02-02 16:00:56.
public enum CameraClock {
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// The text as typed, tidied (2024-02-02T16:00:56 → 2024-02-02 16:00:56); nil when it is not a real date and time.
    public static func parse(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
        guard t.count == 19, let date = format.date(from: t) else { return nil }
        return format.string(from: date)
    }

    /// The clock `seconds` after `start`.
    public static func adding(_ seconds: Double, to start: String) -> String? {
        format.date(from: start).map { format.string(from: $0.addingTimeInterval(seconds)) }
    }

    /// The camera's clock at a video's start, from the recorder's file name: the first of 20250115092459,
    /// 20250115_092459 or 2024-09-18-09-02-49 that is a real date and time (as the labeler's runner reads it).
    public static func fromFileName(_ name: String) -> String? {
        let sep = "[-_.: T]"
        let pattern = "(?<!\\d)(?:(\\d{14})|(\\d{8})\(sep)(\\d{6})|(\\d{4})\(sep)(\\d{2})\(sep)(\\d{2})\(sep)(\\d{2})\(sep)(\\d{2})\(sep)(\\d{2}))(?!\\d)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = name as NSString
        for m in regex.matches(in: name, range: NSRange(location: 0, length: text.length)) {
            func group(_ k: Int) -> String? {
                let r = m.range(at: k)
                return r.location == NSNotFound ? nil : text.substring(with: r)
            }
            let digits = group(1) ?? group(2).map { $0 + (group(3) ?? "") } ?? (4...9).compactMap(group).joined()
            guard digits.count == 14 else { continue }
            let d = Array(digits)
            let iso = "\(String(d[0..<4]))-\(String(d[4..<6]))-\(String(d[6..<8])) \(String(d[8..<10])):\(String(d[10..<12])):\(String(d[12..<14]))"
            if let clock = parse(iso), let year = Int(String(d[0..<4])), (2000..<2100).contains(year) {
                return clock
            }
        }
        return nil
    }
}
