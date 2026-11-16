import OviusCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = Settings()
    /// Which model a file is being picked for.
    @State private var picking: Pick?

    private enum Pick {
        case detector, states
    }

    var body: some View {
        TabView {
            models
                .tabItem { Label("Models", systemImage: "eye") }
            figures
                .tabItem { Label("Figures", systemImage: "chart.bar") }
            running
                .tabItem { Label("Running", systemImage: "cpu") }
        }
        .frame(width: 600, height: 560)
        .onAppear { draft = model.settings }
        .onChange(of: draft) { _, new in model.apply(new) }
    }

    /// The built-in pipeline's detector, and the state model that may join it.
    private var models: some View {
        Form {
            Section {
                LabeledContent("Detector", value: model.detector?.name ?? "None yet")
                if let d = model.detector {
                    LabeledContent("Classes", value: d.classes.joined(separator: ", "))
                    if !d.needs.isEmpty {
                        LabeledContent("Its preprocessing also needs", value: d.needs.joined(separator: ", "))
                    }
                    if let missing = missingClasses(d) {
                        Label(missing, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Button(model.detector == nil ? "Choose Detector…" : "Replace Detector…") { picking = .detector }
            } header: {
                Text("Detector")
            } footer: {
                Text("A model's or a pipeline's bundle from the labeler (its .tar.gz, or the folder it unpacks to), which holds the model, its classes and its preprocessing; or a D-FINE .pth with its .dfine.json beside it. It is copied into the library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("State model") {
                    Text(model.stateModel.map { "\($0.name), \($0.kind == .clips ? "judges clips" : "segments whole tracks")" } ?? "None")
                }
                if let m = model.stateModel {
                    if !m.states.isEmpty {
                        LabeledContent("Its states", value: m.states.joined(separator: ", "))
                    }
                    TextField("Idle states", text: $draft.idleStates, prompt: Text("idle"))
                    if m.kind == .clips {
                        number("Clip length, as its state version cut them", $draft.stateClipS, unit: "s")
                    }
                }
                HStack {
                    Button(model.stateModel == nil ? "Choose State Model…" : "Replace State Model…") { picking = .states }
                    if model.stateModel != nil {
                        Button("Remove", role: .destructive) { model.removeStateModel() }
                    }
                }
            } header: {
                Text("Excavator states (optional)")
            } footer: {
                Text("Without one, an excavator is working or idle by how its box moves: every figure is worked out from that. With one (state_model.pth or segment_model.pth from the labeler's state training), each excavator also gets its states, digging, swinging, loading…, and the states named idle (comma-separated) count as idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let problem = model.cannotChangeModels {
                Text(problem)
                    .foregroundStyle(.secondary)
            }
            if model.importingModel {
                ProgressView("Copying the model into the library…")
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .disabled(model.importingModel)
        .fileImporter(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
                      allowedContentTypes: picking == .states ? [.data] : [.folder, .gzip, .archive, .data]) { result in
            let pick = picking
            picking = nil
            guard case .success(let url) = result else { return }
            switch pick {
            case .detector: model.importDetector(from: url)
            case .states: model.importStateModel(from: url)
            case nil: break
            }
        }
    }

    /// The classes the built-in pipeline needs that the detector does not have.
    private func missingClasses(_ d: Detector) -> String? {
        let key = { (c: String) in c.lowercased().filter { !" _-".contains($0) } }
        let has = Set(d.classes.map(key))
        let missing = ["excavator", "dumptruck"].filter { !has.contains($0) }
        return missing.isEmpty ? nil : "The pipeline looks for \(missing.joined(separator: " and ")) boxes, which this detector does not find."
    }

    private var figures: some View {
        Form {
            Section {
                number("Volume of a truck load", $draft.m3PerLoad, unit: "m³")
                number("Struck: level with the body's sides", $draft.m3Struck, unit: "m³")
                number("Heaped: the most it holds", $draft.m3Heaped, unit: "m³")
            } header: {
                Text("Material moved")
            } footer: {
                Text("Material moved is load cycles × the volume of a load, shown with the range from struck to heaped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                number("Ignore loading points seen under", $draft.minPointMinutes, unit: "min")
            } header: {
                Text("Excavators")
            } footer: {
                Text("A loading point seen briefly, where no truck was loaded, is left out: the detector saw something for a moment, not an excavator. Changing these works every analysis's figures out again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.recalculating {
                ProgressView("Working the figures out again…")
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private var running: some View {
        Form {
            Section {
                Picker("Run the models on", selection: $draft.device) {
                    Text("Apple GPU").tag("mps")
                    Text("CPU").tag("cpu")
                }
            }
            Section {
                LabeledContent("Python") {
                    Text(model.pythonDescription)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Use another Python", text: $draft.customPython, prompt: Text("Empty: the app's own"))
                if let setup = model.pythonSetup {
                    ProgressView(setup.stage, value: setup.fraction ?? 0)
                }
                HStack {
                    Button("Set Up Python Again") { model.reinstallPython() }
                    Button("Reinstall Packages") { model.reinstallPackages() }
                        .help("PyTorch and the rest are installed again on the next run.")
                }
                .disabled(model.isBusy)
            } header: {
                Text("Python")
            } footer: {
                Text("The app downloads its own Python the first time it analyses footage, and installs the packages the pipeline needs (PyTorch and the rest, a few GB, once). After changing the Python, reinstall the packages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Show Library in Finder") { model.reveal(model.library.root) }
            }
        }
        .formStyle(.grouped)
    }

    private func number(_ label: String, _ value: Binding<Double>, unit: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(unit)
                    .frame(width: 30, alignment: .leading)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
