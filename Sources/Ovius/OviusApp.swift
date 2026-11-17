import AppKit
import SwiftData
import SwiftUI

@main
struct OviusApp: App {
    private let databaseManager = DatabaseManager.shared
    @State private var settingsViewModel = SettingsViewModel()

    init() {
        // Keep standard macOS app activation, Dock icon, and menu bar when run via `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Ovius", id: "main") {
            ContentView()
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear {
                    if ProcessInfo.processInfo.environment["OVIUS_BACKGROUND"] == nil {
                        NSApplication.shared.activate()
                    }
                }
        }
        .modelContainer(databaseManager.container)
        .commands {
            SidebarCommands()
        }

        Settings {
            SettingsView(viewModel: settingsViewModel)
                .frame(minWidth: 580, minHeight: 480)
        }
        .modelContainer(databaseManager.container)
    }
}
