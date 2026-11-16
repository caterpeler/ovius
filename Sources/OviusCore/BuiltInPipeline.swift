import Foundation

/// The detector the built-in pipeline runs: a model or workflow from the labeler as run_workflow.py reads it
/// (detector.json: its classes, each step's model file, preprocessing and rules), kept in the library's
/// models/detector/ with its files.
public struct Detector: Equatable {
    public var name: String
    public var classes: [String]
    public var spec: URL
    /// Packages its preprocessing code imports, beyond the pipeline's own.
    public var needs: [String]
}

/// A state model from the labeler's state training, which gives each excavator its states (digging, swinging,
/// loading, idle…) in place of the motion rule's working or idle. Kept in the library's models/states/.
public struct StateModel: Equatable {
    public enum Kind: String, Codable {
        /// Judges a clip around a moment, every so often (a state classification run's).
        case clips
        /// Labels every frame of a whole track at once (a temporal segmentation run's).
        case segmentation
    }

    public var name: String
    public var kind: Kind
    /// Its states, when the file it came with names them.
    public var states: [String]
    public var file: URL
}

/// The detector and the state model in the library.
public enum Models {
    public static func detector(in library: Library) -> Detector? {
        let spec = library.detector.appendingPathComponent("detector.json")
        guard let data = try? Data(contentsOf: spec), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let classes = json["classes"] as? [String] ?? []
        let steps = json["steps"] as? [[String: Any]] ?? []
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? steps.first?["model_name"] as? String ?? "Detector"
        return Detector(name: name, classes: classes, spec: spec, needs: needs(of: steps))
    }

