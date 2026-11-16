import Foundation
import SQLite3
import XCTest
@testable import OviusCore

final class CameraClockTests: XCTestCase {
    func testReadsTheStartFromARecordersFileName() {
        XCTAssertEqual(CameraClock.fromFileName("ch01_20240202160056.mp4"), "2024-02-02 16:00:56")
        XCTAssertEqual(CameraClock.fromFileName("NVR_20250115_092459.mp4"), "2025-01-15 09:24:59")
        XCTAssertEqual(CameraClock.fromFileName("2024-09-18-09-02-49.mp4"), "2024-09-18 09:02:49")
        // Not a real time, then a real one.
        XCTAssertEqual(CameraClock.fromFileName("20241399999999_20240101000000.mp4"), "2024-01-01 00:00:00")
        XCTAssertNil(CameraClock.fromFileName("pit3 north.mp4"))
        XCTAssertNil(CameraClock.fromFileName("120240202160056.mp4"))
    }

    func testTidiesATypedStart() {
        XCTAssertEqual(CameraClock.parse(" 2024-02-02T16:00:56 "), "2024-02-02 16:00:56")
        XCTAssertNil(CameraClock.parse("2024-02-30 16:00:56"))
        XCTAssertNil(CameraClock.parse("yesterday"))
        XCTAssertEqual(CameraClock.adding(3600, to: "2024-02-02 23:30:00"), "2024-02-03 00:30:00")
    }
}

final class ProgressReaderTests: XCTestCase {
    func testFollowsTheRunnersLines() {
        var reader = ProgressReader()
        XCTAssertEqual(reader.read("Making a Python environment in /x/venv (Python 3.12.8)")?.stage, "Making a Python environment")
        XCTAssertNil(reader.read("Collecting torch"))
        XCTAssertEqual(reader.read("Detect, Track: 1800 s of video, 1 frame in 6"), RunProgress(stage: "Watching the video", fraction: 0))
        XCTAssertEqual(reader.read("   450 s of video | 2250 frames | 14.2 frames/s")?.fraction, 0.25)
        XCTAssertEqual(reader.read("analysed 9000 frames in 640 s")?.fraction, 1)
        XCTAssertEqual(reader.read("running Loading events (loading)"), RunProgress(stage: "Loading events"))
        XCTAssertEqual(reader.read("Detect: cached (detect-1a2b.parquet)")?.stage, "Reusing what an earlier run saw")
    }
}

final class DatabaseTests: XCTestCase {
    func testKeepsSitesClustersCamerasPipelinesAndBatches() throws {
        let dir = try temporaryFolder()
        let path = dir.appendingPathComponent("ovius.sqlite").path
        do {
            let store = Store(try Database(path: path))
            let alpha = try store.cluster(site: "Pit 3", name: "Section Alpha")
            XCTAssertEqual(try store.cluster(site: "pit 3", name: "section alpha"), alpha, "found again, whatever the case")
            let north = try store.camera(cluster: alpha.id, name: "North")
            let south = try store.camera(cluster: alpha.id, name: "South")
            let beta = try store.cluster(site: "Pit 3", name: "Section Beta")
            XCTAssertNotEqual(try store.camera(cluster: beta.id, name: "North").id, north.id, "camera names are per cluster")
            let pipeline = try store.addPipeline(name: "Loading", nodes: ["Video", "Detect"], reportFile: "report.csv", eventsFile: "events.csv")
            let (batch, ids) = try store.addBatch(cluster: alpha.id, pipeline: pipeline, videos: [
                .init(camera: north.id, videoName: "n.mp4", start: "2024-02-02 16:00:56"), .init(camera: south.id, videoName: "s.mp4", start: nil),
            ], status: .queued)
            XCTAssertEqual(ids.count, 2)
            XCTAssertEqual(try store.analyses(of: batch).map(\.cameraID), [north.id, south.id])
            XCTAssertThrowsError(try store.addBatch(cluster: alpha.id, pipeline: pipeline, videos: [
                .init(camera: north.id, videoName: "a.mp4", start: nil), .init(camera: north.id, videoName: "b.mp4", start: nil),
            ], status: .queued), "one video per camera")
            XCTAssertThrowsError(try store.addBatch(cluster: beta.id, pipeline: pipeline, videos: [.init(camera: north.id, videoName: "a.mp4", start: nil)],
                                                    status: .queued), "a camera of another cluster")
        }
        // Opened again: the steps are not run twice, and the rows are there.
        let store = Store(try Database(path: path))
        XCTAssertEqual(try store.db.query("PRAGMA user_version").first?.int("user_version"), Int64(Database.version))
        XCTAssertNil(store.db.backup, "nothing to back up: the library was made by this version")
        let c = try store.read()
        XCTAssertEqual(c.sites.map(\.name), ["Pit 3"])
        XCTAssertEqual(c.clusters.map(\.name), ["Section Alpha", "Section Beta"])
        XCTAssertEqual(c.pipelines.first?.nodes, ["Video", "Detect"])
        XCTAssertEqual(c.batches.count, 1)
        XCTAssertEqual(c.analyses.map(\.status), [.queued, .queued])
        XCTAssertEqual(c.analyses.first?.start, "2024-02-02 16:00:56")
        XCTAssertNil(c.analyses.first?.metrics)
    }
}

/// The step from Site → Camera, each video its own analysis, to Site → Cluster → Camera with batches, on a library
/// made by the version before.
/// Clusters by their names alone: the app shows no sites.
final class ClusterNameTests: XCTestCase {
    func testFindsAndMakesClustersByName() throws {
        let store = Store(try Database(path: ":memory:"))
        let alpha = try store.cluster(site: "Labeler host runs", name: "Section Alpha")
        XCTAssertEqual(try store.cluster(named: " section alpha ").id, alpha.id, "found whatever its site, in any case")
        let beta = try store.cluster(named: "Section Beta")
        XCTAssertEqual(beta.siteID, alpha.siteID, "made at the library's first site")
        XCTAssertThrowsError(try store.rename(cluster: beta, name: "SECTION ALPHA"))
        try store.rename(cluster: beta, name: "Section Gamma")
        XCTAssertEqual(try store.read().clusters.map(\.name).sorted(), ["Section Alpha", "Section Gamma"])
        XCTAssertThrowsError(try store.cluster(named: "  "))
    }
}

