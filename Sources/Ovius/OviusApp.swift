import AppKit
import SwiftUI

@main
struct OviusApp: App {
    @State private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--import-results") { ImportCommand.run(CommandLine.arguments) }
        if CommandLine.arguments.contains("--snapshot") { Snapshot.run(CommandLine.arguments) }
        if ModelCommand.flags.contains(where: CommandLine.arguments.contains) { ModelCommand.run(CommandLine.arguments) }
        // A regular app with a Dock icon and menus even when started with `swift run`, outside its .app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Ovius", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 640)
                .onAppear { if ProcessInfo.processInfo.environment["OVIUS_BACKGROUND"] == nil { NSApplication.shared.activate() } }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Analysis…") { model.showNewAnalysis = true }
                    .keyboardShortcut("n")
                Button("Import Results…") { model.showImportResults = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
