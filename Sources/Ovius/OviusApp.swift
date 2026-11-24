import AppKit
import SwiftData
import SwiftUI

@main
struct OviusApp: App {
    /// `Ovius --gallery` opens only the component gallery: no library, no network.
    static let galleryOnly = CommandLine.arguments.contains("--gallery")
    /// `Ovius --fleet [--multi] [--targets]` opens only the dashboard's analysis, on sample data: no library, no network.
    static let fleetOnly = CommandLine.arguments.contains("--fleet")

    private let databaseManager = OviusApp.galleryOnly || OviusApp.fleetOnly || ShellPreview.isOn ? DatabaseManager(inMemory: true) : DatabaseManager.shared
    @State private var settingsViewModel = SettingsViewModel()

    init() {
        if Self.galleryOnly && CommandLine.arguments.contains("--snapshot") {
            GallerySnapshot.run(CommandLine.arguments)
        }
        if Self.fleetOnly && CommandLine.arguments.contains("--snapshot") {
            FleetSnapshot.run(CommandLine.arguments)
        }
        // Keep standard macOS app activation, Dock icon, and menu bar when run via `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Ovius", id: "main") {
            Group {
                if Self.galleryOnly {
                    ComponentGallery()
                } else if Self.fleetOnly {
                    FleetSamplePreview(recordings: CommandLine.arguments.contains("--multi") ? 4 : 1,
                                       targets: CommandLine.arguments.contains("--targets") ? FleetSnapshot.sampleTargets : FleetTargets())
                } else if ShellPreview.isOn {
                    ShellPreview.content
                } else {
                    ContentView()
                }
            }
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
            CommandGroup(after: .help) {
                GalleryCommand()
            }
        }

        Window("Component Gallery", id: "gallery") {
            ComponentGallery()
                .frame(minWidth: 1100, minHeight: 700)
        }

        Settings {
            SettingsView(viewModel: settingsViewModel)
                .frame(minWidth: 580, minHeight: 480)
        }
        .modelContainer(databaseManager.container)
    }
}

/// Help › Component Gallery: every Ovius component, for reviewing the design.
private struct GalleryCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Component Gallery") { openWindow(id: "gallery") }
    }
}