final class MigrationTests: XCTestCase {
    func testKeepsEveryAnalysisOfALibraryWithData() throws {
        let dir = try temporaryFolder()
        let path = dir.appendingPathComponent("ovius.sqlite").path
        try makeVersionOneLibrary(at: path)

        let db = try Database(path: path)
        XCTAssertEqual(try db.query("PRAGMA user_version").first?.int("user_version"), Int64(Database.version))
        XCTAssertEqual(try db.query("PRAGMA foreign_keys").first?.int("foreign_keys"), 1, "foreign keys on again")
        XCTAssertTrue(try db.query("PRAGMA foreign_key_check").isEmpty)

        // The copy made first is the library as it was.
        let backup = try XCTUnwrap(db.backup)
        XCTAssertEqual(backup.lastPathComponent, "ovius.sqlite.before-step-2")
        let old = try Database(path: ":memory:")
        try old.execute("ATTACH DATABASE '\(backup.path)' AS old")
        XCTAssertEqual(try old.query("PRAGMA old.user_version").first?.int("user_version"), 1)
        XCTAssertEqual(try old.query("SELECT count(*) AS n FROM old.analyses").first?.int("n"), 3)

        let c = try Store(db).read()
        XCTAssertEqual(c.sites.map(\.name), ["Labeler host runs"])
        // Each camera is a cluster of its own, of its name; each analysis a batch of one camera.
        XCTAssertEqual(c.clusters.map(\.name), ["mock_sample", "rafi_anotasi"])
        XCTAssertEqual(c.cameras.map { [$0.id, $0.clusterID] }, [[1, 1], [2, 2]])
        XCTAssertEqual(c.batches.map(\.id).sorted(), [1, 2, 3])
        XCTAssertEqual(c.analyses.map(\.batchID), [1, 2, 3])
        XCTAssertEqual(c.batches.first { $0.id == 3 }?.clusterID, 2)
        XCTAssertEqual(c.analyses.map(\.videoName), ["mock_sample_1.mp4", "mock_sample_2.mp4", "rafi_anotasi_1.mp4"])
        XCTAssertEqual(c.analyses.map(\.status), [.done, .done, .failed])
        // Figures of the old version are not read: the app works them out again.
        XCTAssertNil(c.analyses[0].metrics)
        XCTAssertEqual(c.settings.m3PerLoad, 48.0, "the settings kept, what is left of them")

        // It works as a library of this version: a new batch next to the old ones, and nothing left to migrate.
        let store = Store(db)
        let camera = try store.camera(cluster: 1, name: "mock_sample 2")
        _ = try store.addBatch(cluster: 1, pipeline: 1, videos: [.init(camera: camera.id, videoName: "x.mp4", start: nil)], status: .queued)
        XCTAssertNil(try Database(path: path).backup)
    }

    /// A library as the version before left it: one site, two cameras, a pipeline and three analyses.
    private func makeVersionOneLibrary(at path: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE sites (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE);
        CREATE TABLE cameras (id INTEGER PRIMARY KEY, site_id INTEGER NOT NULL REFERENCES sites(id), name TEXT NOT NULL COLLATE NOCASE,
                              UNIQUE (site_id, name));
        CREATE TABLE pipelines (id INTEGER PRIMARY KEY, name TEXT NOT NULL, nodes TEXT NOT NULL, report_file TEXT NOT NULL,
                                events_file TEXT NOT NULL, imported_at REAL NOT NULL);
        CREATE TABLE analyses (id INTEGER PRIMARY KEY, camera_id INTEGER NOT NULL REFERENCES cameras(id),
                               pipeline_id INTEGER NOT NULL REFERENCES pipelines(id), video_name TEXT NOT NULL, start TEXT, status TEXT NOT NULL,
                               error TEXT, metrics TEXT, created_at REAL NOT NULL, finished_at REAL);
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO sites VALUES (1, 'Labeler host runs');
        INSERT INTO cameras VALUES (1, 1, 'mock_sample'), (2, 1, 'rafi_anotasi');
        INSERT INTO pipelines VALUES (1, 'PTZ tracker + loading events', '[]', 'report.csv', 'events.csv', 100);
        INSERT INTO analyses VALUES (1, 1, 1, 'mock_sample_1.mp4', NULL, 'done', NULL, '{"version": 1, "totals": {}}', 200, 210),
                                    (2, 1, 1, 'mock_sample_2.mp4', NULL, 'done', NULL, '{"version": 1, "totals": {}}', 201, 211),
                                    (3, 2, 1, 'rafi_anotasi_1.mp4', NULL, 'failed', 'It stopped', NULL, 202, 212);
        INSERT INTO settings VALUES ('settings', '{"m3PerLoad": 48.0, "longStopS": 300, "shifts": []}');
        PRAGMA user_version = 1;
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(handle)))
    }
}

