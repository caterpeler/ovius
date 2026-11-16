import OviusCore
import SwiftUI
import UniformTypeIdentifiers

/// A cluster's footage to analyse: the cluster, a video from each of its cameras (copied into the library) with the
/// camera's clock at its start. The built-in pipeline runs on each.
struct NewAnalysisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The cluster to start with, as the sidebar had it.
    let clusterID: Int64?
    /// Opens the new analysis.
    let added: (Int64) -> Void

    @State private var place = ClusterChoice()
    @State private var videos: [Footage] = []
    @State private var picking = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ClusterSection(choice: $place)
                Section {
                    FootageRows(items: $videos, clusterID: place.cluster)
                    Button("Choose Videos…") { picking = true }
                } header: {
                    Text("Footage")
                } footer: {
                    Text("A video from each camera of the cluster, covering the same period. Each is copied into the library. Its start is the camera's clock at the first frame, read from the file name where the recorder wrote it; type it where it was not.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    if let detector = model.detector {
                        LabeledContent("Detector", value: detector.name)
                        LabeledContent("Excavator states", value: model.stateModel?.name ?? "Working or idle, by how they move")
                    } else {
                        Text(model.cannotAnalyse ?? "")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text(model.stateModel.map { "Each excavator's states come from \($0.name)." }
                         ?? "Excavators are working or idle by how they move, which every figure needs. A state model (Settings) adds their states: digging, swinging, loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let problem = Footage.problem(videos, choice: place, model: model) {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(videos.count > 1 ? "Analyse \(videos.count) Videos" : "Analyse Video") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Footage.problem(videos, choice: place, model: model) != nil || model.cannotAnalyse != nil)
            }
            .padding(16)
        }
        .frame(width: 780, height: 600)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.movie, .video], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls where !videos.contains(where: { $0.url == url }) {
                videos.append(Footage(url: url, start: CameraClock.fromFileName(url.lastPathComponent) ?? ""))
            }
            Footage.assign(&videos, in: place.cluster, model: model)
        }
        .onChange(of: place.cluster) { _, cluster in Footage.assign(&videos, in: cluster, model: model, again: true) }
        .onAppear {
            place.cluster = clusterID ?? model.batches.first?.clusterID ?? model.clusters.first?.id
        }
    }

    private func add() {
        do {
            let cluster = try place.resolve(model)
            let picked = try videos.map { v in
                NewVideo(url: v.url, camera: try v.resolve(in: cluster, model: model), start: CameraClock.parse(v.start))
            }
            if let id = model.add(cluster: cluster, videos: picked) { added(id) }
            dismiss()
        } catch {
            model.alert = error.localizedDescription
        }
    }
}

/// A cluster picked, or a new one's name.
struct ClusterChoice: Equatable {
    /// nil for a new one.
    var cluster: Int64?
    var newName = ""

    var isComplete: Bool {
        cluster != nil || !newName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @MainActor func resolve(_ model: AppModel) throws -> Cluster {
        try cluster.flatMap(model.cluster) ?? model.cluster(named: newName)
    }
}

struct ClusterSection: View {
    @Environment(AppModel.self) private var model
    @Binding var choice: ClusterChoice