    /// Takes a detector into the library, in place of the one there: a bundle from the labeler (a model's or a
    /// pipeline's, as its .tar.gz or unpacked), which holds the spec and the model files, or a D-FINE checkpoint
    /// (.pth) with its .dfine.json beside it.
    @discardableResult
    public static func importDetector(_ source: URL, into library: Library) throws -> Detector {
        let fm = FileManager.default
        try fm.createDirectory(at: library.models, withIntermediateDirectories: true)
        let staging = library.models.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let made = staging.appendingPathComponent("detector", isDirectory: true)
        try fm.createDirectory(at: made.appendingPathComponent("models"), withIntermediateDirectories: true)

        var spec: [String: Any]
        let name = source.lastPathComponent.lowercased()
        if source.pathExtension.lowercased() == "pth" {
            spec = try dfineSpec(source)
        } else if [".tar.gz", ".tgz", ".tar"].contains(where: name.hasSuffix) || source.pathExtension.lowercased() == "pt" || source.pathExtension.lowercased() == "onnx" {
            if source.pathExtension.lowercased() == "pt" || source.pathExtension.lowercased() == "onnx" {
                throw OviusError(message: "\(source.lastPathComponent) alone does not name its classes. Choose its bundle from the labeler (the model's Download bundle), which does.")
            }
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try Tool.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", source.path, "-C", unpacked.path])
            spec = try bundleSpec(in: unpacked)
        } else {
            spec = try bundleSpec(in: source)
        }

        // Each step's model (and a D-FINE model's config) into models/, the spec pointing at them there.
        guard let classes = spec["classes"] as? [String], !classes.isEmpty else {
            throw OviusError(message: "The detector does not name its classes.")
        }
        let folder = URL(fileURLWithPath: spec.removeValue(forKey: "_folder") as? String ?? "", isDirectory: true)
        var steps = spec["steps"] as? [[String: Any]] ?? []
        guard !steps.isEmpty else { throw OviusError(message: "The detector has no model.") }
        for k in steps.indices {
            guard let path = steps[k]["model"] as? String else { throw OviusError(message: "A step of the detector names no model file.") }
            let file = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
            guard fm.fileExists(atPath: file.path) else { throw OviusError(message: "The detector's model \(path) is not with it.") }
            let into = made.appendingPathComponent("models/\(file.lastPathComponent)")
            if !fm.fileExists(atPath: into.path) { try fm.copyItem(at: file, to: into) }
            if file.pathExtension.lowercased() == "pth" {
                let meta = file.deletingPathExtension().appendingPathExtension("dfine.json")
                guard fm.fileExists(atPath: meta.path) else {
                    throw OviusError(message: "\(file.lastPathComponent) is a D-FINE model without its \(meta.lastPathComponent) (its config and classes).")
                }
                let metaInto = made.appendingPathComponent("models/\(meta.lastPathComponent)")
                if !fm.fileExists(atPath: metaInto.path) { try fm.copyItem(at: meta, to: metaInto) }
            }
            steps[k]["model"] = "models/\(file.lastPathComponent)"
        }
        spec["steps"] = steps
        try JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted, .sortedKeys]).write(to: made.appendingPathComponent("detector.json"))

        if fm.fileExists(atPath: library.detector.path) { try fm.removeItem(at: library.detector) }
        try fm.moveItem(at: made, to: library.detector)
        guard let detector = detector(in: library) else { throw OviusError(message: "Could not keep the detector.") }
        return detector
    }

    /// The spec in an unpacked labeler bundle: a model's workflow.json, or a pipeline's single detector-<node>.json;
    /// the folder its paths are relative to under `_folder`.
    static func bundleSpec(in folder: URL) throws -> [String: Any] {
        let fm = FileManager.default
        var top = folder
        func specs(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent == "workflow.json" || ($0.lastPathComponent.hasPrefix("detector-") && $0.pathExtension == "json") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        // A bundle packed again may hold its files in one folder.
        if specs(top).isEmpty {
            let inside = ((try? fm.contentsOfDirectory(at: top, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix(".") }
            if inside.count == 1 { top = inside[0] }
        }
        let found = specs(top)
        guard let file = found.first else {
            throw OviusError(message: "\(folder.lastPathComponent) is not a model or pipeline bundle from the labeler: it has no workflow.json or detector-….json.")
        }
        guard found.count == 1 else {
            throw OviusError(message: "\(folder.lastPathComponent) has \(found.count) detectors (\(found.map(\.lastPathComponent).joined(separator: ", "))): the built-in pipeline runs one.")
        }
        guard var spec = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw OviusError(message: "\(file.lastPathComponent) is not a detector's spec.")
        }
        spec["_folder"] = top.path
        return spec
    }

    /// A D-FINE checkpoint on its own, as one step: its classes from its .dfine.json.
    static func dfineSpec(_ file: URL) throws -> [String: Any] {
        let meta = file.deletingPathExtension().appendingPathExtension("dfine.json")
        guard let data = try? Data(contentsOf: meta), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = json["names"] as? [String] else {
            throw OviusError(message: "\(file.lastPathComponent) needs its \(meta.lastPathComponent) beside it (its config and classes), as the labeler keeps them.")
        }
        let name = file.deletingPathExtension().lastPathComponent
        return [
            "_folder": file.deletingLastPathComponent().path,
            "name": name,
            "classes": names,
            "merge": ["measure": "iou", "threshold": 1.0, "across_classes": false],
            "rules": ["classes": [String](), "exclude": [String](), "min_confidence": 0.0],
            "steps": [["model": file.lastPathComponent, "model_name": name, "preprocess": [String: Any](), "rules": ["min_confidence": 0.02]]],
        ]
    }

    /// The packages a detector's preprocessing code blocks import that the pipeline does not install.
    static func needs(of steps: [[String: Any]]) -> [String] {
        let code = steps.flatMap { (($0["preprocess"] as? [String: Any])?["code"] as? [[String: Any]]) ?? [] }.compactMap { $0["source"] as? String }
        var found: [String] = []
        for module in code.flatMap(imports) {
            guard !stdlib.contains(module), !installed.contains(module) else { continue }
            let package = pipNames[module] ?? module
            if !found.contains(package) { found.append(package) }
        }
        return found
    }

    /// The top-level modules Python code imports, in order: `import a.b, c as d` gives a and c, `from e.f import g`
    /// gives e. Relative imports are left out.
    static func imports(_ code: String) -> [String] {
        var found: [String] = []
        for raw in code.split(separator: "\n") {
            let line = (raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
            var names: [String] = []
            if line.hasPrefix("import ") {
                names = line.dropFirst(7).split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
            } else if line.hasPrefix("from ") {
                names = line.dropFirst(5).split(separator: " ").first.map { [String($0)] }?.filter { !$0.hasPrefix(".") } ?? []
            }
            for name in names {
                let top = String(name.split(separator: ".").first ?? "")
                if !top.isEmpty, top.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !found.contains(top) { found.append(top) }
            }
        }
        return found
    }

    /// What requirements.txt installs anyway, by module.
    private static let installed: Set<String> = ["numpy", "cv2", "pandas", "torch", "torchvision", "yaml", "PIL", "ultralytics", "lap", "scipy"]
    private static let pipNames = ["cv2": "opencv-python", "PIL": "Pillow", "yaml": "PyYAML", "sklearn": "scikit-learn",
                                   "skimage": "scikit-image", "dateutil": "python-dateutil"]
    private static let stdlib: Set<String> = [
        "abc", "argparse", "array", "ast", "asyncio", "base64", "bisect", "builtins", "bz2", "calendar", "cmath", "collections",
        "colorsys", "concurrent", "contextlib", "copy", "csv", "ctypes", "dataclasses", "datetime", "decimal", "difflib", "enum",
        "errno", "fnmatch", "fractions", "functools", "gc", "glob", "gzip", "hashlib", "heapq", "hmac", "html", "http", "inspect",
        "io", "itertools", "json", "logging", "lzma", "math", "multiprocessing", "numbers", "operator", "os", "pathlib", "pickle",
        "platform", "pprint", "queue", "random", "re", "shutil", "signal", "socket", "sqlite3", "statistics", "string", "struct",
        "subprocess", "sys", "tempfile", "textwrap", "threading", "time", "timeit", "traceback", "types", "typing", "unicodedata",
        "urllib", "uuid", "warnings", "weakref", "zipfile", "zlib",
    ]

    // MARK: State model

    public static func stateModel(in library: Library) -> StateModel? {
        struct About: Decodable {
            var name: String
            var kind: StateModel.Kind
            var file: String
            var states: [String]
        }
        guard let data = try? Data(contentsOf: library.stateModel.appendingPathComponent("state.json")),
              let about = try? JSONDecoder().decode(About.self, from: data) else { return nil }
        let file = library.stateModel.appendingPathComponent(about.file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return StateModel(name: about.name, kind: about.kind, states: about.states, file: file)
    }

    /// Takes a state model (state_model.pth or segment_model.pth, from a state training run) into the library, in
    /// place of the one there. Its states are read from the .json the run wrote beside it, when it is there.
    @discardableResult
    public static func importStateModel(_ source: URL, into library: Library) throws -> StateModel {
        let fm = FileManager.default
        guard source.pathExtension.lowercased() == "pth" else {
            throw OviusError(message: "A state model is a .pth file from the labeler's state training (state_model.pth or segment_model.pth).")
        }
        let kind = try kindOf(source)
        let stem = source.deletingPathExtension().lastPathComponent
        let generic = ["state_model", "segment_model", "model", "best", "last"].contains(stem.lowercased())
        let name = generic ? source.deletingLastPathComponent().lastPathComponent : stem
        var states: [String] = []
        let about = source.deletingPathExtension().appendingPathExtension("json")
        if let data = try? Data(contentsOf: about), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            states = json["states"] as? [String] ?? []
        }
        try fm.createDirectory(at: library.models, withIntermediateDirectories: true)
        let made = library.models.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: source, to: made.appendingPathComponent(source.lastPathComponent))
            let record: [String: Any] = ["name": name, "kind": kind.rawValue, "file": source.lastPathComponent, "states": states]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: made.appendingPathComponent("state.json"))
            if fm.fileExists(atPath: library.stateModel.path) { try fm.removeItem(at: library.stateModel) }
            try fm.moveItem(at: made, to: library.stateModel)
        } catch {
            try? fm.removeItem(at: made)
            throw error
        }
        guard let model = stateModel(in: library) else { throw OviusError(message: "Could not keep the state model.") }
        return model
    }

    public static func removeStateModel(from library: Library) throws {
        if FileManager.default.fileExists(atPath: library.stateModel.path) { try FileManager.default.removeItem(at: library.stateModel) }
    }

    /// Which training made the file, from the format PyTorch's pickle names near its start.
    static func kindOf(_ file: URL) throws -> StateModel.Kind {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw OviusError(message: "Could not read \(file.lastPathComponent).") }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4 << 20)) ?? Data()
        if head.range(of: Data("labeler-segment-model".utf8)) != nil { return .segmentation }
        if head.range(of: Data("labeler-state-model".utf8)) != nil { return .clips }
        throw OviusError(message: "\(file.lastPathComponent) is not a state model made by the labeler's state training.")
    }
}

