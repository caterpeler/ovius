import AppKit
import SwiftUI

/// Every Ovius component on one page: first assembled into a dashboard, as the reference lays one out, then one by one
/// with their variants, each with what it recreates and where it is used. Its figures are made up: it reads no data.
public struct ComponentGallery: View {
    @State private var search = ""
    @State private var range = 14
    @State private var day: String? = "d11"
    @State private var preset = 30
    @State private var field = "https://d1zj4agypqh81v.cloudfront.net/api/v1"
    /// Whether the page scrolls (not when it is rendered whole to an image).
    let scrolls: Bool

    public init(scrolls: Bool = true) {
        self.scrolls = scrolls
    }

    public var body: some View {
        Group {
            if scrolls {
                ScrollView { page }
            } else {
                page
            }
        }
        .background(Ov.canvas)
        .foregroundStyle(Ov.ink)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 48) {
            dashboardPreview
            catalogue
        }
        .padding(32)
    }

    // MARK: - Assembled

    private var dashboardPreview: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            GalleryTitle("Dashboard, assembled", note: "The reference's layout with Ovius content: sidebar, top bar, page header, four figures, the tile chart with its day panel, the highlight card and a list card.")
            // As wide as a full window; in a narrower one it scrolls sideways.
            ViewThatFits(in: .horizontal) {
                preview
                ScrollView(.horizontal) { preview }
            }
        }
    }

    private var preview: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: 270)
                .padding(Ov.Space.l)
            main
                .padding(Ov.Space.page)
        }
        .frame(minWidth: 1380)
        .background(Ov.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Ov.hairline))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            OvBrandHeader(title: "Ovius", subtitle: "Open-Pit Site") {}
            OvSearchField(text: $search, prompt: "Search clips…", shortcut: "⌘K")
            VStack(alignment: .leading, spacing: 2) {
                OvSectionLabel("Workspace")
                OvNavItem("Dashboard", systemImage: "square.grid.2x2", isSelected: true) {}
                OvNavItem("Recordings", systemImage: "film.stack", count: 12, isSelected: false) {}
                OvNavItem("Flagged clips", systemImage: "flag", count: 2, isSelected: false) {}
            }
            VStack(alignment: .leading, spacing: 2) {
                OvSectionLabel("Configure")
                OvNavItem("Clusters & Sections", systemImage: "square.stack.3d.up", showsChevron: true, isSelected: false) {}
                OvNavItem("Endpoint", systemImage: "network", showsChevron: true, isSelected: false) {}
                OvNavItem("Offline cache", systemImage: "internaldrive", showsChevron: true, isSelected: false) {}
            }
            Spacer(minLength: 120)
            OvSidebarStatusCard(systemImage: "film.stack", value: 12, total: 48, caption: "clips loaded")
            OvIdentityRow(initials: "OP", title: "Open-Pit Site", subtitle: "3 sections · 9 cameras")
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: Ov.Space.xxl) {
            HStack(spacing: Ov.Space.s) {
                OvBreadcrumb([.init("Dashboard") {}, .init("Open-Pit Site")])
                Spacer()
                OvStatusPill("Telemetry synced", tone: .live)
                OvIconButton("arrow.clockwise", help: "Reload recordings") {}
                OvIconButton("bell", count: 2, help: "Flagged clips") {}
                Button {} label: { Label("Add section", systemImage: "plus") }
                    .buttonStyle(.ovPrimary)
            }
            OvPageHeader("Open-Pit Site", details: ["Last 14 days", "12 clips", "410 cycles"]) {
                Button {} label: { Label("Export", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.ovSecondary)
                Button {} label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.ovPrimary)
            }
            kpiRow
            HStack(alignment: .top, spacing: Ov.Space.l) {
                chartCard
                VStack(spacing: Ov.Space.l) {
                    OvHighlightCard("Complete cycles", value: 312, total: 410, caption: "98 cut off or incomplete: left out of the means.") {}
                    listCard
                }
                .frame(width: 340)
            }
        }
    }

    private var kpiRow: some View {
        HStack(spacing: Ov.Space.l) {
            OvKPICard("Complete cycles", systemImage: "checkmark", value: "312", footnote: "of 410 · 26 per clip",
                      delta: OvDeltaChip("4.2%", isUp: true, tone: .positive), style: .tinted)
            OvKPICard("Mean cycle time", systemImage: "clock", value: "4m 12s", footnote: "± 1m 03s · 5.8 passes",
                      delta: OvDeltaChip("8.1%", isUp: true, tone: .negative))
            OvKPICard("Excavator idle", systemImage: "pause.circle", value: "2m 10s", footnote: "± 48 s · trucks 1m 30s", style: .inverse)
            OvKPICard("Excavator EEU", systemImage: "gauge.with.needle", value: "78", unit: "%", footnote: "Trucks 64%") {
                OvRingGauge(fraction: 0.78)
            }
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: Ov.Space.xl) {
            OvCardHeader("Cycles per day", subtitle: "Every tile is 10 cycles. Pick a day to read it.") {
                OvSegmentedControl(selection: $range, options: [(7, "7 days"), (14, "14 days"), (30, "30 days")])
            }
            HStack(alignment: .top, spacing: Ov.Space.l) {
                VStack(alignment: .leading, spacing: Ov.Space.m) {
                    OvTileChart(columns: Self.sampleColumns, rows: 9, selection: $day)
                    OvLegend([(Ov.tileSage, "Complete"), (Ov.tileMid, "Incomplete"), (Ov.tileStrong, "Cut off"), (Ov.tileEmpty, "No cycles")])
                }
                VStack(alignment: .leading, spacing: Ov.Space.l) {
                    Text("Thu 12 Nov · 3 clips")
                        .ovText(.caption)
                        .foregroundStyle(Ov.ink2)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("38").ovText(.value).font(.system(size: 34, weight: .medium))
                        Text("cycles").ovText(.caption).foregroundStyle(Ov.ink3)
                    }
                    OvBreakdownRow(color: Ov.tileSage, title: "Complete", share: "79%", value: "30")
                    OvBreakdownRow(color: Ov.tileMid, title: "Incomplete", share: "13%", value: "5")
                    OvBreakdownRow(color: Ov.tileStrong, title: "Cut off", share: "8%", value: "3")
                    Spacer(minLength: 0)
                    Label("Mean cycle 4m 05s", systemImage: "clock")
                        .ovText(.caption)
                        .foregroundStyle(Ov.ink2)
                }
                .frame(width: 190, alignment: .leading)
                .ovCard(.sunken, padding: Ov.Space.l, radius: Ov.Radius.inner)
            }
        }
        .ovCard()
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: Ov.Space.s) {
            OvCardHeader("Busiest clips", subtitle: "Most cycles first")
            OvListRow(initials: "C1", title: "CAM01_0600", subtitle: "Section Alpha · 12 Nov", fraction: 0.82, value: "64")
            OvListRow(initials: "C4", title: "CAM04_0600", subtitle: "Section Beta · 12 Nov", fraction: 0.71, value: "51")
            OvListRow(initials: "C2", title: "CAM02_1400", subtitle: "Section Alpha · 11 Nov", fraction: 0.55, value: "47")
        }
        .ovCard()
    }

    /// Fourteen days of tiles, the strongest kinds at the bottom.
    static let sampleColumns: [OvTileColumn] = {
        let complete = [5, 6, 4, 6, 5, 3, 6, 6, 5, 6, 4, 6, 3, 5]
        let incomplete = [1, 1, 2, 1, 1, 2, 1, 1, 2, 1, 1, 1, 1, 1]
        return (0..<14).map { k in
            let tiles = [OvTileKind.strong] + Array(repeating: .mid, count: incomplete[k]) + Array(repeating: .sage, count: complete[k])
            return OvTileColumn(id: "d\(k)", label: "\(k + 1)", tiles: tiles)
        }
    }()

    // MARK: - One by one

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: Ov.Space.xxl) {
            GalleryTitle("Components, one by one", note: "Each with what it recreates from the reference and where it goes in Ovius.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: Ov.Space.l, alignment: .top)], alignment: .leading, spacing: Ov.Space.l) {
                GalleryItem("Tokens", recreates: "The warm grey canvas, white cards on soft shadows, sage accent, near-black emphasis", usedFor: "Every page") {
                    HStack(spacing: Ov.Space.s) {
                        ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(swatch.1)
                                    .frame(width: 48, height: 48)
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Ov.hairline))
                                Text(swatch.0).font(.system(size: 10)).foregroundStyle(Ov.ink2)
                            }
                        }
                    }
                }
                GalleryItem("Type scale", recreates: "Greeting title, card values, labels, section eyebrows", usedFor: "Every page") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Open-Pit Site").ovText(.display)
                        Text("4m 12s").ovText(.value)
                        Text("Cycles per day").ovText(.heading)
                        Text("Every tile is 10 cycles").ovText(.label).foregroundStyle(Ov.ink2)
                        Text("WORKSPACE").ovText(.eyebrow).foregroundStyle(Ov.ink3)
                    }
                }
                GalleryItem("Buttons", recreates: "\"+ New\", \"Start a check\" (primary) and \"Export\" (secondary)", usedFor: "Refresh, Add section, Save, Test connection, Delete") {
                    VStack(alignment: .leading, spacing: Ov.Space.m) {
                        HStack {
                            Button {} label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.ovPrimary)
                            Button {} label: { Label("Export", systemImage: "square.and.arrow.down") }.buttonStyle(.ovSecondary)
                            Button("Reset") {}.buttonStyle(.ovQuiet)
                        }
                        HStack {
                            Button("Delete section") {}.buttonStyle(.ov(.destructive))
                            Button("Small") {}.buttonStyle(.ov(.secondary, size: .small))
                            Button("Disabled") {}.buttonStyle(.ovPrimary).disabled(true)
                        }
                    }
                }
                GalleryItem("Brand header", recreates: "Veyla · Northwick Mutual, with the sidebar button", usedFor: "Sidebar top: Ovius and the active cluster") {
                    OvBrandHeader(title: "Ovius", subtitle: "Open-Pit Site") {}
                }
                GalleryItem("Search field", recreates: "\"Search checks… ⌘K\"", usedFor: "Recording search, Data Explorer search") {
                    OvSearchField(text: $search, prompt: "Search clips, cameras, locations…", shortcut: "⌘K")
                }
                GalleryItem("Navigation", recreates: "DESK / CONTROLS labels, items with counts and chevrons, the sage selection", usedFor: "Sidebar: Dashboard, Clusters & Sections, Settings") {
                    VStack(alignment: .leading, spacing: 2) {
                        OvSectionLabel("Workspace", trailing: "3")
                        OvNavItem("Dashboard", systemImage: "square.grid.2x2", isSelected: true) {}
                        OvNavItem("Recordings", systemImage: "film.stack", count: 12, isSelected: false) {}
                        OvNavItem("Clusters & Sections", systemImage: "square.stack.3d.up", showsChevron: true, isSelected: false) {}
                    }
                }
                GalleryItem("Sidebar status card", recreates: "\"23/60 in queue\" with its dots", usedFor: "Sidebar foot: clips loaded of those selected, while telemetry streams") {
                    OvSidebarStatusCard(systemImage: "film.stack", value: 12, total: 48, caption: "clips loaded")
                }
                GalleryItem("Identity row", recreates: "\"Ines Okafor · Lead · Leeds\" with its switcher", usedFor: "Cluster switcher at the sidebar's foot (replaces the cluster menu)") {
                    OvIdentityRow(initials: "OP", title: "Open-Pit Site", subtitle: "3 sections · 9 cameras")
                }
                GalleryItem("Breadcrumb", recreates: "\"Trust & Safety desk › Overview\"", usedFor: "Top bar; the Data Explorer's Recordings › clip › cycle path") {
                    OvBreadcrumb([.init("All recordings") {}, .init("CAM01_0600") {}, .init("CYC-0412")])
                }
                GalleryItem("Status pill", recreates: "\"● All checks running\"", usedFor: "Telemetry: synced, streaming, page cap reached, sync error") {
                    VStack(alignment: .leading, spacing: Ov.Space.s) {
                        HStack {
                            OvStatusPill("Telemetry synced", tone: .live)
                            OvStatusPill("Streaming 8 of 12", tone: .busy)
                        }
                        HStack {
                            OvStatusPill("Page cap reached", tone: .warning)
                            OvStatusPill("Sync error", tone: .error)
                        }
                    }
                }
                GalleryItem("Icon buttons", recreates: "The moon and bell (with its count), and the square sidebar button", usedFor: "Reload, flagged clips, fold the sidebar") {
                    HStack(spacing: Ov.Space.m) {
                        OvIconButton("arrow.clockwise", help: "Reload") {}
                        OvIconButton("bell", count: 3, help: "Flagged clips") {}
                        OvIconButton("sidebar.left", shape: .square, help: "Hide the sidebar") {}
                    }
                }
                GalleryItem("Page header", recreates: "\"Good morning, Ines\", its line of details, Export and Start a check", usedFor: "Dashboard, a section's page, Settings") {
                    OvPageHeader("Section Alpha", details: ["SEC_ALPHA", "4 cameras", "2 tags"]) {
                        Button("Edit") {}.buttonStyle(.ov(.secondary, size: .small))
                    }
                }
                GalleryItem("KPI cards", recreates: "Passed today (tinted), Median time (plain), Stopped today (inverse), Sources answering (ring)", usedFor: "The dashboard's figures: cycles, cycle time, idle, EEU") {
                    VStack(spacing: Ov.Space.m) {
                        HStack(spacing: Ov.Space.m) {
                            OvKPICard("Complete cycles", systemImage: "checkmark", value: "312", footnote: "of 410", style: .tinted)
                            OvKPICard("Excavator idle", systemImage: "pause.circle", value: "2m 10s", footnote: "± 48 s", style: .inverse)
                        }
                        OvKPICard("Truck EEU", systemImage: "gauge.with.needle", value: "64", unit: "%", footnote: "spotting, loading, departing",
                                  delta: OvDeltaChip("0.4 pts", isUp: false, tone: .neutral)) {
                            OvRingGauge(fraction: 0.64, size: 60, lineWidth: 7)
                        }
                    }
                }
                GalleryItem("Change chips", recreates: "\"↓0.1%\" and \"↑8.1%\"", usedFor: "A figure against an earlier period, when the dashboard compares one") {
                    HStack {
                        OvDeltaChip("4.2%", isUp: true, tone: .positive)
                        OvDeltaChip("8.1%", isUp: true, tone: .negative)
                        OvDeltaChip("0.1%", isUp: false, tone: .neutral)
                    }
                }
                GalleryItem("Segmented control", recreates: "7 / 14 / 30 days", usedFor: "Date range presets (7D, 1M, 3M, All); Explorer filters") {
                    OvSegmentedControl(selection: $preset, options: [(7, "7D"), (30, "1M"), (90, "3M"), (0, "All")])
                }
                GalleryItem("Pill menus", recreates: "(The reference's dropdowns, in the same pill shape)", usedFor: "Section, Camera, Sort and Status filters") {
                    HStack {
                        OvPillMenu("All sections", systemImage: "square.stack.3d.up") { Button("Section Alpha") {}; Button("Section Beta") {} }
                        OvPillMenu("Sort: Newest") { Button("Newest") {}; Button("Most cycles") {} }
                    }
                }
                GalleryItem("Tile chart", recreates: "\"Checks per day\": a column of tiles a day, a day to pick", usedFor: "Cycles per day: complete, incomplete, cut off") {
                    VStack(alignment: .leading, spacing: Ov.Space.m) {
                        OvTileChart(columns: Array(Self.sampleColumns.prefix(8)), rows: 8, selection: $day)
                        OvLegend([(Ov.tileSage, "Complete"), (Ov.tileMid, "Incomplete"), (Ov.tileStrong, "Cut off")])
                    }
                }
                GalleryItem("Breakdown rows", recreates: "Passed / Needed a person / Declined with shares", usedFor: "The picked day's panel; a clip's cycles by status") {
                    VStack(spacing: Ov.Space.m) {
                        OvBreakdownRow(color: Ov.tileSage, title: "Complete", share: "79%", value: "30")
                        OvBreakdownRow(color: Ov.tileMid, title: "Incomplete", share: "13%", value: "5")
                    }
                }
                GalleryItem("Highlight card", recreates: "\"Review queue 23/60\" with dots and its arrow", usedFor: "Complete of all cycles, opening the incomplete ones in the Explorer") {
                    OvHighlightCard("Complete cycles", value: 312, total: 410, caption: "98 cut off or incomplete: left out of the means.") {}
                }
                GalleryItem("List card", recreates: "\"Next up · Oldest first\" with initials, bars and figures", usedFor: "Busiest clips, or clips with the most incomplete cycles") {
                    VStack(spacing: 0) {
                        OvListRow(initials: "C1", title: "CAM01_0600", subtitle: "Section Alpha · 12 Nov", fraction: 0.82, value: "64")
                        OvListRow(initials: "C4", title: "CAM04_0600", subtitle: "Section Beta · 12 Nov", fraction: 0.71, value: "51")
                    }
                }
                GalleryItem("Progress", recreates: "Dots, thin bars and the ring", usedFor: "Loading, shares, utilisation") {
                    HStack(spacing: Ov.Space.xl) {
                        OvDotProgress(value: 18, total: 30).frame(width: 140)
                        OvProgressBar(fraction: 0.6).frame(width: 80)
                        OvRingGauge(fraction: 0.42, size: 48, lineWidth: 6)
                    }
                }
                GalleryItem("Banners", recreates: "(In the reference's tones)", usedFor: "Telemetry sync error, page cap reached, selector test result") {
                    VStack(spacing: Ov.Space.s) {
                        OvBanner(.error, title: "Telemetry sync error", message: "HTTP 503 from the API. Try Refresh in a minute.")
                        OvBanner(.warning, title: "Page cap reached", message: "Select fewer recordings for every segment.")
                    }
                }
                GalleryItem("Empty and loading", recreates: "(Same quiet card language)", usedFor: "No recording selected; loading the Explorer") {
                    HStack(spacing: Ov.Space.m) {
                        OvEmptyState(systemImage: "sidebar.left", title: "No recording selected", message: "Pick recordings, then Refresh.") {
                            Button("Select all") {}.buttonStyle(.ov(.secondary, size: .small))
                        }
                        .ovCard(.sunken, padding: 0, radius: Ov.Radius.inner)
                        OvLoadingState("Loading cycles…", message: "Fetching 12 recordings, 8 at a time.")
                            .ovCard(.sunken, padding: 0, radius: Ov.Radius.inner)
                    }
                }
                GalleryItem("Field", recreates: "(The search field's well, with a label)", usedFor: "Settings: endpoint, API key, timeout; section editor") {
                    OvField("Primary CloudFront URL", text: $field)
                }
                GalleryItem("Action bar", recreates: "(A dark pill in the reference's style)", usedFor: "\"Selection changed. Refresh\" at the dashboard's foot") {
                    OvActionBar("Selection changed: 14 clips", actionTitle: "Refresh") {}
                }
            }
        }
    }

    static let swatches: [(String, Color)] = [
        ("canvas", Ov.canvas), ("card", Ov.card), ("sunken", Ov.sunken), ("sage", Ov.sage),
        ("sage+", Ov.sageStrong), ("inverse", Ov.inverse), ("mid", Ov.tileMid),
    ]
}

