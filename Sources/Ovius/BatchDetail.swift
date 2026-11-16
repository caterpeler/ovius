import OviusCore
import SwiftUI

/// A run: where each camera is, then the cluster's figures once they are worked out.
struct BatchDetail: View {
    @Environment(AppModel.self) private var model
    let batch: Batch
    var back: PageBack?

    var body: some View {
        ScrollView {
            BatchContent(batch: batch, back: back)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(model.clusterTitle(batch.clusterID))
    }
}

/// The page itself, without its scrolling (to render it whole).
struct BatchContent: View {
    @Environment(AppModel.self) private var model
    let batch: Batch
    var back: PageBack?

    var body: some View {
        let state = model.state(of: batch)
        let cameras = model.analyses(of: batch)
        VStack(alignment: .leading, spacing: 24) {
            header(cameras)
            switch state {
            case .done:
                EmptyView()
            case .partial:
                // What went wrong first: the cameras that failed or were stopped, the rest with the others below.
                CameraStatusList(batch: batch, state: state, onlyOver: true)
            case .running, .copying, .figuring, .failed, .stopped:
                CameraStatusList(batch: batch, state: state)
            }
            if let metrics = batch.metrics {
                Dashboard(batch: batch, metrics: metrics, starts: Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0.start) }),
                          comparison: model.comparison(for: batch))
            }
            switch state {
            case .done, .partial:
                DisclosureGroup("Cameras, and what the pipeline printed for each") {
                    CameraStatusList(batch: batch, state: .done)
                        .padding(.top, 8)
                }
            default:
                EmptyView()
            }
        }
    }

    private func header(_ cameras: [Analysis]) -> some View {
        PageHeader(back: back, title: model.clusterTitle(batch.clusterID), subtitle: "\(model.when(batch)) · \(model.summary(of: batch))",
                   info: batch.metrics.map(Dashboard.estimates)) {
            if cameras.contains(where: { $0.status == .running || $0.status == .queued }) {
                Button { model.cancel(batch) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.page)
            }
            Button { model.reveal(model.library.batch(batch.id)) } label: { Image(systemName: "folder") }
                .buttonStyle(.page)
                .help("Show in Finder")
            Button(role: .destructive) { model.deleting = batch } label: { Image(systemName: "trash") }
                .buttonStyle(.page)
                .help("Delete this run…")
        }
    }
}

/// Each camera's video: running, waiting, failed (with why, and Run Again), or done; and what its pipeline printed.
private struct CameraStatusList: View {
    @Environment(AppModel.self) private var model
    let batch: Batch
    let state: Batch.State
    /// Only the cameras that failed or were stopped.
    var onlyOver = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .partial(let missing):
                Label("\(missing) of \(model.analyses(of: batch).count) cameras failed or were stopped: the figures below are of the others.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .figuring:
                Label("Every camera is done: working out the cluster's figures.", systemImage: "gearshape.2")
                    .foregroundStyle(.secondary)
            case .failed:
                Label(batch.error.map { "The cluster's figures could not be worked out: \($0)" } ?? "Every camera failed.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .running(let over, let of):
                Label("\(over) of \(of) cameras done. The cluster's figures are worked out once every camera is.", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .copying:
                Label("Copying the videos into the library.", systemImage: "doc.on.doc")
                    .foregroundStyle(.secondary)
            case .stopped:
                Label("Stopped before any camera finished.", systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
            case .done:
                EmptyView()
            }
            ForEach(model.analyses(of: batch).filter { !onlyOver || $0.status == .failed || $0.status == .cancelled }) { analysis in
                CameraStatus(analysis: analysis)
            }
        }
    }
}

private struct CameraStatus: View {
    @Environment(AppModel.self) private var model
    let analysis: Analysis
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.cameraName(analysis.cameraID))
                        .font(.body.weight(.medium))
                    Text("\(analysis.videoName) · \(Format.clock(analysis.start))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                status
                Menu {
                    if analysis.status == .running || analysis.status == .queued {
                        Button("Stop") { model.cancel(analysis) }
                    }
                    if analysis.status == .failed || analysis.status == .cancelled {
                        Button("Run Again") { model.retry(analysis) }
                    }
                    Button(showLog ? "Hide What It Printed" : "Show What It Printed") { showLog.toggle() }
                    Button("Show in Finder") { model.reveal(model.revealable(analysis)) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if analysis.status == .failed, let error = analysis.error {
                Text(error)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if showLog {
                ScrollView {
                    Text(model.log(of: analysis))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: 200)
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var status: some View {
        switch analysis.status {
        case .done:
            if let m = analysis.metrics {
                Text("\(m.cycles.count) loads seen · \(Format.hours(m.video.durationS / 3600)) of video")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Pill(text: "Done", color: .secondary)
            }
        case .running:
            let now = model.progress[analysis.id]
            HStack(spacing: 6) {
                Text(now?.stage ?? "Running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fraction = now?.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 80)
                }
            }
        case .queued: Pill(text: model.runningID == nil ? "Starting soon" : "Waiting", color: .secondary)
        case .copying: Pill(text: "Copying", color: .secondary)
        case .failed: Pill(text: "Failed", color: .red)
        case .cancelled: Pill(text: "Stopped", color: .secondary)
        }
    }
}