/// The pipeline the app runs on each camera's video: the labeler's "Loading productivity (PTZ)" steps with their
/// settings, and the state model's step when there is one. Its code (run_pipeline.py and the rest) comes with the
/// app; the detector and the state model are the library's.
public enum BuiltInPipeline {
    /// The folder holding run.sh, run_pipeline.py, run_workflow.py, state_models.py and dfine/: in the app's
    /// Resources, or beside this file when run with `swift run`.
    public static var folder: URL {
        if let url = Bundle.main.url(forResource: "pipeline", withExtension: nil) { return url }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("pipeline", isDirectory: true)
    }

    /// What it is called in the library: analyses are compared with others of the same.
    public static func name(detector: Detector, states: StateModel?) -> String {
        "Built-in · \(detector.name)" + (states.map { " + states · \($0.name)" } ?? "")
    }

    public static func steps(states: StateModel?) -> [String] {
        ["Video", "Detect", "Camera motion", "Still views", "Track", "Re-link after moves", "Fill gaps", "Machine state"]
            + (states == nil ? [] : ["Classify states"]) + ["Loading events", "Productivity report"]
    }

    /// pipeline.json, as run_pipeline.py reads it: the nodes in the order they run.
    public static func spec(detector: Detector, states: StateModel?, settings: Settings) -> [String: Any] {
        func node(_ id: String, _ kind: String, _ label: String, inputs: [String: [String]] = [:], outputs: [String], optional: [String] = [],
                  _ params: [String: Any]) -> [String: Any] {
            ["id": id, "kind": kind, "label": label, "inputs": inputs, "outputs": outputs, "optional": optional, "params": params]
        }
        let views = ["views", "views"]
        // Machine state's, or the state model's in its place for the excavators.
        let judged = states == nil ? ["state", "states"] : ["classify", "states"]
        var nodes: [[String: Any]] = [
            node("video", "video", "Video", outputs: ["frames"], ["fps": 5.0, "max_seconds": 0.0]),
            node("detect", "detect", "Detect", inputs: ["frames": ["video", "frames"]], outputs: ["detections"],
                 ["detector": detector.spec.path, "model_name": detector.name, "min_confidence": 0.02, "class_confidence": [String: Double](),
                  "class_map": [String: String](), "one_box_iou": 0.7]),
            node("camera", "camera_motion", "Camera motion", inputs: ["frames": ["video", "frames"]], outputs: ["camera"],
                 ["width": 640, "overlay_band_pct": 8.0, "find_overlay": true, "features": 400]),
            node("views", "still_views", "Still views", inputs: ["camera": ["camera", "camera"]], outputs: ["views"],
                 ["split": true, "move_rate": 0.15, "settle_s": 0.4]),
            node("track", "track", "Track", inputs: ["detections": ["detect", "detections"], "views": views], outputs: ["tracks"], optional: ["views"],
                 ["tracker": "bytetrack", "new_confidence": 0.25, "continue_confidence": 0.02, "keep_s": 20.0, "match_threshold": 0.8,
                  "follow_camera": true, "restart_each_view": false]),
            node("relink", "relink", "Re-link after moves", inputs: ["tracks": ["track", "tracks"], "views": views], outputs: ["tracks", "links"],
                 ["window_s": 3.0, "look_back_s": 120.0, "sift_features": 3000, "min_matches": 30, "max_cost": 1.0, "match_width": 960]),
            node("fill", "fill", "Fill gaps", inputs: ["tracks": ["relink", "tracks"], "views": views], outputs: ["tracks"], optional: ["views"],
                 ["max_gap_s": 0.0]),
            node("state", "machine_state", "Machine state", inputs: ["tracks": ["fill", "tracks"], "views": views], outputs: ["states"], optional: ["views"],
                 ["window_s": 4.0, "stop_speed": 0.05, "working_change": 0.05, "min_state_s": 3.0, "excavator_classes": "excavator"]),
        ]
        if let states {
            nodes.append(node("classify", "classify_states", "Classify states", inputs: ["states": ["state", "states"]], outputs: ["states"],
                              ["model_file": states.file.path, "model_name": states.name, "classes": "excavator", "every_s": 1.0,
                               "clip_s": settings.stateClipS, "padding": 0.15, "min_confidence": 0.0, "min_state_s": 1.0,
                               "idle_states": settings.idleStates]))
        }
        nodes += [
            node("loading", "loading_events", "Loading events", inputs: ["states": judged], outputs: ["events"],
                 ["truck_classes": "dumptruck", "excavator_classes": "excavator", "beside": 0.3, "near": 6.0, "same_ground": 1.0,
                  "min_loading_s": 20.0, "min_queue_s": 0.0, "working_share": 0.3, "gap_s": 3.0, "min_exchange_s": 10.0]),
            node("report", "productivity_report", "Productivity report", inputs: ["events": ["loading", "events"], "states": judged], outputs: [],
                 ["file": "report.csv", "events_file": "events.csv", "excavator_classes": "excavator", "start_time": ""]),
        ]
        return ["name": "ovius", "nodes": nodes]
    }

    /// The packages a run needs, as the library's models/requirements.txt: the pipeline's, and what the detector's
    /// preprocessing code imports.
    public static func requirements(for detector: Detector, in library: Library) throws -> URL {
        let file = library.models.appendingPathComponent("requirements.txt")
        let text = (["# What the built-in pipeline needs, with this detector (written by the app).", "-r \(folder.appendingPathComponent("requirements.txt").path)"]
            + detector.needs.map { "\($0)  # the detector's preprocessing" }).joined(separator: "\n") + "\n"
        if (try? String(contentsOf: file, encoding: .utf8)) != text {
            try FileManager.default.createDirectory(at: library.models, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return file
    }
}