/// A part of the gallery: its title and what it shows.
private struct GalleryTitle: View {
    let title: String
    let note: String

    init(_ title: String, note: String) {
        self.title = title
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).ovText(.title)
            Text(note).ovText(.label).foregroundStyle(Ov.ink2)
        }
    }
}

/// One component in the catalogue: its name, what it recreates, where it goes, and the component itself.
private struct GalleryItem<Content: View>: View {
    let name: String
    let recreates: String
    let usedFor: String
    @ViewBuilder let content: () -> Content

    init(_ name: String, recreates: String, usedFor: String, @ViewBuilder content: @escaping () -> Content) {
        self.name = name
        self.recreates = recreates
        self.usedFor = usedFor
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ov.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).ovText(.heading)
                Text("Recreates: \(recreates)").ovText(.caption).foregroundStyle(Ov.ink2)
                Text("In Ovius: \(usedFor)").ovText(.caption).foregroundStyle(Ov.sageInk)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Ov.Space.l)
                .background(Ov.canvas, in: RoundedRectangle(cornerRadius: Ov.Radius.inner, style: .continuous))
        }
        .ovCard()
    }
}

/// `Ovius --gallery --snapshot OUT.png [--width POINTS] [--dark]`: renders the whole gallery to an image without a
/// window, then quits. Text fields and menus are AppKit's and draw as placeholders.
@MainActor
enum GallerySnapshot {
    static func run(_ args: [String]) -> Never {
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let out = value("--snapshot") else { exit(2) }
        let view = ComponentGallery(scrolls: false)
            .frame(width: value("--width").flatMap(Double.init) ?? 1500)
            .environment(\.colorScheme, args.contains("--dark") ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("Could not render the gallery.\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: out))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
        print("Wrote \(out)")
        exit(0)
    }
}
