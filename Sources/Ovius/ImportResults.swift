import OviusCore
import Foundation
import SwiftUI

/// Results a pipeline wrote elsewhere, a folder per camera, as one run of a cluster: the cluster, and each folder's
/// camera and start.
struct ImportResultsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folders: [URL]
    /// The cluster to start with, as the sidebar had it.
    let clusterID: Int64?
    /// Opens the new analysis.
    let added: (Int64) -> Void

    @State private var place = ClusterChoice()
    @State private var items: [Footage] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ClusterSection(choice: $place)
                Section {
                    FootageRows(items: $items, clusterID: place.cluster)
                } header: {
                    Text("Results")
                } footer: {
                    Text("A folder per camera of the cluster, covering the same period: what a pipeline wrote, its report, its events and review.json. They are copied into the library; the videos are not.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                if let problem = Footage.problem(items, choice: place, model: model) {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(items.count > 1 ? "Import \(items.count) Results as One Run" : "Import Results") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Footage.problem(items, choice: place, model: model) != nil)
            }
            .padding(16)
        }
        .frame(width: 780, height: 560)
        .onChange(of: place.cluster) { _, cluster in Footage.assign(&items, in: cluster, model: model, again: true) }
        .onAppear {
            place.cluster = clusterID ?? model.clusters.first?.id
            items = folders.map { Footage(url: $0, start: CameraClock.fromFileName($0.lastPathComponent) ?? "") }
            Footage.assign(&items, in: place.cluster, model: model)
        }
    }

    private func add() {
        let access = folders.map { $0.startAccessingSecurityScopedResource() }
        defer { for (folder, on) in zip(folders, access) where on { folder.stopAccessingSecurityScopedResource() } }
        do {
            let cluster = try place.resolve(model)
            let imports = try items.map { item in
                ResultsImport(folder: item.url, camera: try item.resolve(in: cluster, model: model).name, start: CameraClock.parse(item.start))
            }
            added(try model.importResults(imports, cluster: cluster))
            dismiss()
        } catch {
            model.alert = error.localizedDescription
        }
    }
}

/// `Ovius --cluster CLUSTER --import-results FOLDER [--camera NAME] [--start TIME] [--video NAME]
/// [--import-results FOLDER …]`: imports a folder of results per camera into the library, as one run of the cluster,
/// without opening a window. A folder's camera is named after its video when not given.
@MainActor
enum ImportCommand {
    static func run(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let clusterName = value("--cluster") else {
            FileHandle.standardError.write(Data("usage: Ovius --cluster CLUSTER --import-results FOLDER [--camera NAME] [--start TIME] [--video NAME] [--import-results FOLDER ...]\n".utf8))
            exit(2)
        }
        let model = AppModel(runQueue: false)
        do {
            if let alert = model.alert { throw OviusError(message: alert) }
            // Each --import-results starts a folder; the --camera, --start and --video after it are its own.
            var items: [ResultsImport] = []
            var k = 0
            while k < args.count {
                let flag = args[k], next = k + 1 < args.count ? args[k + 1] : nil
                switch (flag, next) {
                case ("--import-results", let folder?):
                    let url = URL(fileURLWithPath: folder, isDirectory: true)
                    items.append(ResultsImport(folder: url, camera: Footage.cameraName(from: url), start: CameraClock.fromFileName(url.lastPathComponent)))
                case ("--camera", let name?) where !items.isEmpty:
                    items[items.count - 1].camera = name
                case ("--start", let typed?) where !items.isEmpty:
                    guard let clock = CameraClock.parse(typed) else { throw OviusError(message: "--start is not a time like 2024-02-02 16:00:56") }
                    items[items.count - 1].start = clock
                case ("--video", let name?) where !items.isEmpty:
                    items[items.count - 1].videoName = name
                case ("--site", _?), ("--pipeline", _?):
                    break  // no longer told apart; taken for the commands written before
                default:
                    k -= 1
                }
                k += 2
            }
            let cluster = try model.cluster(named: clusterName)
            let id = try model.importResults(items, cluster: cluster)
            let batch = model.batch(id)
            print("Imported \(items.count) \(items.count == 1 ? "folder" : "folders") as run \(id) of \(cluster.name)"
                  + (batch?.metrics.map { ": \($0.total.cycles) cycles (\($0.total.observed) observed, \($0.total.estimated) estimated)" } ?? ""))
            if let alert = model.alert { FileHandle.standardError.write(Data("\(alert)\n".utf8)) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

/// `Ovius --detector PATH`, `--state-model PATH`, `--no-state-model`, `--print-pipeline`: sets the built-in
/// pipeline's models in the library, or prints the pipeline.json a new analysis would run, without opening a window.
@MainActor
enum ModelCommand {
    static let flags = ["--detector", "--state-model", "--no-state-model", "--print-pipeline"]

    static func run(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let library = Library.standard()
        do {
            try library.make()
            if let path = value("--detector") {
                let d = try Models.importDetector(URL(fileURLWithPath: path), into: library)
                print("Detector: \(d.name) (\(d.classes.joined(separator: ", ")))" + (d.needs.isEmpty ? "" : "; its preprocessing also needs \(d.needs.joined(separator: ", "))"))
            }
            if args.contains("--no-state-model") {
                try Models.removeStateModel(from: library)
                print("No state model: excavators are working or idle by how they move.")
            }
            if let path = value("--state-model") {
                let m = try Models.importStateModel(URL(fileURLWithPath: path), into: library)
                print("State model: \(m.name) (\(m.kind.rawValue))" + (m.states.isEmpty ? "" : ": \(m.states.joined(separator: ", "))"))
            }
            if args.contains("--print-pipeline") {
                guard let detector = Models.detector(in: library) else { throw OviusError(message: "No detector yet: set one with --detector.") }
                let settings = (try? Store(Database(path: library.database.path)).read().settings) ?? Settings()
                let spec = BuiltInPipeline.spec(detector: detector, states: Models.stateModel(in: library), settings: settings)
                let data = try JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
