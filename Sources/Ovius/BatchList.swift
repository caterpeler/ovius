import OviusCore
import SwiftUI

/// Where a batch is, in a few words.
struct BatchStatus: View {
    @Environment(AppModel.self) private var model
    let batch: Batch

    var body: some View {
        switch model.state(of: batch) {
        case .done, .partial:
            if let t = batch.metrics?.total {
                HStack(spacing: 6) {
                    Text("\(t.cycles) cycles (\(t.observed) + \(t.estimated) est.)")
                        .foregroundStyle(.secondary)
                    if case .partial(let missing) = model.state(of: batch) {
                        Pill(text: "\(missing) failed", color: .orange)
                    }
                }
            }
        case .running(let over, let of):
            let running = model.analyses(of: batch).first { $0.status == .running }
            if let fraction = running.flatMap({ model.progress[$0.id]?.fraction }) {
                HStack(spacing: 6) {
                    Text("\(over + 1) of \(of)")
                        .foregroundStyle(.secondary)
                    ProgressView(value: fraction)
                        .frame(width: 50)
                }
            } else {
                Pill(text: running == nil ? "Waiting" : "Running \(over + 1) of \(of)", color: running == nil ? .secondary : .blue)
            }
        case .copying: Pill(text: "Copying", color: .secondary)
        case .figuring: Pill(text: "Working out", color: .blue)
        case .failed: Pill(text: "Failed", color: .red)
        case .stopped: Pill(text: "Stopped", color: .secondary)
        }
    }
}

/// What can be done with a batch, in its context menu and toolbar.
struct BatchActions: View {
    @Environment(AppModel.self) private var model
    let batch: Batch

    var body: some View {
        let mine = model.analyses(of: batch)
        if mine.contains(where: { $0.status == .running || $0.status == .queued }) {
            Button("Stop") { model.cancel(batch) }
        }
        let again = mine.filter { $0.status == .failed || $0.status == .cancelled }
        if !again.isEmpty {
            Button(again.count == 1 ? "Run the Failed Camera Again" : "Run \(again.count) Cameras Again") {
                again.forEach(model.retry)
            }
        }
        Button("Show in Finder") { model.reveal(model.library.batch(batch.id)) }
        Divider()
        Button("Delete…", role: .destructive) { model.deleting = batch }
    }
}