    var body: some View {
        Section {
            Picker("Cluster", selection: $choice.cluster) {
                ForEach(model.clusters) { cluster in
                    Text(model.clusterTitle(cluster.id)).tag(Optional(cluster.id))
                }
                if !model.clusters.isEmpty { Divider() }
                Text("New Cluster…").tag(Int64?.none)
            }
            if choice.cluster == nil {
                TextField("Name", text: $choice.newName, prompt: Text("Section Alpha"))
            }
        } header: {
            Text("Cluster")
        } footer: {
            Text("A section of the mine whose cameras each watch a different part of it, none overlapping.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A video (or a folder of results) for one camera of the cluster, and the camera's clock at its start.
struct Footage: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    /// One of the cluster's cameras, or nil for a new one called `newCamera`.
    var camera: Int64?
    var newCamera = ""
    var start: String

    /// A camera's name from a recorder's file name, or the runner's folder (video__pipeline): without its date and
    /// time. "ch01_20240202160056.mp4" → "ch01".
    static func cameraName(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent.components(separatedBy: "__").first ?? url.lastPathComponent
        let bare = stem.replacing(#/[-_. ]*\d{4}[-_.]?\d{2}[-_.]?\d{2}[-_. T]?\d{2}[-_.:]?\d{2}[-_.:]?\d{2}/#, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        return bare.isEmpty ? stem : bare
    }

    /// Gives each item without a camera (every item, `again`) the cluster's camera its file is named after, else a
    /// new camera of that name.
    @MainActor static func assign(_ items: inout [Footage], in cluster: Int64?, model: AppModel, again: Bool = false) {
        let cameras = model.cameras.filter { $0.clusterID == cluster }
        var taken = Set(items.filter { !again && $0.camera != nil }.compactMap(\.camera))
        for k in items.indices where again || (items[k].camera == nil && items[k].newCamera.isEmpty) {
            let name = cameraName(from: items[k].url)
            let match = cameras.first { c in !taken.contains(c.id) && (c.name.caseInsensitiveCompare(name) == .orderedSame
                || items[k].url.lastPathComponent.localizedCaseInsensitiveContains(c.name)) }
            items[k].camera = match?.id
            items[k].newCamera = match == nil ? name : ""
            if let match { taken.insert(match.id) }
        }
    }

    /// Why the items cannot be analysed as they are; nil when they can.
    @MainActor static func problem(_ items: [Footage], choice: ClusterChoice, model: AppModel) -> String? {
        if items.isEmpty { return "Add a video from each camera." }
        if !choice.isComplete { return "Name the new cluster." }
        if items.contains(where: { $0.camera == nil && $0.newCamera.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Name each new camera."
        }
        if items.contains(where: { !$0.startIsValid }) { return "Write a start as 2024-02-02 16:00:56, or leave it empty." }
        let cameras = model.cameras.filter { $0.clusterID == choice.cluster }
        let keys = items.map { item -> String in
            if let id = item.camera { return "\(id)" }
            let name = item.newCamera.trimmingCharacters(in: .whitespaces)
            return cameras.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map { "\($0.id)" } ?? name.lowercased()
        }
        if Set(keys).count < keys.count { return "Two videos have one camera: an analysis takes one video per camera." }
        return nil
    }

    var startIsValid: Bool {
        start.trimmingCharacters(in: .whitespaces).isEmpty || CameraClock.parse(start) != nil
    }

    @MainActor func resolve(in cluster: Cluster, model: AppModel) throws -> Camera {
        try camera.flatMap(model.camera) ?? model.camera(in: cluster, name: newCamera)
    }
}

/// Each item: its file, its camera (one of the cluster's, or a new one), and its start.
struct FootageRows: View {
    @Environment(AppModel.self) private var model
    @Binding var items: [Footage]
    let clusterID: Int64?

    var body: some View {
        let cameras = model.cameras.filter { $0.clusterID == clusterID }
        ForEach($items) { $item in
            HStack(spacing: 8) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(item.url.path)
                Picker("Camera", selection: $item.camera) {
                    ForEach(cameras) { camera in
                        Text(camera.name).tag(Optional(camera.id))
                    }
                    if !cameras.isEmpty { Divider() }
                    Text("New Camera").tag(Int64?.none)
                }
                .labelsHidden()
                .frame(width: 140)
                if item.camera == nil {
                    TextField("Camera", text: $item.newCamera, prompt: Text("Camera name"))
                        .labelsHidden()
                        .frame(width: 130)
                }
                TextField("Starts at", text: $item.start, prompt: Text("Start unknown"))
                    .labelsHidden()
                    .frame(width: 150)
                    .monospacedDigit()
                Image(systemName: item.startIsValid ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(item.startIsValid ? Color.secondary : Color.red)
                    .help(item.startIsValid ? "The camera's clock at the first frame" : "Write it as 2024-02-02 16:00:56, or leave it empty")
                Button { items.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
    }
}