/// The pipeline the app runs: the labeler's runner, with the library's detector and (when there is one) state model.
final class BuiltInPipelineTests: XCTestCase {
    func testImportsADetectorFromALabelerBundle() throws {
        let dir = try temporaryFolder()
        let library = Library(root: dir.appendingPathComponent("library"))
        try library.make()
        let archive = try detectorBundle(in: dir, code: "import cv2\nimport numpy as np\nfrom skimage import exposure\nimport json\n")
        let detector = try Models.importDetector(archive, into: library)
        XCTAssertEqual(detector.name, "S-v3-mini-dfine")
        XCTAssertEqual(detector.classes, ["excavator", "dumptruck", "bulldozer"])
        XCTAssertEqual(detector.needs, ["scikit-image"], "what its preprocessing imports beyond the pipeline's packages")
        // The spec points at its model in the library, with the D-FINE config beside it.
        let spec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: detector.spec)) as? [String: Any])
        let step = try XCTUnwrap((spec["steps"] as? [[String: Any]])?.first)
        XCTAssertEqual(step["model"] as? String, "models/S-v3-mini-dfine.pth")
        for file in ["models/S-v3-mini-dfine.pth", "models/S-v3-mini-dfine.dfine.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: library.detector.appendingPathComponent(file).path), file)
        }
        XCTAssertEqual(Models.detector(in: library), detector)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.models.path).filter { $0.hasPrefix(".") }, [])

        let requirements = try BuiltInPipeline.requirements(for: detector, in: library)
        let text = try String(contentsOf: requirements, encoding: .utf8)
        XCTAssertTrue(text.contains("-r \(BuiltInPipeline.folder.appendingPathComponent("requirements.txt").path)"))
        XCTAssertTrue(text.contains("scikit-image"))
    }

    func testRefusesADetectorItCannotRun() throws {
        let dir = try temporaryFolder()
        let library = Library(root: dir.appendingPathComponent("library"))
        try library.make()
        let alone = dir.appendingPathComponent("best.pt")
        try Data("weights".utf8).write(to: alone)
        XCTAssertThrowsError(try Models.importDetector(alone, into: library)) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not name its classes"), error.localizedDescription)
        }
        let pth = dir.appendingPathComponent("best.pth")
        try Data("weights".utf8).write(to: pth)
        XCTAssertThrowsError(try Models.importDetector(pth, into: library)) { error in
            XCTAssertTrue(error.localizedDescription.contains("best.dfine.json"), error.localizedDescription)
        }
        XCTAssertNil(Models.detector(in: library))
    }

    func testImportsAStateModel() throws {
        let dir = try temporaryFolder()
        let library = Library(root: dir.appendingPathComponent("library"))
        try library.make()
        let run = dir.appendingPathComponent("segment-v2", isDirectory: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let file = run.appendingPathComponent("segment_model.pth")
        try Data("PK\u{3}\u{4}archive/data.pkl}q(X\u{6}formatqX\u{15}labeler-segment-modelq".utf8).write(to: file)
        try JSONSerialization.data(withJSONObject: ["states": ["digging", "swinging", "loading", "idle"]]).write(to: run.appendingPathComponent("segment_model.json"))
        let model = try Models.importStateModel(file, into: library)
        XCTAssertEqual(model.name, "segment-v2")
        XCTAssertEqual(model.kind, .segmentation)
        XCTAssertEqual(model.states, ["digging", "swinging", "loading", "idle"])
        XCTAssertEqual(Models.stateModel(in: library), model)

        let other = dir.appendingPathComponent("weights.pth")
        try Data("PK\u{3}\u{4}something else".utf8).write(to: other)
        XCTAssertThrowsError(try Models.importStateModel(other, into: library))
        XCTAssertEqual(Models.stateModel(in: library), model, "a refused one leaves the one there")
        try Models.removeStateModel(from: library)
        XCTAssertNil(Models.stateModel(in: library))
    }

    func testWritesTheStateModelsStepOnlyWhenThereIsOne() throws {
        let detector = Detector(name: "S-v3", classes: ["excavator", "dumptruck"], spec: URL(fileURLWithPath: "/lib/models/detector/detector.json"), needs: [])
        let states = StateModel(name: "segment-v2", kind: .segmentation, states: [], file: URL(fileURLWithPath: "/lib/models/states/segment_model.pth"))
        var settings = Settings()
        settings.idleStates = "idle, waiting"

        let plain = BuiltInPipeline.spec(detector: detector, states: nil, settings: settings)
        let nodes = try XCTUnwrap(plain["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.compactMap { $0["kind"] as? String }, ["video", "detect", "camera_motion", "still_views", "track", "relink", "fill",
                                                                   "machine_state", "loading_events", "productivity_report"])
        XCTAssertEqual((nodes[1]["params"] as? [String: Any])?["detector"] as? String, "/lib/models/detector/detector.json")
        XCTAssertEqual((nodes[8]["inputs"] as? [String: [String]])?["states"], ["state", "states"])

        let judged = try XCTUnwrap(BuiltInPipeline.spec(detector: detector, states: states, settings: settings)["nodes"] as? [[String: Any]])
        XCTAssertEqual(judged.compactMap { $0["kind"] as? String }.firstIndex(of: "classify_states"), 8)
        let classify = try XCTUnwrap(judged[8]["params"] as? [String: Any])
        XCTAssertEqual(classify["model_file"] as? String, "/lib/models/states/segment_model.pth")
        XCTAssertEqual(classify["idle_states"] as? String, "idle, waiting")
        XCTAssertEqual((judged[9]["inputs"] as? [String: [String]])?["states"], ["classify", "states"])
        XCTAssertEqual((judged[10]["inputs"] as? [String: [String]])?["states"], ["classify", "states"])
        XCTAssertEqual(BuiltInPipeline.name(detector: detector, states: states), "Built-in · S-v3 + states · segment-v2")
        XCTAssertEqual(BuiltInPipeline.steps(states: states).count, judged.count)
    }

    /// Every setting the labeler's runner reads of a node (p["…"]) is in the pipeline.json the app writes, and each
    /// node's inputs are what the runner's function for it takes.
    func testGivesTheRunnerEverySettingItReads() throws {
        let detector = Detector(name: "S-v3", classes: ["excavator", "dumptruck"], spec: URL(fileURLWithPath: "/d.json"), needs: [])
        let states = StateModel(name: "s", kind: .clips, states: [], file: URL(fileURLWithPath: "/s.pth"))
        let dir = try temporaryFolder()
        let spec = dir.appendingPathComponent("pipeline.json")
        try JSONSerialization.data(withJSONObject: BuiltInPipeline.spec(detector: detector, states: states, settings: Settings())).write(to: spec)
        let check = dir.appendingPathComponent("check.py")
        try #"""
        import ast, json, sys
        runner, spec = sys.argv[1], json.load(open(sys.argv[2]))
        tree = ast.parse(open(runner).read())
        reads, takes = {}, {}
        for fn in tree.body:
            kinds = [d.args[0].value for d in getattr(fn, "decorator_list", []) if isinstance(d, ast.Call) and getattr(d.func, "id", "") == "node"]
            if not kinds:
                continue
            keys = set()
            for n in ast.walk(fn):
                if isinstance(n, ast.Subscript) and isinstance(n.slice, ast.Constant) and isinstance(n.slice.value, str):
                    v = n.value
                    if (isinstance(v, ast.Name) and v.id == "p") or (isinstance(v, ast.Attribute) and v.attr == "p"):
                        keys.add(n.slice.value)
            reads[kinds[0]] = keys
            if isinstance(fn, ast.FunctionDef):
                takes[kinds[0]] = {a.arg for a in fn.args.args[2:]}
        problems = []
        for node in spec["nodes"]:
            missing = reads.get(node["kind"], set()) - set(node["params"])
            if node["kind"] not in reads:
                problems.append(f"the runner has no {node['kind']}")
            if missing:
                problems.append(f"{node['kind']} reads {sorted(missing)}")
            given = set(node["inputs"])
            if node["kind"] in takes and not given <= takes[node["kind"]]:
                problems.append(f"{node['kind']} takes {sorted(takes[node['kind']])}, given {sorted(given)}")
        print("\n".join(problems))
        sys.exit(1 if problems else 0)
        """#.write(to: check, atomically: true, encoding: .utf8)
        let out = try Tool.run(python, ["-I", check.path, BuiltInPipeline.folder.appendingPathComponent("run_pipeline.py").path, spec.path])
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// A pipeline bundle from the labeler, as its Download bundle packs it: a D-FINE detector with a preprocessing
    /// code block.
    private func detectorBundle(in dir: URL, code: String) throws -> URL {
        let files = dir.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: files.appendingPathComponent("models"), withIntermediateDirectories: true)
        let spec: [String: Any] = [
            "name": "S-v3-mini-dfine", "classes": ["excavator", "dumptruck", "bulldozer"],
            "merge": ["measure": "iou", "threshold": 1.0, "across_classes": false],
            "steps": [["model": "models/S-v3-mini-dfine.pth", "model_name": "S-v3-mini-dfine",
                       "preprocess": ["code": [["name": "v3 Bandpass-Chroma CLAHE", "source": code]]]]],
        ]
        try JSONSerialization.data(withJSONObject: spec).write(to: files.appendingPathComponent("detector-detect.json"))
        try Data("weights".utf8).write(to: files.appendingPathComponent("models/S-v3-mini-dfine.pth"))
        try JSONSerialization.data(withJSONObject: ["names": ["excavator", "dumptruck", "bulldozer"], "imgsz": 640])
            .write(to: files.appendingPathComponent("models/S-v3-mini-dfine.dfine.json"))
        for name in ["pipeline.json", "run.sh", "run_pipeline.py"] { try Data("# \(name)\n".utf8).write(to: files.appendingPathComponent(name)) }
        let archive = dir.appendingPathComponent("PTZ_tracker-pipeline.tar.gz")
        try Tool.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-czf", archive.path, "-C", files.path, "."])
        return archive
    }
}

/// A run's flags: figures unlike its cluster's other runs (or every other run), and things to check in its footage.
final class FlagTests: XCTestCase {
    /// A run of `hours` with these figures.
    private func run(hours: Double = 2, cycles: Int = 80, loadS: Double = 100, util: Double = 80, estimated: Int = 0, excavators: Int = 2) -> TeamFigures {
        TeamFigures(durationH: hours, cycles: cycles, observed: cycles - estimated, estimated: estimated, loadSMean: loadS, volumeM3: Double(cycles) * 51.1,
                    excavatorUtilPct: util, excavators: excavators)
    }

    /// Eight runs, load times 95–105 s, 38–42 cycles an hour, utilisation 78–82%.
    private var usualRuns: [TeamFigures] {
        (0..<8).map { k in run(cycles: 76 + k, loadS: 95 + Double(k) * 10 / 7, util: 78 + Double(k % 5)) }
    }

    func testFlagsAFigureOutsideTheClustersUsualRange() {
        let odd = run(cycles: 40, loadS: 150, util: 80)
        let flags = RunFlags.of(total: odd, cameras: [("North", odd)], missing: 0, cluster: usualRuns, overall: usualRuns)
        XCTAssertEqual(flags.unusual.map(\.kpi), [.cyclesPerH, .loadS])
        let load = flags.unusual[1]
        XCTAssertTrue(load.higher)
        XCTAssertEqual(load.verdict, .neither, "a long load is neither better nor worse")
        XCTAssertEqual(load.against.map(\.scope), [.cluster, .overall])
        XCTAssertEqual(load.against[0].runs, 8)
        XCTAssertEqual(load.against[0].median, 100, accuracy: 0.01)
        XCTAssertLessThan(load.against[0].high, 150)
        XCTAssertFalse(flags.unusual[0].higher)
        XCTAssertEqual(flags.unusual[0].verdict, .worse, "fewer cycles an hour is worse")
        XCTAssertTrue(flags.checks.isEmpty)

        let usual = run(cycles: 79, loadS: 101, util: 81)
        XCTAssertTrue(RunFlags.of(total: usual, cameras: [("North", usual)], missing: 0, cluster: usualRuns, overall: usualRuns).isEmpty)
    }

    func testNeedsFourRunsToKnowWhatIsUsual() {
        let odd = run(loadS: 150)
        let flags = RunFlags.of(total: odd, cameras: [("North", odd)], missing: 0, cluster: Array(usualRuns.prefix(3)), overall: usualRuns)
        XCTAssertEqual(flags.unusual.map(\.kpi), [.loadS])
        XCTAssertEqual(flags.unusual.first?.against.map(\.scope), [.overall], "the cluster's three runs say nothing")
        XCTAssertNil(RunFlags.usual([1, 2, 3], scope: .cluster, percent: false))
    }

    func testLeavesSmallDifferencesFromSteadyRunsAlone() {
        let steady = (0..<6).map { _ in run(loadS: 100, util: 90) }
        let near = run(loadS: 108, util: 94)
        XCTAssertTrue(RunFlags.of(total: near, cameras: [("North", near)], missing: 0, cluster: steady, overall: steady).unusual.isEmpty,
                      "8% and 4 points: outside the quartiles, but not far enough")
        let far = run(loadS: 115, util: 97)
        XCTAssertEqual(RunFlags.of(total: far, cameras: [("North", far)], missing: 0, cluster: steady, overall: steady).unusual.map(\.kpi),
                       [.loadS, .excavatorUtilPct])
    }

    func testChecksTheRunsOwnFootage() {
        let total = run(cycles: 10, estimated: 7)
        let cameras: [(name: String, figures: TeamFigures)] = [
            ("North", run(hours: 2, cycles: 10, estimated: 7)),
            ("Pit edge", run(hours: 2, cycles: 0, excavators: 0)),
            ("South", run(hours: 2, cycles: 0)),
            ("Ramp", run(hours: 0.5, cycles: 0, excavators: 1)),
        ]
        let flags = RunFlags.of(total: total, cameras: cameras, missing: 1, cluster: [], overall: [])
        XCTAssertEqual(flags.checks, [.camerasMissing(1), .noExcavator(["Pit edge"]), .noCycles(["South", "Ramp"]),
                                      .mostlyEstimated(estimated: 7, of: 10), .shortFootage(["Ramp"])])
        XCTAssertEqual(flags.count, 5)
    }

    func testFindsQuartilesAsASpreadsheetDoes() {
        XCTAssertEqual(RunFlags.quantile([1, 2, 3, 4], 0.25), 1.75)
        XCTAssertEqual(RunFlags.quantile([1, 2, 3, 4], 0.5), 2.5)
        XCTAssertEqual(RunFlags.quantile([7], 0.75), 7)
    }
}

/// The Dashboard's periods: a day, a week or a month holding the analyses.
final class PeriodTests: XCTestCase {
    func testGroupsDatesByDayWeekAndMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let f = ISO8601DateFormatter()
        let dates = ["2024-02-01T08:00:00Z", "2024-02-01T16:00:00Z", "2024-02-02T09:00:00Z", "2024-02-06T09:00:00Z", "2024-03-01T09:00:00Z"]
            .compactMap(f.date(from:))
        XCTAssertEqual(Period.holding(dates, .day, calendar: calendar).count, 4)
        let weeks = Period.holding(dates, .week, calendar: calendar)
        XCTAssertEqual(weeks.map { f.string(from: $0.start) }, ["2024-01-29T00:00:00Z", "2024-02-05T00:00:00Z", "2024-02-26T00:00:00Z"])
        XCTAssertEqual(Period.holding(dates, .month, calendar: calendar).count, 2)
        XCTAssertTrue(weeks[0].contains(dates[2]))
        XCTAssertFalse(weeks[0].contains(dates[3]))
        XCTAssertEqual(Period.holding(dates, .all, calendar: calendar), [.all])
        XCTAssertTrue(Period.all.contains(dates[4]))
    }

    func testComparesCountsAndShares() {
        let fewer = Comparison.Change.between(13_152, 17_373, inPoints: false, higherIsBetter: true)
        XCTAssertEqual(fewer?.by ?? 0, -24.3, accuracy: 0.05)
        XCTAssertEqual(fewer?.verdict, .worse)
        XCTAssertEqual(Comparison.Change.between(62, 58, inPoints: true, higherIsBetter: true)?.by, 4)
        XCTAssertEqual(Comparison.Change.between(10.1, 10, inPoints: false, higherIsBetter: nil)?.verdict, .same)
        XCTAssertNil(Comparison.Change.between(3, 0, inPoints: false, higherIsBetter: true))
    }
}

/// The team's definitions: the spreadsheet's trips and excavators, put together by metrics.py as the cluster step
/// does, give its Recording Overview, TOTAL row and Executive Summary.
final class SheetTests: XCTestCase {
    func testReproducesTheTeamsRecordingOverview() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sheet.json")
        let out = try temporaryFolder().appendingPathComponent("metrics.json")
        try Tool.run(python, ["-I", Library.metricsScript.path, "--rows", fixture.path, out.path])
        let got = try ClusterMetrics.decode(Data(contentsOf: out))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])["expected"] as! [String: Any]
        let rows = expected["rows"] as! [String: [String: Double]]
        XCTAssertEqual(got.cameras.count, 11)

        func check(_ f: TeamFigures, _ sheet: [String: Double], _ name: String) {
            let pairs: [(String, Double?)] = [
                ("cycles", Double(f.cycles)), ("observed", Double(f.observed)), ("estimated", Double(f.estimated)),
                ("load_s_mean", f.loadSMean), ("load_s_stdev", f.loadSStdev), ("queue_s_mean", f.queueSMean), ("queue_s_stdev", f.queueSStdev),
                ("excavator_idle_s_mean", f.excavatorIdleSMean), ("excavator_idle_s_stdev", f.excavatorIdleSStdev),
                ("truck_idle_s_mean", f.truckIdleSMean), ("truck_idle_s_stdev", f.truckIdleSStdev), ("volume_m3", f.volumeM3),
                ("volume_struck_m3", f.volumeStruckM3), ("volume_heaped_m3", f.volumeHeapedM3), ("excavators", Double(f.excavators)),
                // The sheet's shares are fractions, rounded to 3 places.
                ("excavator_util", f.excavatorUtilPct.map { $0 / 100 }), ("truck_util", f.truckUtilPct.map { $0 / 100 }),
            ]
            for (key, value) in pairs {
                guard let want = sheet[key] else { continue }
                let tolerance = key.hasSuffix("_util") ? 0.0011 : 0.051
                XCTAssertEqual(try XCTUnwrap(value, "\(name) \(key)"), want, accuracy: tolerance, "\(name) \(key)")
            }
        }
        for camera in got.cameras {
            check(camera.figures, try XCTUnwrap(rows[camera.name]), camera.name)
        }
        check(got.total, expected["total"] as! [String: Double], "TOTAL")

        let card = expected["summary"] as! [String: Double]
        let s = got.summary
        XCTAssertEqual(Double(s.cycles), card["cycles"])
        XCTAssertEqual(Double(s.observed), card["observed"])
        XCTAssertEqual(Double(s.estimated), card["estimated"])
        XCTAssertEqual(s.volumeM3, try XCTUnwrap(card["volume_m3"]), accuracy: 0.05)
        XCTAssertEqual(s.volumeObservedM3, try XCTUnwrap(card["volume_observed_m3"]), accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(s.loadSMean), try XCTUnwrap(card["load_s_mean"]), accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(s.loadSStdev), try XCTUnwrap(card["load_s_stdev"]), accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(s.loadSMedian), try XCTUnwrap(card["load_s_median"]), accuracy: 0.05)
        XCTAssertEqual(s.queueTotalS, try XCTUnwrap(card["queue_total_s"]), accuracy: 0.05)
        XCTAssertEqual(Double(s.queuedTrucks), card["queued_trucks"])
        // The card's 94.0% fits no definition the sheet's columns give (1 − idle ÷ camera window comes closest, at
        // 94.3%): the app keeps the Recording Overview's, every excavator's working over its time, pooled.
        XCTAssertEqual(card["excavator_util_pct"], 94.0)
        XCTAssertEqual(try XCTUnwrap(s.excavatorUtilPct), 96.3, accuracy: 0.05)
    }
}

/// Completing the cycles cut short: drawn from a Gaussian truncated to ±0.45 σ, the same each time.
final class ImputationTests: XCTestCase {
    func testDrawsTheSameLoadTimesWithinTheSpread() throws {
        let library = Library(root: try temporaryFolder())
        // Camera 1: its own complete loads (two, not the same). Camera 2: one complete load, so the cluster's.
        // Camera 3: a load seen longer than any drawn, which keeps what was seen.
        let cameras: [(Int64, complete: [Double], cut: [Double])] = [
            (1, [90, 110, 130], Array(repeating: 20, count: 40)),
            (2, [200], [30, 60, 150]),
            (3, [], [500]),
        ]
        for (id, complete, cut) in cameras {
            let cycles = (complete.map { ($0, true) } + cut.map { ($0, false) }).enumerated().map { k, c in
                ["point": "LP1", "truck": "T\(k)", "load_start_s": Double(k) * 300, "load_end_s": Double(k) * 300 + c.0, "wait_s": 0, "spot_s": 0,
                 "load_s": c.0, "complete": c.1] as [String: Any]
            }
            try write(["version": 2, "video": ["fps": 25, "every": 5, "duration_s": 3600], "observed_h": 1,
                       "excavators": [["point": "LP1", "seen_s": 3600, "working_s": 3000, "idle_s": 600]], "cycles": cycles],
                      to: library.analysis(id).appendingPathComponent("metrics.json"))
        }
        let names = cameras.map { ClusterRun.Camera(name: "Camera \($0.0)", analysis: $0.0) }
        let first = try ClusterRun.run(python: python, library: library, batch: 1, cameras: names, settings: Settings().forCluster())
        let again = try ClusterRun.run(python: python, library: library, batch: 1, cameras: names, settings: Settings().forCluster())
        XCTAssertEqual(first.json, again.json, "the same batch gives the same figures")

        let m = first.metrics
        XCTAssertEqual(m.cameras.map { $0.prior?.basis }, ["camera", "cluster", "cluster"])
        let own = try XCTUnwrap(m.cameras[0].prior)
        XCTAssertEqual(own.n, 3)
        XCTAssertEqual(try XCTUnwrap(own.mean), 110, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(own.low), 110 - 0.45 * 20, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(m.cameras[1].prior?.n), 4, "every complete load of the cluster")
        for camera in m.cameras {
            let p = try XCTUnwrap(camera.prior)
            for c in camera.cycles where c.isEstimated {
                let seen = try XCTUnwrap(c.seenLoadS), load = try XCTUnwrap(c.loadS)
                if seen >= p.high! {
                    XCTAssertEqual(load, seen, "\(camera.name): a load seen longer than any drawn keeps what was seen")
                } else {
                    XCTAssertGreaterThanOrEqual(load, max(p.low!, seen) - 0.05, camera.name)
                    XCTAssertLessThanOrEqual(load, p.high! + 0.05, camera.name)
                }
            }
        }
        // Drawn, not all the same.
        XCTAssertGreaterThan(Set(m.cameras[0].cycles.filter(\.isEstimated).compactMap(\.loadS)).count, 20)
        XCTAssertEqual(m.cameras[2].cycles.first?.loadS, 500)
        XCTAssertEqual(m.summary.observed, 4)
        XCTAssertEqual(m.summary.estimated, 44)
        // An estimated load's unseen part counts towards its excavator's working time and time in view.
        let extra = m.cameras[0].cycles.filter(\.isEstimated).reduce(0.0) { $0 + $1.loadS! - $1.seenLoadS! }
        XCTAssertEqual(m.cameras[0].excavators[0].seenS, 3600 + extra, accuracy: 0.5)
    }

    private func write(_ object: [String: Any], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }
}

final class ComparisonTests: XCTestCase {
    func testAveragesByTheHoursEachAnalysisHad() throws {
        let a = figures(hours: 1, cycles: 10, util: 80, queueS: 60)
        let b = figures(hours: 3, cycles: 18, util: 40, queueS: nil)
        let c = try XCTUnwrap(Comparison.of([a, b]))
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.hours, 4)
        XCTAssertEqual(c.average[.cyclesPerH], 7) // 28 cycles over 4 hours
        XCTAssertEqual(c.average[.excavatorUtilPct], 50)
        XCTAssertEqual(c.average[.queueS], 60) // only the analysis where trucks queued

        let now = figures(hours: 2, cycles: 16, util: 45, queueS: 90)
        let cycles = try XCTUnwrap(c.change(.cyclesPerH, now))
        XCTAssertEqual(cycles.by, 100.0 * (8 - 7) / 7, accuracy: 1e-9)
        XCTAssertEqual(cycles.verdict, .better)
        XCTAssertEqual(c.change(.excavatorUtilPct, now)?.by, -5)
        XCTAssertEqual(c.change(.excavatorUtilPct, now)?.inPoints, true)
        XCTAssertEqual(c.change(.excavatorUtilPct, now)?.verdict, .worse)
        XCTAssertEqual(c.change(.queueS, now)?.verdict, .worse)
        XCTAssertNil(Comparison.of([]))
    }

    private func figures(hours: Double, cycles: Int, util: Double, queueS: Double?) -> TeamFigures {
        TeamFigures(durationH: hours, cycles: cycles, observed: cycles, estimated: 0, queueSMean: queueS, volumeM3: Double(cycles) * 51.1,
                    excavatorUtilPct: util)
    }
}

final class OverviewTests: XCTestCase {
    func testAddsUpAndAveragesBatches() throws {
        func metrics(hours: Double, observed: Int, estimated: Int, util: Double) throws -> ClusterMetrics {
            let n = observed + estimated
            let row = """
            {"duration_h": \(hours), "cycles": \(n), "observed": \(observed), "estimated": \(estimated), "volume_m3": \(Double(n) * 51.1),
             "volume_struck_m3": 0, "volume_heaped_m3": 0, "excavator_util_pct": \(util), "excavators": 1, "trucks": \(n)}
            """
            let json = """
            {"version": 2, "settings": {"m3_per_load": 51.1}, "spread": 0.45, "cameras": [], "total": \(row),
             "summary": {"cycles": \(n), "observed": \(observed), "estimated": \(estimated), "volume_m3": 0, "volume_observed_m3": 0,
                         "volume_struck_m3": 0, "volume_heaped_m3": 0, "m3_per_load": 51.1, "queue_total_s": 0, "queued_trucks": 0,
                         "camera_h": \(hours * 2)}}
            """
            return try ClusterMetrics.decode(Data(json.utf8))
        }
        let o = Overview.of([try metrics(hours: 1, observed: 6, estimated: 4, util: 80), try metrics(hours: 3, observed: 18, estimated: 0, util: 40)])
        XCTAssertEqual(o.analyses, 2)
        XCTAssertEqual(o.cycles, 28)
        XCTAssertEqual(o.observed, 24)
        XCTAssertEqual(o.estimated, 4)
        XCTAssertEqual(o.hours, 4)
        XCTAssertEqual(o.cameraH, 8)
        XCTAssertEqual(o.volumeM3, 28 * 51.1, accuracy: 1e-9)
        XCTAssertEqual(o.average?.average[.cyclesPerH], 7)
        XCTAssertEqual(o.average?.average[.excavatorUtilPct], 50)
        XCTAssertNil(Overview.of([]).average)
    }
}

/// A runner that writes made-up outputs the way the labeler's does, then metrics.py on them.
final class RunTests: XCTestCase {
    func testRunsABundleAndFindsItsCycles() async throws {
        let dir = try temporaryFolder()
        let runner = try fakeRunner(in: dir.appendingPathComponent("runner"), code: oneExcavator)
        let folder = dir.appendingPathComponent("analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("ch01_20240202160056.mp4")
        try Data().write(to: video)
        let lines = Lines()
        let run = PipelineRun(runner: runner, pipeline: try pipelineFile(in: folder), requirements: nil, video: video, out: folder.appendingPathComponent("out"),
                              start: "2024-02-02 16:00:56", device: "cpu", venv: dir.appendingPathComponent("venv"), python: python,
                              log: folder.appendingPathComponent("run.log"))
        try await run.run { lines.add($0) }

        var reader = ProgressReader()
        let progress = lines.all.compactMap { reader.read($0) }
        XCTAssertEqual(progress.compactMap(\.fraction), [0, 0.5, 1])
        XCTAssertEqual(progress.last?.stage, "Loading events")
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("run.log"), encoding: .utf8).contains("analysed 120 frames"))

        let pipeline = Pipeline(id: 1, name: "Loading", nodes: [], reportFile: "report.csv", eventsFile: "events.csv", importedAt: Date())
        let (metrics, _) = try MetricsRun.run(python: python, out: folder.appendingPathComponent("out"),
                                              settings: Settings().forMetrics(start: "2024-02-02 16:00:56", pipeline: pipeline), folder: folder)
        XCTAssertEqual(metrics.video.start, "2024-02-02 16:00:56")
        XCTAssertEqual(metrics.video.durationS, 1200)
        XCTAssertEqual(metrics.observedH, 0.333, accuracy: 0.001)
        XCTAssertEqual(metrics.cycles.map(\.loadS), [300, 300, 300])
        XCTAssertEqual(metrics.cycles.map(\.complete), [true, true, true])
        // Truck 8 came at 300 s, moved into place for the last 20 s of its wait, and was loaded from 400 s.
        let second = metrics.cycles[1]
        XCTAssertEqual(second.arriveS, 300)
        XCTAssertEqual(second.spotAtS, 380)
        XCTAssertEqual(second.waitS, 80)
        XCTAssertEqual(second.spotS, 20)
        XCTAssertNil(metrics.cycles[0].arriveS, "no wait seen before the first")
        XCTAssertEqual(metrics.cycles[0].waitS, 0)
        XCTAssertEqual(metrics.excavators.map(\.point), ["LP1"])
        XCTAssertEqual(metrics.excavators.first?.workingS, 900)
        XCTAssertEqual(metrics.excavators.first?.idleS, 300)
    }

    func testStopsARunWhenCancelled() async throws {
        let dir = try temporaryFolder()
        let runner = try fakeRunner(in: dir.appendingPathComponent("runner"),
                                    code: "import time\nprint('Detect: 60 s of video, 1 frame in 1', flush=True)\ntime.sleep(30)\n")
        let run = PipelineRun(runner: runner, pipeline: try pipelineFile(in: dir), requirements: nil, video: dir.appendingPathComponent("v.mp4"),
                              out: dir.appendingPathComponent("out"), start: nil, device: "cpu", venv: dir.appendingPathComponent("venv"), python: python,
                              log: dir.appendingPathComponent("run.log"))
        let began = Date()
        let task = Task { try await run.run { _ in } }
        try await Task.sleep(for: .milliseconds(700))
        task.cancel()
        do {
            try await task.value
            XCTFail("It ran to the end")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(began), 10)
        }
    }

    func testSaysWhyARunFailed() async throws {
        let dir = try temporaryFolder()
        let runner = try fakeRunner(in: dir.appendingPathComponent("runner"),
                                    code: "import sys\nprint('Detect failed on frame 12:', file=sys.stderr)\nraise SystemExit(1)\n")
        let run = PipelineRun(runner: runner, pipeline: try pipelineFile(in: dir), requirements: nil, video: dir.appendingPathComponent("v.mp4"),
                              out: dir.appendingPathComponent("out"), start: nil, device: "cpu", venv: dir.appendingPathComponent("venv"), python: python,
                              log: dir.appendingPathComponent("run.log"))
        do {
            try await run.run { _ in }
            XCTFail("It did not fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Detect failed on frame 12"), error.localizedDescription)
        }
    }

    /// Results whose tables have other names (a run elsewhere named them) are found by their columns.
    func testFindsTablesByTheirColumns() async throws {
        let dir = try temporaryFolder()
        let runner = try fakeRunner(in: dir.appendingPathComponent("runner"), code: oneExcavator)
        let folder = dir.appendingPathComponent("analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let run = PipelineRun(runner: runner, pipeline: try pipelineFile(in: folder), requirements: nil, video: folder.appendingPathComponent("ch01.mp4"),
                              out: folder.appendingPathComponent("out"), start: "2024-02-02 16:00:56", device: "cpu", venv: dir.appendingPathComponent("venv"),
                              python: python, log: folder.appendingPathComponent("run.log"))
        try await run.run { _ in }
        let written = folder.appendingPathComponent("out/ch01__Loading")
        try FileManager.default.moveItem(at: written.appendingPathComponent("report.csv"), to: written.appendingPathComponent("loads.csv"))
        try FileManager.default.moveItem(at: written.appendingPathComponent("events.csv"), to: written.appendingPathComponent("waits.csv"))
        let (metrics, _) = try MetricsRun.run(python: python, out: folder.appendingPathComponent("out"), settings: Settings().forMetrics(start: nil), folder: folder)
        XCTAssertEqual(metrics.cycles.count, 3)
    }

    /// A video none of whose frames were analysed is a camera that failed, said plainly, not one that saw nothing.
    func testFailsAVideoWithNoFrameAnalysed() throws {
        let folder = try temporaryFolder()
        let out = folder.appendingPathComponent("out/v__ovius", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try #"{"video_fps": 10, "every": 1, "count": 0, "activities": ["unknown"], "frame": [], "id": [], "activity": []}"#
            .write(to: out.appendingPathComponent("review.json"), atomically: true, encoding: .utf8)
        try "loading_point,excavator_ids\nall,\n".write(to: out.appendingPathComponent("report.csv"), atomically: true, encoding: .utf8)
        try "kind,point,truck,start,end,start_s,end_s,duration_s,spot_s,complete\n".write(to: out.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MetricsRun.run(python: python, out: folder.appendingPathComponent("out"), settings: Settings().forMetrics(start: nil), folder: folder)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No frame of the video was analysed"), error.localizedDescription)
        }
    }

    /// With a state model, each excavator's time in each of its states; its idle states are idle in the figures.
    func testKeepsEachExcavatorsStates() throws {
        let folder = try temporaryFolder()
        let out = folder.appendingPathComponent("out/v__ovius", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A frame a second for 1200 s: digging, swinging, then idle, 600, 300 and 300 frames; a truck (ID 2) passes.
        let acts = ["working", "idle", "moving", "unknown", "state:digging", "state:swinging", "state:idle"]
        let own = Array(repeating: 4, count: 600) + Array(repeating: 5, count: 300) + Array(repeating: 6, count: 300)
        let coarse = own.map { $0 == 6 ? 1 : 0 }
        let review: [String: Any] = [
            "video_fps": 1, "every": 1, "count": 1200, "activities": acts,
            "frame": Array(0..<1200) + [5], "id": Array(repeating: 1, count: 1200) + [2],
            "activity": own + [2], "coarse": coarse + [2],
        ]
        try JSONSerialization.data(withJSONObject: review).write(to: out.appendingPathComponent("review.json"))
        try "loading_point,excavator_ids,working_pct\nLP1,E1,75.0\n".write(to: out.appendingPathComponent("report.csv"), atomically: true, encoding: .utf8)
        try "kind,point,truck,start,end,start_s,end_s,duration_s,spot_s,complete\nloading,LP1,T2,,,100,300,200,0.0,True\n"
            .write(to: out.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
        let pipeline = Pipeline(id: 1, name: "Built-in", nodes: [], reportFile: "report.csv", eventsFile: "events.csv", importedAt: Date())
        let (metrics, _) = try MetricsRun.run(python: python, out: folder.appendingPathComponent("out"),
                                              settings: Settings().forMetrics(start: nil, pipeline: pipeline), folder: folder)
        let e = try XCTUnwrap(metrics.excavators.first)
        XCTAssertEqual(e.workingS, 900)
        XCTAssertEqual(e.idleS, 300)
        XCTAssertEqual(e.states, [.init(state: "digging", s: 600), .init(state: "idle", s: 300), .init(state: "swinging", s: 300)])
    }

    /// One excavator at LP1 for 1200 s (a frame a second): loading three trucks, 0–300, 400–700 and 800–1100 s,
    /// each of the last two waited for 100 s, then idle with no truck to the end.
    private let oneExcavator = runner(loads: [(7, 0, 300, true), (8, 400, 700, true), (9, 800, 1100, true)], waits: [(8, 300, 400, 20), (9, 700, 800, 20)])
}

/// A cluster's batch from start to finish, as the app runs it: each camera's video through the runner and metrics.py,
/// one after another, then the cluster step once every camera is over.
final class BatchFlowTests: XCTestCase {
    func testRunsABatchThenWorksOutTheCluster() async throws {
        let (store, library, batch, analyses) = try await runBatch(cameras: ["North", "South"])
        let b = try XCTUnwrap(store.batch(batch))
        XCTAssertEqual(b.state(of: try store.analyses(of: batch)), .done)
        let m = try XCTUnwrap(b.metrics)
        XCTAssertEqual(m.cameras.map(\.name), ["North", "South"])
        XCTAssertEqual(m.cameras.map(\.analysis), analyses)
        // North: three loads, the first cut by the video's start. South: two, the last cut by its end.
        XCTAssertEqual(m.cameras.map(\.figures.cycles), [3, 2])
        XCTAssertEqual(m.cameras.map(\.figures.observed), [2, 1])
        XCTAssertEqual(m.cameras.map(\.figures.estimated), [1, 1])
        XCTAssertEqual(m.total.cycles, 5)
        XCTAssertEqual(m.total.volumeM3, 5 * 51.1, accuracy: 0.05)
        XCTAssertEqual(m.total.volumeStruckM3, 5 * 42.1, accuracy: 0.05)
        XCTAssertEqual(m.summary.volumeObservedM3, 3 * 51.1, accuracy: 0.05)
        XCTAssertEqual(m.total.durationH, 1200.0 / 3600, accuracy: 0.001)
        XCTAssertEqual(m.summary.cameraH, 2400.0 / 3600, accuracy: 0.001)
        // North has two complete loads of its own (250 and 300 s); South one, so the cluster's three.
        XCTAssertEqual(m.cameras.map { $0.prior?.basis }, ["camera", "cluster"])
        for camera in m.cameras {
            let p = try XCTUnwrap(camera.prior)
            let estimated = try XCTUnwrap(camera.cycles.first(where: \.isEstimated))
            XCTAssertGreaterThanOrEqual(estimated.loadS!, max(p.low!, estimated.seenLoadS!) - 0.05)
            XCTAssertLessThanOrEqual(estimated.loadS!, p.high! + 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.batch(batch).appendingPathComponent("cluster.json").path))
    }

    func testAPartialFailureKeepsTheOtherCameras() async throws {
        let (store, _, batch, _) = try await runBatch(cameras: ["North", "Broken", "South"])
        let b = try XCTUnwrap(store.batch(batch))
        let analyses = try store.analyses(of: batch)
        XCTAssertEqual(analyses.map(\.status), [.done, .failed, .done])
        XCTAssertTrue(analyses[1].error?.contains("lens is covered") == true)
        XCTAssertEqual(b.state(of: analyses), .partial(missing: 1))
        XCTAssertEqual(b.metrics?.cameras.map(\.name), ["North", "South"])
        XCTAssertEqual(b.metrics?.total.cycles, 5)
    }

    func testABatchsStateFollowsItsCameras() throws {
        let batch = Batch(id: 1, clusterID: 1, pipelineID: 1, metrics: nil, error: nil, createdAt: Date(), finishedAt: nil)
        func analyses(_ statuses: [Status]) -> [Analysis] {
            statuses.enumerated().map { k, s in
                Analysis(id: Int64(k), batchID: 1, cameraID: Int64(k), pipelineID: 1, videoName: "v", start: nil, status: s, error: nil,
                         metrics: nil, createdAt: Date(), finishedAt: nil)
            }
        }
        XCTAssertEqual(batch.state(of: analyses([.copying, .queued])), .copying)
        XCTAssertEqual(batch.state(of: analyses([.done, .running, .queued])), .running(over: 1, of: 3))
        XCTAssertEqual(batch.state(of: analyses([.done, .failed])), .figuring)
        XCTAssertEqual(batch.state(of: analyses([.failed, .cancelled])), .failed)
        XCTAssertEqual(batch.state(of: analyses([.cancelled])), .stopped)
        XCTAssertFalse(Batch.ready(analyses([.done, .running])))
        XCTAssertFalse(Batch.ready(analyses([.failed, .cancelled])))
        XCTAssertTrue(Batch.ready(analyses([.done, .cancelled])))
        var failed = batch
        failed.error = "metrics.py failed"
        XCTAssertEqual(failed.state(of: analyses([.done])), .failed)
    }

    /// A library with a cluster of `cameras`, a batch of one video each, run one after another; the cluster step once
    /// they are all over.
    private func runBatch(cameras: [String]) async throws -> (Store, Library, Int64, [Int64]) {
        let library = Library(root: try temporaryFolder())
        try library.make()
        let store = Store(try Database(path: library.database.path))
        let pipelineID = try store.addPipeline(name: "Loading", nodes: ["Video", "Loading events"], reportFile: "report.csv", eventsFile: "events.csv")
        let pipeline = try XCTUnwrap(store.read().pipelines.first)
        let runner = try fakeRunner(in: library.root.appendingPathComponent("runner"), code: clusterRunner)
        let cluster = try store.cluster(site: "Pit 3", name: "Section Alpha")
        let videos = try cameras.map { name in
            Store.NewVideo(camera: try store.camera(cluster: cluster.id, name: name).id, videoName: "\(name.lowercased())_20240202160000.mp4",
                           start: CameraClock.fromFileName("\(name)_20240202160000.mp4"))
        }
        let (batch, ids) = try store.addBatch(cluster: cluster.id, pipeline: pipelineID, videos: videos, status: .queued)
        for (k, id) in ids.enumerated() {
            let analysis = try XCTUnwrap(store.analysis(id))
            let folder = library.analysis(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent(analysis.videoName))
            try store.set(id, status: .running)
            do {
                let run = PipelineRun(runner: runner, pipeline: try pipelineFile(in: folder), requirements: nil,
                                      video: folder.appendingPathComponent(analysis.videoName), out: folder.appendingPathComponent("out"),
                                      start: analysis.start, device: "cpu", venv: library.venv, python: python,
                                      log: folder.appendingPathComponent("run.log"))
                try await run.run { _ in }
                let json = try MetricsRun.run(python: python, out: folder.appendingPathComponent("out"),
                                              settings: Settings().forMetrics(start: analysis.start, pipeline: pipeline), folder: folder).json
                try store.set(id, status: .done, metrics: json)
            } catch {
                try store.set(id, status: .failed, error: error.localizedDescription)
            }
            let now = try store.analyses(of: batch)
            if k < ids.count - 1 {
                XCTAssertFalse(Batch.ready(now))
                XCTAssertEqual(try XCTUnwrap(store.batch(batch)).state(of: now), .running(over: k + 1, of: ids.count))
            }
        }
        let over = try store.analyses(of: batch)
        XCTAssertTrue(Batch.ready(over))
        let names = Dictionary(uniqueKeysWithValues: try store.read().cameras.map { ($0.id, $0.name) })
        let done = over.filter { $0.status == .done }.map { ClusterRun.Camera(name: names[$0.cameraID]!, analysis: $0.id) }
        let json = try ClusterRun.run(python: python, library: library, batch: batch, cameras: done, settings: Settings().forCluster()).json
        try store.setFigures(of: batch, metrics: json, error: nil)
        return (store, library, batch, ids)
    }

    /// North: one excavator loading three trucks, the first already loading when the video starts. South: two, the
    /// second still loading when it ends. Broken: the runner fails.
    private let clusterRunner = """
    import sys, pathlib
    stem = pathlib.Path(sys.argv[1]).stem
    if stem.startswith("broken"):
        print("Detect: the lens is covered", file=sys.stderr)
        raise SystemExit(1)
    LOADS, WAITS = {
        "north": ([(7, 0, 120, False), (8, 400, 650, True), (9, 800, 1100, True)], [(8, 300, 400, 20), (9, 700, 800, 20)]),
        "south": ([(3, 100, 250, True), (4, 1000, 1200, False)], [(4, 900, 1000, 15)]),
    }[stem.split("_")[0]]

    """ + runnerBody
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

private let python = URL(fileURLWithPath: "/usr/bin/python3")

/// run.sh as the built-in one ends (exec python run_pipeline.py "$@"), without making a venv, in `folder`, with `code` as
/// run_pipeline.py.
private func fakeRunner(in folder: URL, code: String) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "#!/bin/bash\nset -eo pipefail\nhere=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\nexec \"$OVIUS_PYTHON\" \"$here/run_pipeline.py\" \"$@\"\n"
        .write(to: folder.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
    try code.write(to: folder.appendingPathComponent("run_pipeline.py"), atomically: true, encoding: .utf8)
    return folder
}

/// The built-in pipeline.json, as the app writes one for each camera's run.
private func pipelineFile(in folder: URL) throws -> URL {
    let detector = Detector(name: "S-v3", classes: ["excavator", "dumptruck"], spec: folder.appendingPathComponent("detector.json"), needs: [])
    let file = folder.appendingPathComponent("pipeline.json")
    try JSONSerialization.data(withJSONObject: BuiltInPipeline.spec(detector: detector, states: nil, settings: Settings())).write(to: file)
    return file
}

/// A labeler runner that writes, for a 1200 s video (a frame a second), one excavator at LP1 working through
/// `loads` (truck, start, end, seen whole) and the `waits` (truck, start, end, spotting) before them.
private func runner(loads: [(Int, Int, Int, Bool)], waits: [(Int, Int, Int, Int)]) -> String {
    let py = { (t: (Int, Int, Int, Bool)) in "(\(t.0), \(t.1), \(t.2), \(t.3 ? "True" : "False"))" }
    return "LOADS = [\(loads.map(py).joined(separator: ", "))]\nWAITS = [\(waits.map { "(\($0.0), \($0.1), \($0.2), \($0.3))" }.joined(separator: ", "))]\n"
        + runnerBody
}

private let runnerBody = #"""
import argparse, csv, json, pathlib
p = argparse.ArgumentParser()
p.add_argument("video"); p.add_argument("--pipeline"); p.add_argument("--out"); p.add_argument("--review", action="store_true")
p.add_argument("--device"); p.add_argument("--start")
a = p.parse_args()
assert a.review and a.device == "cpu" and a.start in ("2024-02-02 16:00:56", "2024-02-02 16:00:00"), a
assert [n["kind"] for n in json.load(open(a.pipeline))["nodes"]][-2:] == ["loading_events", "productivity_report"], a.pipeline
print("Detect, Track: 1200 s of video, 1 frame in 10", flush=True)
print("   600 s of video | 60 frames | 30.0 frames/s", flush=True)
print("analysed 120 frames in 4 s")
print("running Loading events (loading)")
out = pathlib.Path(a.out) / (pathlib.Path(a.video).stem[:40] + "__Loading")
out.mkdir(parents=True)
working = lambda t: any(s <= t < e for _, s, e, _ in LOADS)
acts = ["working", "idle", "unknown"]
frames = list(range(0, 12000, 10))
review = {"video_fps": 10, "every": 10, "count": len(frames), "activities": acts, "frame": frames, "id": [1] * len(frames),
          "activity": [0 if working(f / 10) else 1 for f in frames]}
(out / "review.json").write_text(json.dumps(review))
with open(out / "report.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["loading_point", "excavator_ids", "working_pct", "loading_min_median", "exchange_s_median"])
    w.writerow(["LP1", "E1", "75.0", "5.0", "100"])
    w.writerow(["all", "E1", "75.0", "5.0", "100"])
with open(out / "events.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["kind", "point", "truck", "start", "end", "start_s", "end_s", "duration_s", "spot_s", "complete"])
    for truck, s, e, whole in LOADS:
        w.writerow(["loading", "LP1", f"T{truck}", "", "", s, e, e - s, "0.0", whole])
    for truck, s, e, spot in WAITS:
        w.writerow(["queue", "LP1", f"T{truck}", "", "", s, e, e - s, spot, True])
"""#

func temporaryFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ovius-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

final class ResultsFolderTests: XCTestCase {
    func testFindsTheReportsTablesByTheirColumns() throws {
        let dir = try temporaryFolder()
        try "{}".write(to: dir.appendingPathComponent("review.json"), atomically: true, encoding: .utf8)
        try "loading_point,excavator_ids\nLP1,E2\n".write(to: dir.appendingPathComponent("loads.csv"), atomically: true, encoding: .utf8)
        try "frame,seg,id\n".write(to: dir.appendingPathComponent("boxes.csv"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ResultsFolder.read(dir))
        try "kind,point,truck,start\n".write(to: dir.appendingPathComponent("waits.csv"), atomically: true, encoding: .utf8)
        let files = try ResultsFolder.read(dir)
        XCTAssertEqual(files.reportFile, "loads.csv")
        XCTAssertEqual(files.eventsFile, "waits.csv")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("review.json"))
        XCTAssertThrowsError(try ResultsFolder.read(dir)) { XCTAssertTrue($0.localizedDescription.contains("review.json")) }
    }
}
