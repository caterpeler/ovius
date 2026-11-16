import AppKit
import OviusCore
import SwiftUI

/// `Ovius --snapshot OUT.png [--clusters | --cluster ID | --batch ID] [--width POINTS] [--dark]`: renders the
/// Dashboard, the clusters, a cluster's page or a run's page to a PNG without opening a window, to check a view while working on it. Menus and other AppKit
/// controls are drawn as placeholders.
@MainActor
enum Snapshot {
    static func run(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            exit(1)
        }
        guard let out = value("--snapshot") else { fail("usage: Ovius --snapshot OUT.png [--clusters | --cluster ID | --batch ID] [--width POINTS] [--dark]") }
        let model = AppModel(runQueue: false)
        if let alert = model.alert { fail(alert) }
        // As the app would show it: figures an older version worked out are worked out again first.
        if model.bringFiguresUpToDate() {
            let began = Date()
            while !model.recalculating, Date().timeIntervalSince(began) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            while model.recalculating { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            if let alert = model.alert { FileHandle.standardError.write(Data("\(alert)\n".utf8)) }
        }
        let page: AnyView
        if let id = value("--batch").flatMap(Int64.init) {
            guard let batch = model.batch(id) else { fail("No analysis \(id) in \(model.library.root.path).") }
            page = AnyView(BatchContent(batch: batch))
        } else if let id = value("--cluster").flatMap(Int64.init) {
            guard let cluster = model.cluster(id) else { fail("No cluster \(id) in \(model.library.root.path).") }
            page = AnyView(ClusterContent(cluster: cluster) { _ in })
        } else if args.contains("--clusters") {
            page = AnyView(ClustersContent { _ in })
        } else {
            page = AnyView(OverviewContent { _ in })
        }
        let dark = args.contains("--dark")
        let view = page
            .environment(model)
            .padding(24)
            .frame(width: value("--width").flatMap(Double.init) ?? 1100, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { fail("Could not render the page.") }
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        do {
            try png?.write(to: URL(fileURLWithPath: out))
        } catch {
            fail(error.localizedDescription)
        }
        print("Wrote \(out)")
        exit(0)
    }
}
